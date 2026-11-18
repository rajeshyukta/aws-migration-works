#!/usr/bin/env bash
# Remote installation step for NextDP Mail (called by 02-build-and-deploy.ps1)
set -euo pipefail

STAGE="${STAGE_DIR:-/tmp/nextdp-stage}"
START_SERVICES="${START_SERVICES:-0}"
REMOTE_DIR="/opt/nextdp"
ENV_FILE="${REMOTE_DIR}/config/.env"
TLS_DIR="${REMOTE_DIR}/config/tls"
CADDY_CERTS="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
MAIL_HOST="mail.nextdp.com"

if [ ! -d "$STAGE" ]; then
  echo "FATAL: stage dir missing: $STAGE" >&2
  exit 1
fi

echo "=== [1/6] Install Go binary ==="
if [ -f "$STAGE/nextdp" ]; then
  if [ -f "${REMOTE_DIR}/bin/nextdp" ]; then
    cp -f "${REMOTE_DIR}/bin/nextdp" "${REMOTE_DIR}/bin/nextdp.old"
  fi
  install -o ubuntu -g ubuntu -m 0755 "$STAGE/nextdp" "${REMOTE_DIR}/bin/nextdp"
fi

echo "=== [2/6] Install React SPAs ==="
if [ -f "$STAGE/web.tar.gz" ]; then
  for spa in webmail admin super-admin; do
    mkdir -p "${REMOTE_DIR}/web/${spa}"
    rm -rf "${REMOTE_DIR}/web/${spa}/"*
  done
  tar -xzf "$STAGE/web.tar.gz" -C "${REMOTE_DIR}/web"
  chown -R ubuntu:ubuntu "${REMOTE_DIR}/web"
  find "${REMOTE_DIR}/web" -type d -exec chmod 755 {} +
  find "${REMOTE_DIR}/web" -type f -exec chmod 644 {} +
fi

echo "=== [3/6] Initialize /opt/nextdp/config/.env if missing ==="
if [ ! -f "$ENV_FILE" ]; then
  DB_PW="$(openssl rand -hex 24)"
  APP_KEY_VAL="$(openssl rand -hex 32)"
  SESSION_SEC="$(openssl rand -hex 32)"
  JWT_SEC="$(openssl rand -hex 32)"
  MIG_KEY="$(openssl rand -hex 32)"
  ADMIN_PW="$(openssl rand -base64 18 | tr -d '/+=')"
  REDIS_PW="$(sudo awk '/^requirepass / {print $2; exit}' /etc/redis/nextdp-override.conf 2>/dev/null || true)"

  sudo -u postgres psql -q -c "ALTER USER nextdp_mail WITH PASSWORD '${DB_PW}';" >/dev/null 2>&1 || (cd /tmp && sudo -u postgres psql -q -c "ALTER USER nextdp_mail WITH PASSWORD '${DB_PW}';")

  umask 077
  cat >"$ENV_FILE" <<EOF
APP_NAME="NextDP Mail"
APP_ENV=production
APP_DEBUG=false
APP_PORT=8080
APP_URL=https://mail.nextdp.com
APP_KEY=${APP_KEY_VAL}

RAPIDGO_MODE=all

DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=nextdp_mail
DB_USER=nextdp_mail
DB_PASSWORD=${DB_PW}
DB_SSL_MODE=disable

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PW}

SESSION_DRIVER=redis
SESSION_LIFETIME=120
SESSION_SECRET=${SESSION_SEC}
CACHE_DRIVER=redis
CACHE_PREFIX=raimail_
QUEUE_DRIVER=redis
QUEUE_DEFAULT=default
QUEUE_MAX_ATTEMPTS=3
QUEUE_RETRY_DELAY=30
QUEUE_TIMEOUT=60
QUEUE_POLL_INTERVAL=3

JWT_SECRET=${JWT_SEC}
JWT_EXPIRY=3600
MIGRATION_ENCRYPTION_KEY=${MIG_KEY}

SUPER_ADMIN_EMAIL=admin@nextdp.com
SUPER_ADMIN_PASSWORD=${ADMIN_PW}

MAIL_FROM_ADDRESS=noreply@nextdp.com
SMTP_DOMAIN=mx.nextdp.com
SMTP_LISTEN=0.0.0.0:25
SMTP_TLS_LISTEN=0.0.0.0:465
SMTP_SUBMISSION_LISTEN=0.0.0.0:587
SMTP_MAX_MESSAGE_BYTES=26214400
SMTP_TLS_CERT=${TLS_DIR}/${MAIL_HOST}.crt
SMTP_TLS_KEY=${TLS_DIR}/${MAIL_HOST}.key
IMAP_LISTEN=0.0.0.0:143
IMAP_TLS_LISTEN=0.0.0.0:993
POP3_LISTEN=0.0.0.0:110
POP3_TLS_LISTEN=0.0.0.0:995

