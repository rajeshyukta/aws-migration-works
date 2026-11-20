#!/usr/bin/env bash
# Upsert AWS S3 storage settings from a 0600 temp env file ($1) into /etc/nextidp/env
# on Apps-Core-VM (43.204.42.99), drop stale R2_* keys, restart nextidp + nextidp-worker,
# and verify startup logs + health without echoing secrets.
set -Eeuo pipefail

S3_TMP_ENV="${1:?path to 0600 temp S3 env file is required}"
ENV_FILE="/etc/nextidp/env"

sudo test -f "$ENV_FILE" || { echo "FATAL: missing $ENV_FILE" >&2; exit 1; }
[ -f "$S3_TMP_ENV" ] || { echo "FATAL: missing temp env file $S3_TMP_ENV" >&2; exit 1; }

cleanup() {
  rm -f -- "$S3_TMP_ENV"
}
trap cleanup EXIT

sudo python3 - "$ENV_FILE" "$S3_TMP_ENV" <<'PY'
import os, sys

env_path, s3_path = sys.argv[1:3]
src = {}
with open(s3_path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        src[k.strip()] = v.strip()

required = ["AVATAR_STORE", "S3_BUCKET", "S3_REGION", "S3_KEY", "S3_SECRET", "N1_ASSETS_BASE_URL"]
missing = [k for k in required if not src.get(k)]
if missing:
    raise SystemExit(f"FATAL: missing required S3 vars: {missing}")

updates = {
    "AVATAR_STORE": src["AVATAR_STORE"],
    "S3_BUCKET": src["S3_BUCKET"],
    "S3_REGION": src["S3_REGION"],
    "S3_KEY": src["S3_KEY"],
    "S3_SECRET": src["S3_SECRET"],
    "S3_ENDPOINT": src.get("S3_ENDPOINT", ""),
    "S3_SSE": src.get("S3_SSE", "AES256"),
    "S3_ACL": src.get("S3_ACL", ""),
    "N1_ASSETS_KEY_PREFIX": src.get("N1_ASSETS_KEY_PREFIX", ""),
    "N1_ASSETS_BASE_URL": src["N1_ASSETS_BASE_URL"],
}

with open(env_path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

seen = set()
out_lines = []
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in line:
        k = line.split("=", 1)[0].strip()
        if k.startswith("R2_"):
            continue
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

echo "==> Updated /etc/nextidp/env (non-secret S3 keys):"
sudo grep -E '^(AVATAR_STORE|S3_BUCKET|S3_REGION|S3_ENDPOINT|S3_SSE|S3_ACL|N1_ASSETS_KEY_PREFIX|N1_ASSETS_BASE_URL)=' "$ENV_FILE"
echo "S3_KEY_SET=$(sudo grep -q '^S3_KEY=.\+' "$ENV_FILE" && echo true || echo false)"
echo "S3_SECRET_SET=$(sudo grep -q '^S3_SECRET=.\+' "$ENV_FILE" && echo true || echo false)"

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

sleep 1
echo "==> Systemd state:"
systemctl is-active nextidp nextidp-worker
echo "==> Boot avatar log line:"
sudo journalctl -u nextidp -n 20 --no-pager | grep -E '"msg":"avatar|"avatar:' || true
