#!/usr/bin/env bash
# Deploy dns-service + scheduler + Caddy onto DNS-VM (52.66.165.1)
set -euo pipefail

TARBALL="${TARBALL:?TARBALL must be set}"
CADDY_SRC="${CADDY_SRC:?CADDY_SRC must be set}"
APP=dns-service
APP_DIR=/srv/apps/$APP
ENV_FILE=$APP_DIR/shared/.env
SECRETS_FILE=/root/.dns-vm-secrets.env
TS=$(date -u +%Y%m%dT%H%M%S)
REL=$APP_DIR/releases/$TS
PREV=$(readlink -f "$APP_DIR/current" 2>/dev/null || true)

[ -f "$TARBALL" ] || { echo "FATAL: missing $TARBALL"; exit 1; }
[ -f "$CADDY_SRC" ] || { echo "FATAL: missing $CADDY_SRC"; exit 1; }
sudo test -f "$SECRETS_FILE" || { echo "FATAL: missing $SECRETS_FILE"; exit 1; }

set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_FILE")
set +a

echo "==> Unpack dns-service -> $REL"
sudo install -d -o webapps -g webapps "$REL"
sudo tar -xzf "$TARBALL" -C "$REL"
sudo chmod +x "$REL/dns"
sudo ln -sfn "$ENV_FILE" "$REL/.env"
sudo chown -R webapps:webapps "$REL"
sudo chmod -R o+rX "$REL"

echo "==> Ensure $ENV_FILE"
if ! sudo test -f "$ENV_FILE"; then
  APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  JWT_SECRET=$(openssl rand -hex 32)
  sudo tee "$ENV_FILE" >/dev/null <<EOF
APP_NAME=dns-service
APP_ENV=production
APP_DEBUG=false
APP_PORT=8080
APP_URL=https://dns.cconsole.com
APP_KEY=${APP_KEY}

RAPIDGO_MODE=all
GIN_MODE=release
TRUSTED_PROXIES=127.0.0.1,::1

DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=dns_db
DB_USER=dns_u
DB_PASSWORD=${PG_PASS_DNS_SVC}
DB_SSL_MODE=disable

JWT_SECRET=${JWT_SECRET}

IDP_ISSUER=https://accounts.cconsole.com
IDP_LOGIN=false
IDP_PUBLIC_ORIGIN=https://dns.cconsole.com
IDP_OWNER_CONTACT=ops@presencive.com

SESSION_DRIVER=db
SESSION_COOKIE=__Host-sid
SESSION_SECURE=true
SESSION_LIFETIME=720m
SESSION_ABSOLUTE_LIFETIME=1440m

PDNS_API_BASE=http://127.0.0.1:8081/api/v1/servers/localhost
PDNS_API_KEY=${PDNS_API_KEY}
PDNS_NAMESERVERS=ns1.presencive.com,ns2.presencive.com
PDNS_ACCOUNT=presencive
PDNS_SOA_CONTACT=dns-admin@presencive.com

CONNECT_SECRET=${CONNECT_SECRET}
CORS_ALLOWED_ORIGINS=https://dns.cconsole.com,https://admin.dns.cconsole.com

LOG_LEVEL=info
LOG_FORMAT=json
LOG_OUTPUT=stdout
SERVER_READ_TIMEOUT=10s
SERVER_WRITE_TIMEOUT=10s
SERVER_IDLE_TIMEOUT=120s
EOF
  sudo chown webapps:webapps "$ENV_FILE"
  sudo chmod 600 "$ENV_FILE"
fi

echo "==> Install systemd units (dns-service, dns-service-scheduler)"
sudo tee /etc/systemd/system/dns-service.service >/dev/null <<'EOF'
[Unit]
Description=Presencive DNS Service
After=network-online.target postgresql.service pdns.service
Wants=postgresql.service pdns.service

[Service]
Type=simple
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/dns-service/current
EnvironmentFile=/srv/apps/dns-service/shared/.env
ExecStart=/srv/apps/dns-service/current/dns serve
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/dns-service-scheduler.service >/dev/null <<'EOF'
[Unit]
Description=Presencive DNS Service Scheduler
After=network-online.target postgresql.service pdns.service dns-service.service
Wants=postgresql.service pdns.service

[Service]
Type=simple
User=webapps
Group=webapps
WorkingDirectory=/srv/apps/dns-service/current
EnvironmentFile=/srv/apps/dns-service/shared/.env
ExecStart=/srv/apps/dns-service/current/dns schedule:run
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable dns-service dns-service-scheduler >/dev/null 2>&1 || true

echo "==> Run migrations & idempotent tenant seed"
if ! (cd "$REL" && sudo -u webapps ./dns migrate); then
  echo "FATAL: dns migrate failed"
  exit 1
fi
# Save any first-run dk_ dev API key only on-box (0600 root) so secrets never print to chat logs
if [ ! -f /root/.dns-vm-seed.txt ]; then
  (cd "$REL" && sudo -u webapps ./dns db:seed) | sudo tee /root/.dns-vm-seed.txt >/dev/null
  sudo chmod 600 /root/.dns-vm-seed.txt
fi

echo "==> Flip current & restart dns-service"
sudo ln -sfn "$REL" "$APP_DIR/current"
sudo systemctl restart dns-service dns-service-scheduler

echo "==> Configure Caddy"
for f in /var/log/caddy/dns.access.log /var/log/caddy/admin-dns.access.log; do
  sudo touch "$f"
  sudo chown caddy:caddy "$f"
  sudo chmod 0640 "$f"
done
sudo install -m 0644 -o root -g root "$CADDY_SRC" /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo chown caddy:caddy /var/log/caddy/*.log 2>/dev/null || true
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy

for i in 1 2 3 4 5; do
  if out=$(curl -fsS -m 3 http://127.0.0.1:8080/api/v1/ping 2>/dev/null); then
    echo "healthy: $out"
    sudo systemctl is-active pdns dns-service dns-service-scheduler caddy
    ls -1dt "$APP_DIR"/releases/* | tail -n +6 | xargs -r sudo rm -rf
    exit 0
  fi
  sleep 2
done

echo "!! Health check failed"
sudo journalctl -u dns-service -n 40 --no-pager || true
if [ -n "$PREV" ] && [ -d "$PREV" ]; then
  sudo ln -sfn "$PREV" "$APP_DIR/current"
  sudo systemctl restart dns-service dns-service-scheduler
fi
exit 1
