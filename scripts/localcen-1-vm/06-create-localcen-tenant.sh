#!/usr/bin/env bash
# Runs on LocalCen-1-VM. Creates one LocalCen tenant the way the admin console does
# (http/controllers/admin_tenants_controller.go Create + console_apikey_controller.go Create):
#   1. the tenant's organization in Next iDP realm cconsole (idempotent on slug, with LocalCen's IDP_API_KEY)
#   2. tenants row (UUIDv7, webhook_secret = 64 hex, webhook_url, idp_org_id, status active, quotas unlimited)
#   3. api_keys row "nextdp-core" (bk_ + 64 hex; sha256 stored, 12-char prefix)
#   4. /root/.localcen-tenant-<slug>.env (0600): LOCAL_API_KEY, LOCAL_WEBHOOK_SECRET, LOCAL_TENANT_ID (never printed)
#   5. restart LocalCen (the console admits the new organization) + GET /v1/ping with the new key
# MODE=check | apply. A tenant that exists without its saved file is refused (no silent key rotation).
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:-check}"; SLUG="${SLUG:?}"; NAME="${NAME:?}"; WEBHOOK_URL="${WEBHOOK_URL:?}"
[[ "$MODE" =~ ^(check|apply)$ ]] || { echo "FATAL: MODE must be check or apply"; exit 1; }
[[ "$SLUG" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] || { echo "FATAL: bad slug"; exit 1; }
[[ "$WEBHOOK_URL" =~ ^https://[a-z0-9.-]+/ ]] || { echo "FATAL: webhook URL must be https"; exit 1; }
TS=$(date -u +%Y%m%dT%H%M%SZ)
if [ "$MODE" = "apply" ]; then
  BK=/var/backups/localcen/pre-tenant-$SLUG-$TS
  sudo mkdir -p "$BK" && sudo chmod 700 "$BK"
  sudo -u postgres pg_dump -Fc -d localcen_db | sudo tee "$BK/localcen_db.dump" >/dev/null
  echo "backup: $BK/localcen_db.dump ($(sudo du -h "$BK/localcen_db.dump" | cut -f1))"
fi
sudo env MODE="$MODE" SLUG="$SLUG" NAME="$NAME" WEBHOOK_URL="$WEBHOOK_URL" python3 - <<'PY'
import hashlib, json, os, secrets, subprocess, sys, tempfile, time, urllib.error, urllib.request
MODE, SLUG, NAME, HOOK = os.environ["MODE"], os.environ["SLUG"], os.environ["NAME"], os.environ["WEBHOOK_URL"]
APPLY = MODE == "apply"
ENV = "/srv/apps/localcen/shared/.env"
OUT = f"/root/.localcen-tenant-{SLUG}.env"

def envf(p):
    d = {}
    if os.path.exists(p):
        for l in open(p, encoding="utf-8"):
            s = l.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1); d[k.strip()] = v.strip().strip('"').strip("'")
    return d
cfg = envf(ENV)
ISSUER, KEY = cfg.get("IDP_ISSUER", "").rstrip("/"), cfg.get("IDP_API_KEY", "")
if not ISSUER or not KEY:
    sys.exit("FATAL: IDP_ISSUER / IDP_API_KEY missing in LocalCen .env (run 05-wire-localcen-idp first)")

def psql(sql, *vals):
    # values go in as psql variables (quoted by psql), never into the SQL text
    args = ["sudo", "-u", "postgres", "psql", "-d", "localcen_db", "-At", "-F", "|", "-v", "ON_ERROR_STOP=1"]
    for i, v in enumerate(vals):
        args += ["-v", f"v{i}={v}"]
    r = subprocess.run(args, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("FATAL: psql: " + r.stderr.strip()[:300])
    return [l for l in r.stdout.splitlines() if l]

def idp(method, path, body=None):
    h = {"Authorization": f"Bearer {KEY}", "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    req = urllib.request.Request(ISSUER + "/api/v1" + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}

def find_org():
    for page in range(1, 21):
        st, j = idp("GET", f"/realm/organizations?page={page}&limit=100")
        if st != 200:
            sys.exit(f"FATAL: list organizations -> HTTP {st} {json.dumps(j)[:200]}")
        for o in j.get("data") or []:
            if (o.get("slug") or "").lower() == SLUG:
                return o
        if page >= (j.get("meta") or {}).get("pages", 1) or not j.get("data"):
            return None
    return None

row = psql("select id, coalesce(idp_org_id,''), status, coalesce(webhook_url,'') from tenants where slug = :'v0' and deleted_at is null;\n", SLUG)
org = find_org()
saved = envf(OUT)
print(f"tenant {SLUG}: {'exists ' + row[0] if row else 'missing'}; cconsole org: {(org or {}).get('id', 'missing')}; saved file: {'yes' if saved.get('LOCAL_API_KEY') else 'no'}")
if row and not saved.get("LOCAL_API_KEY"):
    sys.exit(f"FATAL: tenant {SLUG} exists but {OUT} is missing; create a key in its console instead")
if not APPLY:
    print("CHECK DONE (nothing written)"); sys.exit(0)

if not org:
    st, j = idp("POST", "/realm/organizations", {"name": NAME, "slug": SLUG, "domain": ""})
    if st in (200, 201):
        org = j.get("data") or j
        print(f"cconsole org {SLUG} created {org.get('id')}")
    elif st == 409:
        org = find_org()
    else:
        sys.exit(f"FATAL: create organization -> HTTP {st} {json.dumps(j)[:200]}")
else:
    print(f"cconsole org {SLUG} exists {org.get('id')}")
org_id = org["id"]

def uuid7():
    ms = int(time.time() * 1000)
    b = bytearray(ms.to_bytes(6, "big") + secrets.token_bytes(10))
    b[6] = (b[6] & 0x0F) | 0x70
    b[8] = (b[8] & 0x3F) | 0x80
    h = b.hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"

if row:
    tid = row[0]
    psql("update tenants set webhook_url = :'v1', idp_org_id = :'v2', updated_at = now() where id = :'v0';\n", tid, HOOK, org_id)
    print(f"tenant {SLUG} kept {tid} (webhook_url, idp_org_id updated); key + secret kept from {OUT}")
else:
    tid, whsec = uuid7(), secrets.token_hex(32)
    plain = "bk_" + secrets.token_hex(32)
    kid = uuid7()
    psql("begin;\n"
         "insert into tenants (id, created_at, updated_at, name, slug, webhook_url, webhook_secret, status, idp_org_id)"
         " values (:'v0', now(), now(), :'v1', :'v2', :'v3', :'v4', 'active', :'v5');\n"
         "insert into api_keys (id, created_at, updated_at, tenant_id, name, key_prefix, key_hash)"
         " values (:'v6', now(), now(), :'v0', 'nextdp-core', :'v7', :'v8');\n"
         "commit;\n", tid, NAME, SLUG, HOOK, whsec, org_id, kid, plain[:12], hashlib.sha256(plain.encode()).hexdigest())
    fd, tmp = tempfile.mkstemp(prefix=".localcen-tenant-", dir="/root")
    os.chmod(tmp, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(f"# LocalCen tenant {SLUG} ({time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}); never print\n")
        fh.write(f"LOCAL_TENANT_ID={tid}\nLOCAL_TENANT_SLUG={SLUG}\nLOCAL_API_KEY={plain}\nLOCAL_WEBHOOK_SECRET={whsec}\nLOCAL_IDP_ORG_ID={org_id}\n")
    os.replace(tmp, OUT)
    print(f"tenant {SLUG} created {tid}, key nextdp-core ({plain[:12]}…), saved {OUT} (0600)")
PY
[ "$MODE" = "apply" ] || exit 0

echo "== restart LocalCen (admit the organization) + ping with the new key"
sudo systemctl restart localcen.service localcen-worker.service
for i in $(seq 1 30); do curl -fsS -m 3 http://127.0.0.1:8092/healthz >/dev/null 2>&1 && break; sleep 1; done
sudo env OUT="/root/.localcen-tenant-$SLUG.env" python3 - <<'PY'
import json, os, urllib.request
d = dict(l.strip().split("=", 1) for l in open(os.environ["OUT"]) if "=" in l and not l.startswith("#"))
req = urllib.request.Request("https://localcen.cconsole.com/v1/ping", headers={"X-API-Key": d["LOCAL_API_KEY"]})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        j = json.loads(r.read() or b"{}")
        t = (j.get("data") or j).get("tenant_id")
        print(f"ping {r.status} tenant_id={t} match={t == d['LOCAL_TENANT_ID']}")
except urllib.error.HTTPError as e:
    print(f"ping HTTP {e.code} {e.read()[:200]!r}"); raise SystemExit(1)
PY
echo "APPLY DONE"
