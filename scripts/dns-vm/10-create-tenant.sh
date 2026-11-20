#!/usr/bin/env bash
# Runs on the DNS VM. Creates a dns-service tenant + one API key + webhook URL/secret directly in
# dns_db, with the same values the admin console would write (the console needs an iDP browser
# session, so it cannot be scripted over HTTP). Then checks the key through the API (/whoami).
# Not done here: the Next iDP organization link (idp_org_id), only needed for tenant console
# sign-in; link it later in admin.dns.cconsole.com -> tenant -> Link organization.
#
# Secrets (API key, webhook secret) go only to /root/.dns-<slug>-secrets.env (0600) and are never
# printed. Idempotent: an existing tenant with the same slug is left alone (key/secret reused).
# Env: SLUG, NAME, NAMESERVERS (comma list), SOA_CONTACT, WEBHOOK_URL (optional), DRY_RUN (1)
set -Eeuo pipefail
exec 2>&1
SLUG="${SLUG:?}"; NAME="${NAME:?}"; NAMESERVERS="${NAMESERVERS:?}"; SOA_CONTACT="${SOA_CONTACT:?}"
WEBHOOK_URL="${WEBHOOK_URL:-}"; DRY_RUN="${DRY_RUN:-1}"
[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "FATAL: invalid SLUG"; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9\ ._-]+$ ]] || { echo "FATAL: invalid NAME"; exit 1; }
[[ "$NAMESERVERS" =~ ^[a-z0-9.-]+(,[a-z0-9.-]+)+$ ]] || { echo "FATAL: NAMESERVERS must be 2+ hosts, comma separated"; exit 1; }
[[ "$SOA_CONTACT" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+$ ]] || { echo "FATAL: invalid SOA_CONTACT"; exit 1; }
[[ -z "$WEBHOOK_URL" || "$WEBHOOK_URL" =~ ^https://[a-z0-9.-]+/[A-Za-z0-9/_-]*$ ]] || { echo "FATAL: invalid WEBHOOK_URL"; exit 1; }
SECRETS="/root/.dns-${SLUG}-secrets.env"
cd /tmp

existing="$(sudo -u postgres psql -d dns_db -XAt -v s="$SLUG" <<'SQL'
SELECT id FROM tenants WHERE (slug = :'s' OR account = :'s') AND deleted_at IS NULL;
SQL
)"
echo "tenant ${SLUG}: $([ -n "$existing" ] && echo "exists ($existing)" || echo "new")"
echo "  name=${NAME} nameservers=${NAMESERVERS} soa=${SOA_CONTACT} webhook=${WEBHOOK_URL:-none}"
if [ "$DRY_RUN" = "1" ]; then echo "DRY RUN: nothing written"; exit 0; fi

if [ -z "$existing" ]; then
  TS="$(date -u +%Y%m%dT%H%M%SZ)"; BK="/var/backups/dns-vm/pre-tenant-${SLUG}-$TS"
  sudo install -d -m 0750 -o root -g ubuntu "$BK"
  sudo -u postgres pg_dump -Fc dns_db | sudo tee "$BK/dns_db.dump" >/dev/null
  echo "  backup: $BK/dns_db.dump"
fi

sudo env SLUG="$SLUG" NAME="$NAME" NAMESERVERS="$NAMESERVERS" SOA_CONTACT="$SOA_CONTACT" WEBHOOK_URL="$WEBHOOK_URL" \
  SECRETS="$SECRETS" EXISTING="$existing" python3 - <<'PY'
import hashlib, json, os, secrets, subprocess, time, urllib.request, urllib.error

E = os.environ
def uuid7():
    ms = int(time.time() * 1000).to_bytes(6, "big")
    r = bytearray(secrets.token_bytes(10))
    r[0] = (r[0] & 0x0F) | 0x70          # version 7
    r[2] = (r[2] & 0x3F) | 0x80          # RFC 4122 variant
    h = (ms + bytes(r)).hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"

def psql(sql, **v):
    args = ["sudo", "-u", "postgres", "psql", "-d", "dns_db", "-XAtq", "-v", "ON_ERROR_STOP=1"]
    for k, val in v.items():
        args += ["-v", f"{k}={val}"]
    return subprocess.run(args, input=sql, text=True, capture_output=True, check=True).stdout.strip()

saved = {}
if os.path.exists(E["SECRETS"]):
    for l in open(E["SECRETS"]):
        if "=" in l and not l.startswith("#"):
            k, v = l.rstrip("\n").split("=", 1); saved[k] = v

tenant_id = E["EXISTING"]
if not tenant_id:
    tenant_id = uuid7()
    whsec = "whsec_" + secrets.token_hex(32) if E["WEBHOOK_URL"] else ""
    key = "dk_" + secrets.token_hex(32)
    psql("""BEGIN;
INSERT INTO tenants (id, created_at, updated_at, slug, name, brand, account, nameservers, soa_contact, status,
                     require_connect, webhook_url, webhook_secret)
VALUES (:'id', now(), now(), :'slug', :'name', :'slug', :'slug', :'ns', :'soa', 'active', false, :'wurl', :'wsec');
INSERT INTO api_keys (id, created_at, updated_at, tenant_id, name, key_prefix, key_hash)
VALUES (:'kid', now(), now(), :'id', :'kname', :'kpre', :'khash');
COMMIT;""", id=tenant_id, slug=E["SLUG"], name=E["NAME"], ns=E["NAMESERVERS"], soa=E["SOA_CONTACT"],
         wurl=E["WEBHOOK_URL"], wsec=whsec, kid=uuid7(), kname=f"{E['SLUG']}-nextdp-core",
         kpre=key[:12], khash=hashlib.sha256(key.encode()).hexdigest())
    lines = [f"# dns-service tenant {E['SLUG']} (created {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})",
             f"TENANT_ID={tenant_id}", f"TENANT_SLUG={E['SLUG']}", f"TENANT_ACCOUNT={E['SLUG']}",
             f"DNS_NAMESERVERS={E['NAMESERVERS']}", f"API_KEY={key}", f"API_KEY_PREFIX={key[:12]}",
             f"WEBHOOK_URL={E['WEBHOOK_URL']}", f"WEBHOOK_SECRET={whsec}", ""]
    fd = os.open(E["SECRETS"] + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines))
    os.replace(E["SECRETS"] + ".tmp", E["SECRETS"])
    print(f"  created tenant {tenant_id} + API key {key[:12]}... (secrets in {E['SECRETS']})")
    saved["API_KEY"] = key
else:
    print(f"  tenant exists; using the key saved in {E['SECRETS']}")

key = saved.get("API_KEY", "")
if not key:
    raise SystemExit("FATAL: no API key saved for this tenant")
req = urllib.request.Request("http://127.0.0.1:8080/api/v1/whoami", headers={"X-API-Key": key, "Accept": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        w = (json.loads(r.read()).get("data") or {})
except urllib.error.HTTPError as e:
    raise SystemExit(f"FATAL: /whoami rejected the key (HTTP {e.code})")
if w.get("tenant_id") != tenant_id or w.get("account") != E["SLUG"]:
    raise SystemExit(f"FATAL: /whoami mismatch: {w}")
print(f"  /whoami OK: account={w.get('account')} tenant_id={w.get('tenant_id')}")
print("TENANT_OK")
PY
