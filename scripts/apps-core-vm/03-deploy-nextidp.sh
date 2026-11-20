#!/usr/bin/env bash
# Deploy Next iDP (:8080) onto Apps-Core-VM (43.204.42.99)
set -euo pipefail

TARBALL="${TARBALL:?TARBALL must be set}"
VERSION="${VERSION:-0.86.0}"
APP_DIR=/opt/nextidp
ENV_FILE=/etc/nextidp/env
SECRETS_FILE=/root/.apps-core-secrets.env
TS=$(date -u +%Y%m%d-%H%M%S)
REL="$APP_DIR/releases/${VERSION}-${TS}"
PREV=""
[ -L "$APP_DIR/current" ] && PREV=$(readlink -f "$APP_DIR/current" || true)

[ -f "$TARBALL" ] || { echo "FATAL: missing $TARBALL"; exit 1; }
sudo test -f "$SECRETS_FILE" || { echo "FATAL: missing $SECRETS_FILE (run 01-server-setup.sh first)"; exit 1; }

set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_FILE")
set +a

echo "==> Unpack Next iDP $VERSION -> $REL"
sudo mkdir -p "$REL"
sudo tar -xzf "$TARBALL" -C "$REL"
sudo chown -R nextidp:nextidp "$REL"
sudo chmod 755 "$REL/nextidp"
sudo chmod -R o+rX "$REL"

echo "==> Ensure /etc/nextidp/env"
if ! sudo test -f "$ENV_FILE"; then
  APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | cut -c1-48)
  sudo tee "$ENV_FILE" >/dev/null <<EOF
APP_NAME="Next iDP"
APP_ENV=production
APP_PORT=8080
APP_KEY=${APP_KEY}
JWT_SECRET=${JWT_SECRET}
LOG_LEVEL=info

N1_MASTER_HOST=nextidp.com
N1_SCHEME=https
N1_PUBLIC_PORT=
N1_EDGE_IPS=43.204.42.99
N1_SEED_HOST_SUFFIX=
N1_SEED_FIXTURES=false
N1_SEED_DIR=/opt/nextidp/current/data

DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=nextidp
DB_USER=nextidp
DB_PASSWORD=${PG_PASS_NEXTIDP}
DB_SSL_MODE=disable

SESSION_DRIVER=redis
REDIS_ADDR=127.0.0.1:6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=0

QUEUE_DRIVER=redis
QUEUE_WORKERS=2
MAIL_DRIVER=outbox
MAIL_FROM_ADDRESS=noreply@nextidp.com
MAIL_FROM_NAME="Next iDP"
MAIL_RETENTION_DAYS=90
N1_DEV_OUTBOX=true
AVATAR_STORE=off
PASSWORD_ALGO=argon2id
HEALTH_EXPOSE_VERSION=true
EOF
  sudo chown root:nextidp "$ENV_FILE"
  sudo chmod 640 "$ENV_FILE"
fi

echo "==> Install systemd units & timers"
for f in "$REL"/systemd/*.service "$REL"/systemd/*.timer; do
  [ -f "$f" ] || continue
  bn=$(basename "$f")
  if [ "$bn" = "nextidp.service" ]; then
    sed 's/^After=network-online.target.*/After=network-online.target postgresql.service redis-server.service/' "$f" | sudo tee "/etc/systemd/system/$bn" >/dev/null
  else
    sudo install -m 644 "$f" "/etc/systemd/system/$bn"
  fi
done
sudo systemctl daemon-reload
sudo systemctl enable nextidp nextidp-worker >/dev/null 2>&1 || true
sudo systemctl enable --now nextidp-mail-prune.timer nextidp-contact-prune.timer nextidp-audit-prune.timer >/dev/null 2>&1 || true

echo "==> Stop, switch symlink, migrate & seed"
sudo systemctl stop nextidp-worker nextidp 2>/dev/null || true
sudo ln -sfn "$REL" "$APP_DIR/current"

set -a
# shellcheck disable=SC1090
source <(sudo cat "$ENV_FILE")
set +a

(cd "$REL" && sudo -E -u nextidp ./nextidp migrate)
(cd "$REL" && sudo -E -u nextidp ./nextidp db:seed)

echo "==> Start & health-check (:8080)"
sudo systemctl start nextidp nextidp-worker
for i in $(seq 1 20); do
  if out=$(curl -fsS -m 3 -H 'Host: 127.0.0.1' http://127.0.0.1:8080/health/version 2>/dev/null); then
    echo "healthy: $out"
    sudo systemctl is-active nextidp nextidp-worker
    ls -1dt "$APP_DIR"/releases/* | tail -n +6 | xargs -r sudo rm -rf
    exit 0
  fi
  sleep 1
done

echo "!! Health check failed"
sudo journalctl -u nextidp -n 40 --no-pager || true
if [ -n "$PREV" ] && [ -d "$PREV" ]; then
  sudo ln -sfn "$PREV" "$APP_DIR/current"
  sudo systemctl restart nextidp nextidp-worker
fi
exit 1
