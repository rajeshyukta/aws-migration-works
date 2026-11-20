#!/usr/bin/env bash
# Configure Zoho CPaaS / ZeptoMail (https://cpaas.zoho.in) in /srv/apps/nextdp/shared/.env
# on Apps-Core-VM (43.204.42.99) without echoing secret keys to stdout,
# restart nextdp, nextdp-worker, and nextdp-scheduler, and verify live EmailService delivery.
set -Eeuo pipefail

KEY_FILE="${1:?path to 0600 file containing Zoho-enczapikey token is required}"
ENV_FILE="/srv/apps/nextdp/shared/.env"
MAIL_API_PROVIDER="${MAIL_API_PROVIDER:-zeptomail}"
ZEPTOMAIL_BASE_URL="${ZEPTOMAIL_BASE_URL:-https://cpaas.zoho.in}"
MAIL_FROM_ADDRESS="${MAIL_FROM_ADDRESS:-noreply@nextdp.com}"
MAIL_FROM_NAME="${MAIL_FROM_NAME:-NextDP}"

cleanup() {
  rm -f -- "$KEY_FILE"
}
trap cleanup EXIT

sudo test -f "$ENV_FILE" || { echo "FATAL: missing $ENV_FILE" >&2; exit 1; }
[ -f "$KEY_FILE" ] || { echo "FATAL: missing key file $KEY_FILE" >&2; exit 1; }

sudo python3 - "$ENV_FILE" "$KEY_FILE" "$MAIL_API_PROVIDER" "$ZEPTOMAIL_BASE_URL" "$MAIL_FROM_ADDRESS" "$MAIL_FROM_NAME" <<'PY'
import os, re, sys

env_path, key_path, provider, base_url, from_addr, from_name = sys.argv[1:7]
with open(key_path, "r", encoding="utf-8") as f:
    raw_key = f.read().strip()

api_key = re.sub(r"^Zoho-enczapikey\s+", "", raw_key, flags=re.IGNORECASE).strip()
if not api_key or len(api_key) < 20:
    raise SystemExit("FATAL: parsed ZeptoMail API key is empty or too short")

updates = {
    "MAIL_API_PROVIDER": provider,
    "ZEPTOMAIL_BASE_URL": base_url.rstrip("/"),
    "ZEPTOMAIL_API_KEY": api_key,
    "MAIL_FROM_ADDRESS": from_addr,
    "MAIL_FROM_NAME": from_name,
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
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
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
sudo chmod 640 "$ENV_FILE"

echo "==> Updated /srv/apps/nextdp/shared/.env (non-secret mail keys):"
sudo grep -E '^(MAIL_API_PROVIDER|ZEPTOMAIL_BASE_URL|MAIL_FROM_ADDRESS|MAIL_FROM_NAME)=' "$ENV_FILE"
echo "ZEPTOMAIL_API_KEY_SET=$(sudo grep -q '^ZEPTOMAIL_API_KEY=.\+' "$ENV_FILE" && echo true || echo false)"

echo "==> Restarting nextdp, nextdp-worker, and nextdp-scheduler"
sudo systemctl restart nextdp nextdp-worker nextdp-scheduler
sleep 3
systemctl is-active nextdp nextdp-worker nextdp-scheduler

for i in $(seq 1 20); do
  if out=$(curl -fsS -m 3 http://127.0.0.1:8090/healthz 2>/dev/null || curl -fsS -m 3 https://core.nextdp.com/healthz 2>/dev/null); then
    echo "health: $out"
    break
  fi
  sleep 1
done

echo "==> Checking recent nextdp startup logs for mail warnings:"
sudo journalctl -u nextdp -u nextdp-worker --since "15 sec ago" --no-pager | grep -iE 'mail sender not configured|email' || echo "No unconfigured-mailer warnings on boot"
