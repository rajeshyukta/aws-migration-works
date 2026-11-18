#!/usr/bin/env bash
# Restore nextdp_mail PostgreSQL database from Cloudflare R2 (restic snapshot or raw S3 dump)
set -euo pipefail

ENV_FILE="${R2_ENV_FILE:-/tmp/.r2.env}"
REPO_PREFIX="${REPO_PREFIX:-}"
SNAPSHOT_ID="${SNAPSHOT_ID:-}"
RAW_OBJECT_KEY="${RAW_OBJECT_KEY:-}"
START_SERVICES="${START_SERVICES:-1}"
RESTORE_DIR="/tmp/r2-restore-$$"
APP_ENV="/opt/nextdp/config/.env"

cleanup() {
  rm -rf "$RESTORE_DIR" "$ENV_FILE"
}
trap cleanup EXIT

if [ ! -f "$ENV_FILE" ]; then
  echo "FATAL: R2 env file missing: $ENV_FILE" >&2
  exit 1
fi
if [ ! -f "$APP_ENV" ]; then
  echo "FATAL: App .env missing: $APP_ENV (run 02-build-and-deploy.ps1 first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a

if [ -z "${R2_ENDPOINT:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
R2_BUCKET="${R2_BUCKET:-nxtmngr-test}"
R2_ENDPOINT="$(python3 -c 'import os; from urllib.parse import urlparse; u=urlparse(os.environ.get("R2_ENDPOINT","").strip()); print((u.scheme+"://"+u.netloc) if u.scheme and u.netloc else os.environ.get("R2_ENDPOINT","").strip().rstrip("/"))')"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"

mkdir -p "$RESTORE_DIR"
chmod 700 "$RESTORE_DIR"

if [ -n "$RAW_OBJECT_KEY" ]; then
  echo "=== [1/5] Downloading raw object from R2 ==="
  export R2_ENDPOINT R2_BUCKET RAW_OBJECT_KEY RESTORE_DIR
  python3 - <<'PY'
import os, boto3
s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["R2_ENDPOINT"],
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name="auto",
)
dst = os.path.join(os.environ["RESTORE_DIR"], os.path.basename(os.environ["RAW_OBJECT_KEY"]))
s3.download_file(os.environ["R2_BUCKET"], os.environ["RAW_OBJECT_KEY"], dst)
print("Downloaded:", dst)
PY
else
  if [ -z "$REPO_PREFIX" ] || [ -z "$SNAPSHOT_ID" ]; then
    echo "FATAL: Specify REPO_PREFIX + SNAPSHOT_ID, or RAW_OBJECT_KEY." >&2
    exit 1
  fi
  if [ -z "${RESTIC_PASSWORD:-}" ]; then
    echo "FATAL: RESTIC_PASSWORD is required to restore from restic." >&2
    exit 1
  fi
  HOST_ONLY="${R2_ENDPOINT#https://}"
  HOST_ONLY="${HOST_ONLY#http://}"
  HOST_ONLY="${HOST_ONLY%/}"
  export RESTIC_PASSWORD
  export RESTIC_REPOSITORY="s3:${HOST_ONLY}/${R2_BUCKET}/${REPO_PREFIX}"

  echo "=== [1/5] Restoring snapshot ${SNAPSHOT_ID} from ${REPO_PREFIX} ==="
  restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --no-lock
fi

DUMP_FILE="$(find "$RESTORE_DIR" -type f \( -name '*.dump' -o -name '*.sql' \) | head -1)"
if [ -z "$DUMP_FILE" ]; then
  ZIP_FILE="$(find "$RESTORE_DIR" -type f -name '*.zip' | head -1)"
  if [ -n "$ZIP_FILE" ]; then
    python3 -m zipfile -e "$ZIP_FILE" "$RESTORE_DIR/unzipped"
    DUMP_FILE="$(find "$RESTORE_DIR/unzipped" -type f \( -name '*.dump' -o -name '*.sql' \) | head -1)"
  fi
fi

if [ -z "$DUMP_FILE" ]; then
  echo "FATAL: No .dump or .sql file found inside restored content." >&2
  find "$RESTORE_DIR" -maxdepth 4 -type f
  exit 1
fi
echo "  Found dump: $(basename "$DUMP_FILE") ($(stat -c%s "$DUMP_FILE") bytes)"

echo "=== [2/5] Stopping NextDP Mail units before DB restore ==="
sudo systemctl stop nextdp-scheduler nextdp-worker nextdp 2>/dev/null || true

DB_PW="$(grep -E '^DB_PASSWORD=' "$APP_ENV" | head -1 | cut -d= -f2- | tr -d '\r\"')"
if [ -z "$DB_PW" ]; then
  echo "FATAL: DB_PASSWORD missing from $APP_ENV" >&2
  exit 1
fi

echo "=== [3/5] Recreating nextdp_mail database and replaying dump ==="
cd /tmp
sudo -u postgres psql -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'nextdp_mail' AND pid <> pg_backend_pid();"
sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS nextdp_mail;"
sudo -u postgres psql -q -c "ALTER USER nextdp_mail WITH PASSWORD '${DB_PW}';"
sudo -u postgres psql -q -c "CREATE DATABASE nextdp_mail OWNER nextdp_mail;"
unset DB_PW

if [[ "$DUMP_FILE" == *.sql ]]; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d nextdp_mail -f "$DUMP_FILE" >/dev/null
else
  sudo -u postgres pg_restore -d nextdp_mail --no-owner --no-acl --role=nextdp_mail "$DUMP_FILE" 2> >(grep -viE 'already exists|warning' >&2 || true) || true
fi

TABLE_CNT="$(sudo -u postgres psql -d nextdp_mail -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")"
echo "  Restored public tables: ${TABLE_CNT}"
if [ "${TABLE_CNT:-0}" -lt 10 ]; then
  echo "FATAL: Expected >=10 restored tables, got ${TABLE_CNT}." >&2
  exit 1
fi

echo "=== [4/5] Running nextdp migrate & verifying table counts ==="
(cd /opt/nextdp/config && /opt/nextdp/bin/nextdp migrate)

sudo -u postgres psql -d nextdp_mail -At \
  -c "SELECT 'organizations='||count(*) FROM organizations" \
  -c "SELECT 'domains='||count(*) FROM domains" \
  -c "SELECT 'users='||count(*) FROM users" \
  -c "SELECT 'mailboxes='||count(*) FROM mailboxes" \
  -c "SELECT 'messages='||count(*) FROM messages" \
  -c "SELECT 'raw_emails='||count(*) FROM raw_emails" \
  -c "SELECT 'attachments='||count(*) FROM attachments"

if [ "$START_SERVICES" = "1" ]; then
  echo "=== [5/5] Starting NextDP Mail services ==="
  sudo systemctl enable nextdp nextdp-worker nextdp-scheduler
  sudo systemctl restart nextdp nextdp-worker nextdp-scheduler
  sleep 3
  systemctl is-active nextdp nextdp-worker nextdp-scheduler caddy postgresql redis-server
  curl -sS --max-time 5 http://127.0.0.1:8080/api/health/ready; echo ""
fi
echo "=== Restore complete ==="
