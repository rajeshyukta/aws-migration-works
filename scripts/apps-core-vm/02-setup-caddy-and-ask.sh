#!/usr/bin/env bash
# Install apps-core-tls-ask.service (:8099) and consolidated Caddyfile on Apps-Core-VM (43.204.42.99)
set -euo pipefail

STAGE_DIR="${STAGE_DIR:?STAGE_DIR must be set}"

echo "=== [1/3] apps-core-tls-ask (:8099) ==="
sudo install -m 0755 -o root -g root "$STAGE_DIR/apps-core-tls-ask.py" /usr/local/bin/apps-core-tls-ask.py

sudo tee /etc/systemd/system/apps-core-tls-ask.service >/dev/null <<'EOF'
[Unit]
Description=Apps-Core On-Demand TLS Ask Multiplexer (:8099)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/python3 /usr/local/bin/apps-core-tls-ask.py
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now apps-core-tls-ask.service
for i in 1 2 3 4 5; do
  if curl -fsS --max-time 3 http://127.0.0.1:8099/healthz; then break; fi
  sleep 1
done
curl -fsS --max-time 3 http://127.0.0.1:8099/healthz

echo "=== [2/3] Pre-create Caddy log files ==="
sudo mkdir -p /var/log/caddy /etc/caddy/sites-enabled
sudo chown -R caddy:caddy /var/log/caddy
for f in nextidp-master.access.log nextdp-core.access.log admin-localcen.access.log localcen.access.log apps-core-catchall.access.log public-localcen.access.log; do
  [ -f "/var/log/caddy/$f" ] || sudo install -o caddy -g caddy -m 0640 /dev/null "/var/log/caddy/$f"
done

echo "=== [3/3] Install & validate Caddyfile ==="
if [ -f /etc/caddy/Caddyfile ] && [ ! -f /etc/caddy/Caddyfile.bak-orig ]; then
  sudo cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-orig
fi
sudo install -m 0644 -o root -g root "$STAGE_DIR/Caddyfile.apps-core-vm" /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy || sudo systemctl restart caddy
systemctl is-active caddy apps-core-tls-ask
