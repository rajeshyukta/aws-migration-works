#!/usr/bin/env bash
# Runs on Apps-Core-VM. Connects a NextDP Core brand to its dns-service tenant (what the core admin
# "Brand > Domains > DNS service" panel + "Provision webhook" button do), by script:
#   1. checks the tenant API key against dns-service (GET /api/v1/whoami)
#   2. seals the API key with NextDP Core's keyring (AES-256-GCM, HKDF of ENCRYPTION_KEY/APP_KEY,
#      same format as rapidgo core/encryption) and upserts brand_service_connections kind=dns
#   3. (WEBHOOK=1) points the tenant webhook at https://<console_domain>/webhooks/dns, rotates the
#      signing secret, seals and stores it, and sends a signed test ping (must come back delivered).
#      NOTE 2026-11-20: dns-service runs with Next iDP console login, so its webhook endpoints accept
#      only a console session, not the API key (HTTP 403). Use -NoWebhook and set the webhook in the
#      consoles (docs/azure-r2-restore.md section 4).
# Secrets are read from files and never printed. Env: BRAND_ID, API_KEY_FILE (0600, the key only),
# DNS_BASE_URL (https://dns.cconsole.com), NAMESERVERS ("ns1.nextdp.com ns2.nextdp.com"), WEBHOOK=1
set -Eeuo pipefail
exec 2>&1

BRAND_ID="${BRAND_ID:?BRAND_ID required}"
API_KEY_FILE="${API_KEY_FILE:?API_KEY_FILE required}"
DNS_BASE_URL="${DNS_BASE_URL:-https://dns.cconsole.com}"
NAMESERVERS="${NAMESERVERS:-ns1.nextdp.com ns2.nextdp.com}"
WEBHOOK="${WEBHOOK:-1}"
trap 'rm -f "$API_KEY_FILE"' EXIT
[[ "$BRAND_ID" =~ ^[0-9a-f-]{36}$ ]] || { echo "FATAL: invalid BRAND_ID"; exit 1; }
[[ "$DNS_BASE_URL" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || { echo "FATAL: invalid DNS_BASE_URL"; exit 1; }
[ -s "$API_KEY_FILE" ] || { echo "FATAL: API key file missing"; exit 1; }
python3 -c "import cryptography" 2>/dev/null || { echo "FATAL: python3-cryptography missing (apt install python3-cryptography)"; exit 1; }

sudo env BRAND_ID="$BRAND_ID" API_KEY_FILE="$API_KEY_FILE" DNS_BASE_URL="$DNS_BASE_URL" NAMESERVERS="$NAMESERVERS" WEBHOOK="$WEBHOOK" \
  python3 - <<'PY'
import base64, json, os, subprocess, sys, urllib.error, urllib.request, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

ENV_FILE = "/srv/apps/nextdp/shared/.env"
brand_id, base = os.environ["BRAND_ID"], os.environ["DNS_BASE_URL"].rstrip("/")
nameservers = "\n".join(os.environ["NAMESERVERS"].split())
api_key = open(os.environ["API_KEY_FILE"]).read().strip()

def env_file(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            k, v = s.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k.strip()] = v
    return out

cfg = env_file(ENV_FILE)
secret = cfg.get("ENCRYPTION_KEY") or cfg.get("APP_KEY") or ""
material = base64.b64decode(secret[7:]) if secret.startswith("base64:") else secret.encode()
if len(material) < 32:
    sys.exit("FATAL: ENCRYPTION_KEY/APP_KEY missing or shorter than 32 bytes")
key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"rapidgo field encryption v1").derive(material)

def seal(plain):
    nonce = os.urandom(12)
    return base64.urlsafe_b64encode(nonce + AESGCM(key).encrypt(nonce, plain.encode(), None)).decode()

def unseal(token):
    raw = base64.urlsafe_b64decode(token)
    return AESGCM(key).decrypt(raw[:12], raw[12:], None).decode()

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"X-API-Key": api_key, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}

def psql(sql, **params):
    args = ["sudo", "-u", "postgres", "psql", "-p", "5432", "-d", "nextdp_core", "-XAt", "-v", "ON_ERROR_STOP=1"]
    for k, v in params.items():
        args += ["-v", f"{k}={v}"]
    return subprocess.run(args, input=sql, text=True, capture_output=True, check=True).stdout.strip()

brand = psql("SELECT slug || '|' || coalesce(console_domain,'') FROM brands WHERE id = :'b';", b=brand_id)
if not brand:
    sys.exit("FATAL: brand not found")
slug, console = brand.split("|", 1)

st, who = api("GET", "/api/v1/whoami")
if st != 200 or not who.get("success"):
    sys.exit(f"FATAL: dns-service rejected the API key (HTTP {st})")
w = who.get("data") or {}
print(f"  dns-service tenant: account={w.get('account')} tenant_id={w.get('tenant_id')}")

sealed = seal(api_key)
assert unseal(sealed) == api_key
existing = psql("SELECT id FROM brand_service_connections WHERE brand_id = :'b' AND kind = 'dns';", b=brand_id)
if existing:
    psql("UPDATE brand_service_connections SET base_url = :'u', api_key_enc = :'k', nameservers = :'n', active = true, updated_at = now() WHERE id = :'i';",
         u=base, k=sealed, n=nameservers, i=existing)
    print(f"  updated dns connection {existing} for brand {slug}")
else:
    new_id = str(uuid.uuid4())
    psql("INSERT INTO brand_service_connections (id, brand_id, kind, base_url, api_key_enc, nameservers, webhook_secret_enc, config, active, created_at, updated_at) "
         "VALUES (:'i', :'b', 'dns', :'u', :'k', :'n', '', '', true, now(), now());",
         i=new_id, b=brand_id, u=base, k=sealed, n=nameservers)
    print(f"  created dns connection {new_id} for brand {slug}")

if os.environ.get("WEBHOOK") == "1":
    if not console:
        sys.exit("FATAL: brand has no console_domain")
    receiver = f"https://{console}/webhooks/dns"
    st, _ = api("PUT", "/api/v1/webhook", {"webhook_url": receiver})
    if st != 200:
        sys.exit(f"FATAL: set webhook URL failed (HTTP {st})" + (": dns-service webhook settings need a console session (iDP login); the DNS connection itself IS saved. Set the webhook in the consoles (docs/azure-r2-restore.md section 4)" if st == 403 else ""))
    st, rot = api("POST", "/api/v1/webhook/rotate-secret")
    wsecret = (rot.get("data") or {}).get("webhook_secret", "")
    if st != 200 or not wsecret:
        sys.exit(f"FATAL: rotate webhook secret failed (HTTP {st})")
    psql("UPDATE brand_service_connections SET webhook_secret_enc = :'s', updated_at = now() WHERE brand_id = :'b' AND kind = 'dns';",
         s=seal(wsecret), b=brand_id)
    del wsecret
    st, test = api("POST", "/api/v1/webhook/test")
    d = test.get("data") or {}
    print(f"  webhook {receiver}: test HTTP {st}, receiver status {d.get('status_code')}, delivered={d.get('ok')} {d.get('error') or ''}")
    if not d.get("ok"):
        sys.exit("FATAL: webhook test ping was not accepted by NextDP Core")
print("DNS_CONNECTION_OK")
PY
