#!/usr/bin/env bash
# Configure Next iDP outbound ZeptoMail (Zoho CPaaS India) in /etc/nextidp/env on Apps-Core-VM,
# turn off staging N1_DEV_OUTBOX, restart nextidp + nextidp-worker, and verify boot logs/health.
# Reads the API key from a 0600 temp file (argument $1) and shreds/removes it cleanly.
set -Eeuo pipefail

KEY_FILE="${1:?path to file containing Zoho-enczapikey token is required}"
ENV_FILE="/etc/nextidp/env"
MAIL_DRIVER="${MAIL_DRIVER:-zeptomail}"
MAIL_FROM_ADDRESS="${MAIL_FROM_ADDRESS:-noreply@nextidp.com}"
MAIL_FROM_NAME="${MAIL_FROM_NAME:-Next iDP}"
MAIL_API_BASE_URL="${MAIL_API_BASE_URL:-https://cpaas.zoho.in}"
MAIL_RETENTION_DAYS="${MAIL_RETENTION_DAYS:-90}"
N1_DEV_OUTBOX="${N1_DEV_OUTBOX:-false}"

sudo test -f "$ENV_FILE" || { echo "FATAL: missing $ENV_FILE" >&2; exit 1; }
[ -f "$KEY_FILE" ] || { echo "FATAL: missing key file $KEY_FILE" >&2; exit 1; }

cleanup() {
  rm -f -- "$KEY_FILE"
}
trap cleanup EXIT

sudo python3 - "$ENV_FILE" "$KEY_FILE" "$MAIL_DRIVER" "$MAIL_FROM_ADDRESS" "$MAIL_FROM_NAME" "$MAIL_API_BASE_URL" "$MAIL_RETENTION_DAYS" "$N1_DEV_OUTBOX" <<'PY'
import os, re, sys

env_path, key_path, driver, from_addr, from_name, base_url, retention, dev_outbox = sys.argv[1:9]
with open(key_path, "r", encoding="utf-8") as f:
    raw_key = f.read().strip()

# rapidgo-modules/mailapi/zeptomail.go prepends "Zoho-enczapikey " automatically.
api_key = re.sub(r"^Zoho-enczapikey\s+", "", raw_key, flags=re.IGNORECASE).strip()
if not api_key or len(api_key) < 20:
    raise SystemExit("FATAL: parsed ZeptoMail API key is empty or too short")

updates = {
    "MAIL_DRIVER": driver,
    "MAIL_FROM_ADDRESS": from_addr,
    "MAIL_FROM_NAME": f'"{from_name}"',
    "MAIL_API_BASE_URL": base_url.rstrip("/"),
    "MAIL_API_KEY": api_key,
    "MAIL_RETENTION_DAYS": retention,
    "N1_DEV_OUTBOX": dev_outbox,
}

with open(env_path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

seen = set()
out_lines = []
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in line:
        k = line.split("=", 1)[0].strip()
        if k in updates:
            out_lines.append(f"{k}={updates[k]}")
            seen.add(k)
            continue
    out_lines.append(line)

for k, v in updates.items():
    if k not in seen:
        out_lines.append(f"{k}={v}")

tmp_env = env_path + ".tmp"
fd = os.open(tmp_env, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out_lines) + "\n")
    os.replace(tmp_env, env_path)
except Exception:
    if os.path.exists(tmp_env):
        os.unlink(tmp_env)
    raise
PY

sudo chown root:nextidp "$ENV_FILE"
sudo chmod 640 "$ENV_FILE"

echo "==> Updated /etc/nextidp/env (non-secret mail keys):"
sudo grep -E '^(MAIL_DRIVER|MAIL_FROM_ADDRESS|MAIL_FROM_NAME|MAIL_API_BASE_URL|MAIL_RETENTION_DAYS|N1_DEV_OUTBOX)=' "$ENV_FILE"
echo "MAIL_API_KEY_SET=$(sudo grep -q '^MAIL_API_KEY=.\+' "$ENV_FILE" && echo true || echo false)"

echo "==> Restarting nextidp and nextidp-worker"
sudo systemctl restart nextidp nextidp-worker

for i in $(seq 1 20); do
  if out=$(curl -fsS -m 3 -H 'Host: nextidp.com' http://127.0.0.1:8080/health/version 2>/dev/null); then
    echo "healthy: $out"
    break
  fi
  [ "$i" -eq 20 ] && { echo "FATAL: health check failed" >&2; sudo journalctl -u nextidp -n 30 --no-pager; exit 1; }
  sleep 1
done

sleep 2
echo "==> Systemd state:"
systemctl is-active nextidp nextidp-worker
echo "==> Boot mail log lines (nextidp & nextidp-worker):"
sudo journalctl -u nextidp -n 20 --no-pager | grep -E '"msg":"mail"|N1_DEV_OUTBOX' || true
sudo journalctl -u nextidp-worker -n 20 --no-pager | grep -E '"msg":"mail"|N1_DEV_OUTBOX' || true
echo "==> Worker heartbeats in DB:"
sudo -u postgres psql -d nextidp -P pager=off -c "SELECT host, kind, pid, seen_at FROM worker_heartbeats WHERE kind='mail' ORDER BY seen_at DESC LIMIT 3;"