STORAGE_DRIVER=local
STORAGE_PATH=${REMOTE_DIR}/storage
STORAGE_LOCAL_PATH=${REMOTE_DIR}/storage/uploads

LOG_LEVEL=info
LOG_FORMAT=json
LOG_OUTPUT=stdout
EOF
  chown ubuntu:ubuntu "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  unset DB_PW APP_KEY_VAL SESSION_SEC JWT_SEC MIG_KEY ADMIN_PW REDIS_PW
  echo "  Generated fresh .env at ${ENV_FILE} (secrets not echoed)."
else
  echo "  Existing ${ENV_FILE} preserved."
fi

echo "=== [4/6] Install systemd units + cert-sync hook ==="
sudo cp "$STAGE/nextdp.service" /etc/systemd/system/nextdp.service
sudo cp "$STAGE/nextdp-worker.service" /etc/systemd/system/nextdp-worker.service
sudo cp "$STAGE/nextdp-scheduler.service" /etc/systemd/system/nextdp-scheduler.service

sudo tee /usr/local/bin/nextdp-certsync >/dev/null <<'EOF'
#!/usr/bin/env bash
set -e
CERT_ROOT="/var/lib/caddy/.local/share/caddy/certificates"
TLS_DIR="/opt/nextdp/config/tls"
MAIL_HOST="mail.nextdp.com"
CRT_SRC="$(find "$CERT_ROOT" -type f -name "${MAIL_HOST}.crt" 2>/dev/null | head -1)"
KEY_SRC="$(find "$CERT_ROOT" -type f -name "${MAIL_HOST}.key" 2>/dev/null | head -1)"
if [ -n "$CRT_SRC" ] && [ -n "$KEY_SRC" ]; then
  install -o ubuntu -g ubuntu -m 0644 "$CRT_SRC" "${TLS_DIR}/${MAIL_HOST}.crt"
  install -o ubuntu -g ubuntu -m 0640 "$KEY_SRC" "${TLS_DIR}/${MAIL_HOST}.key"
fi
EOF
sudo chmod 0755 /usr/local/bin/nextdp-certsync

sudo mkdir -p "${CADDY_CERTS}"
sudo chown -R caddy:caddy /var/lib/caddy/.local 2>/dev/null || true

sudo tee /etc/systemd/system/nextdp-certwatch.path >/dev/null <<EOF
[Unit]
Description=Watch Caddy cert store; sync & reload NextDP mail listeners on renewal
[Path]
PathModified=/var/lib/caddy/.local/share/caddy/certificates
PathModified=${CADDY_CERTS}/${MAIL_HOST}
Unit=nextdp-certreload.service
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/nextdp-certreload.service >/dev/null <<'EOF'
[Unit]
Description=Sync renewed mail TLS certs and restart NextDP if active
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 15
ExecStartPre=/usr/local/bin/nextdp-certsync
ExecStart=/bin/systemctl try-restart nextdp.service
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nextdp-certwatch.path

echo "=== [5/6] Install Caddyfile & start Caddy (TLS issuance) ==="
sudo cp "$STAGE/Caddyfile" /etc/caddy/Caddyfile
sudo chown root:root /etc/caddy/Caddyfile
sudo chmod 644 /etc/caddy/Caddyfile
sudo mkdir -p /var/log/caddy
for lf in $(grep -oE '/var/log/caddy/[A-Za-z0-9._-]+' /etc/caddy/Caddyfile | sort -u); do
  sudo touch "$lf"
done
sudo chown -R caddy:caddy /var/log/caddy
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
sudo systemctl reload caddy

echo "  Waiting up to 45s for Caddy ACME cert (${MAIL_HOST})..."
for _ in $(seq 1 15); do
  if sudo find /var/lib/caddy/.local/share/caddy/certificates -type f -name "${MAIL_HOST}.crt" 2>/dev/null | grep -q .; then
    sudo /usr/local/bin/nextdp-certsync
    break
  fi
  sleep 3
done
ls -la "${TLS_DIR}/${MAIL_HOST}".* 2>/dev/null || echo "  (cert not yet present; Caddy may still be issuing)"

echo "=== [6/6] Services ==="
if [ "$START_SERVICES" = "1" ]; then
  (cd "${REMOTE_DIR}/config" && "${REMOTE_DIR}/bin/nextdp" migrate)
  sudo systemctl enable nextdp nextdp-worker nextdp-scheduler
  sudo systemctl restart nextdp nextdp-worker nextdp-scheduler
  sleep 3
  systemctl is-active caddy nextdp nextdp-worker nextdp-scheduler
  curl -sS --max-time 5 http://127.0.0.1:8080/api/health/ready || true
  echo ""
else
  echo "  START_SERVICES=0: leaving nextdp/worker/scheduler stopped until DB restore."
fi

rm -rf "$STAGE"
echo "=== Remote install complete ==="
