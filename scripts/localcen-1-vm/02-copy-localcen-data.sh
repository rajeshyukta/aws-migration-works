#!/usr/bin/env bash
# One-time: install LocalCen's data + config copied from Apps-Core-VM onto LocalCen-1-VM.
# Stage (from 02-copy-localcen-data.ps1, dir 0700): localcen_db.dump, localcen.env (0600), shared.tar.gz.
#  - restores localcen_db only if it is still empty (refuses to overwrite data)
#  - installs .env only if none exists, with: new DB password (this VM), LOCAL_HOST_SERVER_IPS=3.111.132.3,
#    CADDY_SYNC_SPOOL removed (dedicated Caddy with on-demand TLS, no shared-Caddy sync)
# Never prints secret values.
set -Eeuo pipefail
exec 2>&1
STAGE_DIR="${STAGE_DIR:?}"
APP=/srv/apps/localcen
ENV_FILE=$APP/shared/.env
SECRETS_FILE=/root/.localcen-1-secrets.env
PUBLIC_IP=3.111.132.3
trap 'rm -rf "$STAGE_DIR"' EXIT
cd /tmp

echo "=== [1/3] database localcen_db ==="
tables=$(sudo -u postgres psql -XAt -d localcen_db -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
if [ "$tables" != 0 ]; then
  echo "  localcen_db already has $tables tables - not restoring"
else
  sudo install -o postgres -g postgres -m 0600 "$STAGE_DIR/localcen_db.dump" /tmp/.lc-restore.dump
  sudo -u postgres pg_restore -d localcen_db --no-owner --no-acl --role=localcen_u /tmp/.lc-restore.dump
  sudo rm -f /tmp/.lc-restore.dump
  sudo -u postgres psql -Xq -d localcen_db -c "GRANT ALL ON SCHEMA public TO localcen_u;"
  echo "  restored: $(sudo -u postgres psql -XAt -d localcen_db -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'") tables, migrations=$(sudo -u postgres psql -XAt -d localcen_db -c 'SELECT count(*) FROM schema_migrations'), shared_domains=$(sudo -u postgres psql -XAt -d localcen_db -c 'SELECT count(*) FROM shared_domains')"
fi
bad=$(sudo -u postgres psql -XAt -d localcen_db -c "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner<>'localcen_u'")
echo "  tables not owned by localcen_u: $bad"

echo "=== [2/3] .env ==="
if sudo test -f "$ENV_FILE"; then
  echo "  exists - kept"
else
  PW="$(sudo grep -E '^PG_PASS_LOCALCEN=' "$SECRETS_FILE" | cut -d= -f2-)"
  sudo PW="$PW" IP="$PUBLIC_IP" SRC="$STAGE_DIR/localcen.env" DST="$ENV_FILE" python3 - <<'PY'
import os
out, seen = [], set()
for line in open(os.environ["SRC"], encoding="utf-8").read().splitlines():
    k = line.split("=", 1)[0].strip()
    if k == "CADDY_SYNC_SPOOL":
        continue
    if k == "DB_PASSWORD":
        line = "DB_PASSWORD=" + os.environ["PW"]
    elif k == "LOCAL_HOST_SERVER_IPS":
        line = "LOCAL_HOST_SERVER_IPS=" + os.environ["IP"]
    elif k == "DB_HOST":
        line = "DB_HOST=127.0.0.1"
    seen.add(k)
    out.append(line)
if "LOCAL_HOST_SERVER_IPS" not in seen:
    out.append("LOCAL_HOST_SERVER_IPS=" + os.environ["IP"])
open(os.environ["DST"], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  unset PW
  sudo chown webapps:webapps "$ENV_FILE"; sudo chmod 0640 "$ENV_FILE"
  echo "  installed (DB password = this VM's, LOCAL_HOST_SERVER_IPS=$PUBLIC_IP, CADDY_SYNC_SPOOL removed)"
fi
sudo grep -E '^(APP_PORT|DB_HOST|DB_NAME|DB_USER|LOCAL_HOST_SERVER_IPS|LOCAL_HOST_TLS_ADDR|IDP_LOGIN|IDP_ISSUER|CORS_ALLOWED_ORIGINS)=' "$ENV_FILE" | sed 's/^/  /'
sudo grep -q '^CADDY_SYNC_SPOOL=' "$ENV_FILE" && echo "  WARNING: CADDY_SYNC_SPOOL still set" || true

echo "=== [3/3] shared files ==="
sudo tar -xzf "$STAGE_DIR/shared.tar.gz" -C "$APP/shared" --skip-old-files --exclude='./.env' --exclude='.env' --exclude='./storage/caddy-sync-spool*' --exclude='storage/caddy-sync-spool*'
sudo chown -R webapps:webapps "$APP/shared"; sudo chmod 750 "$APP/shared"
echo "  $(sudo find "$APP/shared" -type f | wc -l) files in shared/"
echo "COPY_OK"
