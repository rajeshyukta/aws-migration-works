#!/usr/bin/env bash
# Wire Next iDP (cconsole realm at https://accounts.cconsole.com) into dns-service on DNS-VM:
# 1) Links existing dns_db.tenants (presencive, nextdp) to their Next iDP organization IDs
# 2) Updates /srv/apps/dns-service/shared/.env with IDP_* vars and IDP_LOGIN=true
# 3) Restarts dns-service + scheduler and verifies boot logs + health + OIDC redirects.
set -Eeuo pipefail

SECRETS_IN="${1:?path to 0600 temp cconsole-realm.env is required}"
ENV_FILE="/srv/apps/dns-service/shared/.env"

cleanup() {
  rm -f -- "$SECRETS_IN"
}
trap cleanup EXIT

sudo test -f "$ENV_FILE" || { echo "FATAL: missing $ENV_FILE" >&2; exit 1; }
[ -f "$SECRETS_IN" ] || { echo "FATAL: missing input file $SECRETS_IN" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$SECRETS_IN"
set +a

echo "==> Linking dns_db tenants (presencive, nextdp) to Next iDP org IDs"
sudo -u postgres psql -d dns_db -v ON_ERROR_STOP=1 -v pres_org="$ORG_PRESENCIVE_ID" -v nextdp_org="$ORG_NEXTDP_ID" <<'SQL'
UPDATE tenants SET idp_org_id = :'pres_org'   WHERE slug = 'presencive' AND (idp_org_id IS NULL OR idp_org_id = '');
UPDATE tenants SET idp_org_id = :'nextdp_org' WHERE slug = 'nextdp'     AND (idp_org_id IS NULL OR idp_org_id = '');
SELECT slug, account, idp_org_id, status FROM tenants ORDER BY slug;
SQL

echo "==> Updating $ENV_FILE (without printing secrets)"
sudo python3 - "$ENV_FILE" "$SECRETS_IN" <<'PY'
import os, sys

env_path, src_path = sys.argv[1:3]
src = {}
with open(src_path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            src[k.strip()] = v.strip()

required = [
    "IDP_ISSUER",
    "IDP_REALM_ID",
    "IDP_CONSOLE_CLIENT_ID",
    "IDP_CONSOLE_CLIENT_SECRET",
    "IDP_ADMIN_CLIENT_ID",
    "IDP_ADMIN_CLIENT_SECRET",
    "IDP_API_KEY",
    "IDP_WEBHOOK_SECRET",
]
missing = [k for k in required if not src.get(k)]
if missing:
    raise SystemExit(f"FATAL: missing keys in source env: {missing}")

updates = {
    "IDP_ISSUER": src["IDP_ISSUER"],
    "IDP_REALM_ID": src["IDP_REALM_ID"],
    "IDP_CONSOLE_CLIENT_ID": src["IDP_CONSOLE_CLIENT_ID"],
    "IDP_CONSOLE_CLIENT_SECRET": src["IDP_CONSOLE_CLIENT_SECRET"],
    "IDP_ADMIN_CLIENT_ID": src["IDP_ADMIN_CLIENT_ID"],
    "IDP_ADMIN_CLIENT_SECRET": src["IDP_ADMIN_CLIENT_SECRET"],
    "IDP_API_KEY": src["IDP_API_KEY"],
    "IDP_WEBHOOK_SECRET": src["IDP_WEBHOOK_SECRET"],
    "IDP_PUBLIC_ORIGIN": "https://dns.cconsole.com",
    "IDP_OWNER_CONTACT": "admin@cconsole.com",
    "IDP_LOGIN": "true",
}

with open(env_path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

seen = set()
out = []
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in line:
        k = line.split("=", 1)[0].strip()
        if k in updates:
            out.append(f"{k}={updates[k]}")
            seen.add(k)
            continue
    out.append(line)

for k, v in updates.items():
    if k not in seen:
        out.append(f"{k}={v}")

tmp = env_path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, env_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PY

sudo chown webapps:webapps "$ENV_FILE"
sudo chmod 600 "$ENV_FILE"

echo "==> Non-secret IDP_* flags now in $ENV_FILE:"
sudo grep -E '^(IDP_ISSUER|IDP_REALM_ID|IDP_CONSOLE_CLIENT_ID|IDP_ADMIN_CLIENT_ID|IDP_LOGIN|IDP_PUBLIC_ORIGIN|IDP_OWNER_CONTACT)=' "$ENV_FILE"
for sec_key in IDP_CONSOLE_CLIENT_SECRET IDP_ADMIN_CLIENT_SECRET IDP_API_KEY IDP_WEBHOOK_SECRET; do
  echo "${sec_key}_SET=$(sudo grep -q "^${sec_key}=.\+" "$ENV_FILE" && echo true || echo false)"
done

echo "==> Restarting dns-service and dns-service-scheduler"
sudo systemctl restart dns-service dns-service-scheduler
sleep 4
systemctl is-active dns-service dns-service-scheduler

echo "==> Health & Boot logs:"
curl -fsS --max-time 5 http://127.0.0.1:8080/health; echo ""
sudo journalctl -u dns-service -n 25 --no-pager | grep -iE 'idp|warn|error' || true
