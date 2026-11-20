#!/usr/bin/env bash
# Deploy NextDP Core (:8090) onto Apps-Core-VM (43.204.42.99)
set -euo pipefail

TARBALL="${TARBALL:?TARBALL must be set}"
APP=nextdp
APP_DIR=/srv/apps/$APP
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

echo "==> Unpack NextDP Core -> $REL"
sudo mkdir -p "$REL" "$APP_DIR/shared/storage"
sudo chown -R webapps:webapps "$APP_DIR/shared/storage"
sudo tar -xzf "$TARBALL" -C "$REL"
sudo chmod +x "$REL/nextdp"
sudo ln -sfn "$APP_DIR/shared/storage" "$REL/storage"
sudo ln -sfn "$APP_DIR/shared/.env" "$REL/.env"
sudo chown -R webapps:webapps "$REL"
sudo chmod -R o+rX "$REL"

echo "==> Ensure $ENV_FILE"
if ! sudo test -f "$ENV_FILE"; then
  APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  ENCRYPTION_KEY="base64:$(openssl rand -base64 48 | tr -d '\n')"
  JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
  sudo tee "$ENV_FILE" >/dev/null <<EOF
APP_NAME=NextDP
APP_ENV=production
APP_DEBUG=false
APP_PORT=8090
APP_URL=https://core.nextdp.com
APP_KEY=${APP_KEY}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
RAPIDGO_MODE=all
GIN_MODE=release
HOST_CORE=core.nextdp.com
CORE_BASE_URL=https://core.nextdp.com

DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=nextdp_core
DB_USER=nextdp_core
DB_PASSWORD=${PG_PASS_NEXTDP_CORE}
DB_SSL_MODE=disable

JWT_SECRET=${JWT_SECRET}
SESSION_DRIVER=redis
SESSION_LIFETIME=120m
SESSION_SECURE=true
SESSION_SAMESITE=lax
SESSION_COOKIE=__Host-nextdp_session
SESSION_PATH=/
CACHE_DRIVER=memory
CACHE_PREFIX=nextdp_

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=1

QUEUE_DRIVER=database
QUEUE_TABLE=go_jobs
QUEUE_FAILED_TABLE=go_failed_jobs
QUEUE_DEFAULT=default
QUEUE_MAX_ATTEMPTS=3
QUEUE_RETRY_DELAY=30s
QUEUE_TIMEOUT=150s
QUEUE_POLL_INTERVAL=3s

STORAGE_DRIVER=local
DNS_BACKEND=service
MAIL_FROM_ADDRESS=noreply@nextdp.com
MAIL_FROM_NAME=NextDP
LOG_LEVEL=info
LOG_FORMAT=json
LOG_OUTPUT=stdout
SERVER_READ_TIMEOUT=30s
SERVER_WRITE_TIMEOUT=60s
SERVER_IDLE_TIMEOUT=120s
TRUSTED_PROXIES=127.0.0.1,::1
ACCESSGUARD_TRUSTED_PROXIES=127.0.0.0/8,::1/128
HEALTH_EXPOSE_VERSION=true
EOF
  sudo chown webapps:webapps "$ENV_FILE"
  sudo chmod 640 "$ENV_FILE"
fi

if ! sudo grep -qE '^ENCRYPTION_KEY=.+' "$ENV_FILE"; then
  ENC_KEY="base64:$(openssl rand -base64 48 | tr -d '\n')"
  printf '\nENCRYPTION_KEY=%s\n' "$ENC_KEY" | sudo tee -a "$ENV_FILE" >/dev/null
  unset ENC_KEY
  sudo chown webapps:webapps "$ENV_FILE"
  sudo chmod 640 "$ENV_FILE"
fi

echo "==> Install systemd units (nextdp, nextdp-worker, nextdp-scheduler)"
sudo tee /etc/systemd/system/nextdp.service >/dev/null <<'EOF'
[Unit]
Description=NextDP Core Platform
After=network-online.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/nextdp/current
ExecStart=/srv/apps/nextdp/current/nextdp serve
EnvironmentFile=/srv/apps/nextdp/shared/.env
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/srv/apps/nextdp/shared/storage
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/nextdp-worker.service >/dev/null <<'EOF'
[Unit]
Description=NextDP Core Platform - queue worker
After=network-online.target postgresql.service redis-server.service nextdp.service
Wants=postgresql.service redis-server.service

[Service]
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/nextdp/current
ExecStart=/srv/apps/nextdp/current/nextdp work -q default -w 2
EnvironmentFile=/srv/apps/nextdp/shared/.env
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/srv/apps/nextdp/shared/storage
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/nextdp-scheduler.service >/dev/null <<'EOF'
[Unit]
Description=NextDP Core Platform - task scheduler
After=network-online.target postgresql.service redis-server.service nextdp.service
Wants=postgresql.service redis-server.service

[Service]
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/nextdp/current
ExecStart=/srv/apps/nextdp/current/nextdp schedule:run
EnvironmentFile=/srv/apps/nextdp/shared/.env
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/srv/apps/nextdp/shared/storage
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nextdp nextdp-worker nextdp-scheduler >/dev/null 2>&1 || true

echo "==> Bootstrap pre-Go base schema if DB is brand-new"
if [ -n "${BASE_SQL:-}" ] && [ -f "$BASE_SQL" ]; then
  HAS_EL=$(PGPASSWORD="$PG_PASS_NEXTDP_CORE" psql -h 127.0.0.1 -U nextdp_core -d nextdp_core -Atc "SELECT to_regclass('public.email_layouts')" || true)
  if [ -z "$HAS_EL" ]; then
    echo "    applying $BASE_SQL (fresh DB detected)..."
    PGPASSWORD="$PG_PASS_NEXTDP_CORE" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U nextdp_core -d nextdp_core -f "$BASE_SQL" >/dev/null
  fi
fi

echo "==> Run migrations"
if ! (cd "$REL" && sudo -u webapps ./nextdp migrate); then
  echo "FATAL: nextdp migrate failed"
  exit 1
fi

echo "==> Flip current & restart"
sudo ln -sfn "$REL" "$APP_DIR/current"
sudo systemctl restart nextdp nextdp-worker nextdp-scheduler

for i in 1 2 3 4 5; do
  if out=$(curl -fsS -m 3 http://127.0.0.1:8090/health 2>/dev/null); then
    echo "healthy: $out"
    sudo systemctl is-active nextdp nextdp-worker nextdp-scheduler
    ls -1dt "$APP_DIR"/releases/* | tail -n +6 | xargs -r sudo rm -rf
    exit 0
  fi
  sleep 2
done

echo "!! Health check failed"
sudo journalctl -u nextdp -n 40 --no-pager || true
if [ -n "$PREV" ] && [ -d "$PREV" ]; then
  sudo ln -sfn "$PREV" "$APP_DIR/current"
  sudo systemctl restart nextdp nextdp-worker nextdp-scheduler
fi
exit 1
