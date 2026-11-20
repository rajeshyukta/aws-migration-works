#!/usr/bin/env bash
# Deploy LocalCen (:8092) onto Apps-Core-VM (43.204.42.99) in Shared-Caddy mode
set -euo pipefail

STAGE_DIR="${STAGE_DIR:?STAGE_DIR must be set}"
TARBALL="$STAGE_DIR/localcen-release.tar.gz"
APP_DIR=/srv/apps/localcen
ENV_FILE=$APP_DIR/shared/.env
SECRETS_FILE=/root/.apps-core-secrets.env
TS=$(date -u +%Y%m%dT%H%M%S)
REL=$APP_DIR/releases/$TS
PREV=$(readlink -f "$APP_DIR/current" 2>/dev/null || true)

[ -f "$TARBALL" ] || { echo "FATAL: missing $TARBALL"; exit 1; }
sudo test -f "$SECRETS_FILE" || { echo "FATAL: missing $SECRETS_FILE"; exit 1; }

set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_FILE")
set +a

echo "==> Unpack LocalCen -> $REL"
sudo mkdir -p "$REL"
sudo tar -xzf "$TARBALL" -C "$REL"
sudo chown -R webapps:webapps "$REL"
sudo chmod -R u=rwX,go=rX "$REL"
sudo chmod 755 "$REL/localcen"

echo "==> Ensure $ENV_FILE (APP_PORT=8092)"
if ! sudo test -f "$ENV_FILE"; then
  APP_KEY=$(openssl rand -base64 48 | tr -d '\n')
  JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
  sudo tee "$ENV_FILE" >/dev/null <<EOF
APP_NAME=localcen
APP_ENV=production
APP_DEBUG=false
APP_PORT=8092
APP_URL=http://127.0.0.1:8092
APP_KEY=${APP_KEY}
RAPIDGO_MODE=all
GIN_MODE=release
APP_SERVICE_NAME=localcen
CONNECT_ENFORCE=false
IDP_LOGIN=false
HEALTH_EXPOSE_VERSION=true

DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=localcen_db
DB_USER=localcen_u
DB_PASSWORD=${PG_PASS_LOCALCEN}
DB_SSL_MODE=disable

JWT_SECRET=${JWT_SECRET}
JWT_EXPIRY=900
JWT_REFRESH_TOKEN_TTL=720h
SESSION_IDLE=168h
SESSION_MAX=2160h
WEBHOOK_TIMEOUT=5s
CORS_ALLOWED_ORIGINS=https://admin.localcen.cconsole.com,https://localcen.cconsole.com
MAX_UPLOAD_MB=8
ALLOWED_MEDIA=jpg,jpeg,png,gif,webp
LANG_PUBLISH_DIR=/srv/apps/localcen/shared/lang
CADDY_SYNC_SPOOL=/srv/apps/localcen/shared/storage/caddy-sync-spool
LOCAL_HOST_SERVER_IPS=43.204.42.99
LOCAL_HOST_TLS_ADDR=127.0.0.1:443
TRUSTED_PROXIES=127.0.0.1,::1
RATE_LIMIT_MACHINE=120-M
API_LOG_RETENTION_DAYS=90
IDP_ISSUER=https://accounts.cconsole.com

SESSION_DRIVER=db
SESSION_COOKIE=__Host-sid
SESSION_SECURE=true
SESSION_LIFETIME=720m
SESSION_ABSOLUTE_LIFETIME=1440m
CACHE_DRIVER=memory
CACHE_PREFIX=localcen_
QUEUE_DRIVER=database
QUEUE_DEFAULT=default
QUEUE_TABLE=jobs
QUEUE_FAILED_TABLE=failed_jobs
QUEUE_MAX_ATTEMPTS=3
QUEUE_RETRY_DELAY=30s
QUEUE_TIMEOUT=60s
QUEUE_POLL_INTERVAL=3s
LOG_LEVEL=info
LOG_FORMAT=json
LOG_OUTPUT=stdout
SERVER_READ_TIMEOUT=10s
SERVER_WRITE_TIMEOUT=10s
SERVER_IDLE_TIMEOUT=120s
EOF
  sudo chown webapps:webapps "$ENV_FILE"
  sudo chmod 640 "$ENV_FILE"
fi

sudo mkdir -p "$APP_DIR/shared/lang" "$APP_DIR/shared/storage/caddy-sync-spool"
sudo chown -R webapps:webapps "$APP_DIR/shared/lang" "$APP_DIR/shared/storage/caddy-sync-spool"

echo "==> Install systemd units (localcen, worker, cleanup timer, shared-caddy sync)"
sudo tee /etc/systemd/system/localcen.service >/dev/null <<'EOF'
[Unit]
Description=LocalCen service
After=network-online.target postgresql.service
Wants=postgresql.service

[Service]
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/localcen/current
ExecStart=/srv/apps/localcen/current/localcen serve
EnvironmentFile=/srv/apps/localcen/shared/.env
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/srv/apps/localcen/shared/storage /srv/apps/localcen/shared/lang /srv/apps/localcen/shared/certs
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/localcen-worker.service >/dev/null <<'EOF'
[Unit]
Description=LocalCen service - queue worker
After=network-online.target postgresql.service localcen.service
Wants=postgresql.service

[Service]
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/localcen/current
ExecStart=/srv/apps/localcen/current/localcen work -q default --timeout 60 -w 2
EnvironmentFile=/srv/apps/localcen/shared/.env
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/srv/apps/localcen/shared/storage /srv/apps/localcen/shared/lang /srv/apps/localcen/shared/certs
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

echo "==> Run migrations"
set -a
# shellcheck disable=SC1090
source <(sudo cat "$ENV_FILE")
set +a
(cd "$REL" && sudo -E -u webapps ./localcen migrate)

echo "==> Install shared-caddy sync & cleanup timer"
sudo cp "$STAGE_DIR/caddy-hosts-sync.sh" /tmp/caddy-hosts-sync.sh
sudo sed -i 's/\r$//; s|^UPSTREAM=.*|UPSTREAM=127.0.0.1:8092|' /tmp/caddy-hosts-sync.sh
sudo bash -c "sed 's/\r$//' '$STAGE_DIR/caddy-hosts-setup.sh' | bash"
sudo bash -c "sed 's/\r$//' '$STAGE_DIR/cleanup-setup.sh' | bash"
sudo rm -f /tmp/caddy-hosts-sync.sh

sudo systemctl daemon-reload
sudo systemctl enable localcen.service localcen-worker.service >/dev/null 2>&1 || true

echo "==> Flip current & restart"
sudo ln -sfn "$REL" "$APP_DIR/current"
sudo systemctl restart localcen.service localcen-worker.service

for i in 1 2 3 4 5; do
  if out=$(curl -fsS --max-time 5 http://127.0.0.1:8092/healthz 2>/dev/null); then
    echo "healthy: $out"
    sudo systemctl is-active localcen localcen-worker localcen-caddy-sync.path localcen-caddy-sync.timer localcen-cleanup.timer
    ls -1dt "$APP_DIR"/releases/* | tail -n +6 | xargs -r sudo rm -rf
    exit 0
  fi
  sleep 2
done

echo "!! Health check failed"
sudo journalctl -u localcen -n 40 --no-pager || true
if [ -n "$PREV" ] && [ -d "$PREV" ]; then
  sudo ln -sfn "$PREV" "$APP_DIR/current"
  sudo systemctl restart localcen.service localcen-worker.service
fi
exit 1
