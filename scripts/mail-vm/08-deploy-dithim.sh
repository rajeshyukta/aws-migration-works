#!/usr/bin/env bash
# Remote installation/update for dithim.com static site, Python .txt form backend,
# Caddy clean-URL + www->@ redirect config, and updated traffic archive classifier.
set -euo pipefail

STAGE_DIR="${STAGE_DIR:?STAGE_DIR env var required}"

for req in "$STAGE_DIR/dithim-dist.tar.gz" "$STAGE_DIR/dithim-form-backend.py" "$STAGE_DIR/Caddyfile" "$STAGE_DIR/nextdp-traffic-archive.py"; do
  if [ ! -f "$req" ]; then
    echo "ERROR: Missing staged artifact: $req" >&2
    exit 1
  fi
done

echo "=== Installing Dithim static site -> /opt/dithim/public ==="
sudo mkdir -p /opt/dithim /opt/dithim/backend
sudo rm -rf /opt/dithim/public.new /opt/dithim/public.old
sudo mkdir -p /opt/dithim/public.new
sudo tar -xzf "$STAGE_DIR/dithim-dist.tar.gz" -C /opt/dithim/public.new
sudo rm -rf /opt/dithim/public.new/api
sudo find /opt/dithim/public.new -type f -name '*.php' -delete
sudo chown -R root:root /opt/dithim/public.new
sudo chmod -R u=rwX,go=rX /opt/dithim/public.new
if [ -d /opt/dithim/public ]; then
  sudo mv /opt/dithim/public /opt/dithim/public.old
fi
sudo mv /opt/dithim/public.new /opt/dithim/public
sudo rm -rf /opt/dithim/public.old

echo "=== Installing Python form backend -> /opt/dithim/backend ==="
sed 's/\r$//' "$STAGE_DIR/dithim-form-backend.py" | sudo tee /opt/dithim/backend/dithim-form-backend.py >/dev/null
sudo chown root:root /opt/dithim/backend/dithim-form-backend.py
sudo chmod 0755 /opt/dithim/backend/dithim-form-backend.py

sudo mkdir -p /var/lib/dithim/submissions/daily /var/lib/dithim/state
sudo chown -R www-data:ubuntu /var/lib/dithim
sudo chmod 0750 /var/lib/dithim /var/lib/dithim/state
sudo chmod 2750 /var/lib/dithim/submissions /var/lib/dithim/submissions/daily

echo "=== Installing dithim-web.service (127.0.0.1:8090) ==="
sudo tee /etc/systemd/system/dithim-web.service >/dev/null <<'UNIT'
[Unit]
Description=Dithim Website Form Backend (Python stdlib -> .txt)
After=network.target

[Service]
Type=simple
User=www-data
Group=ubuntu
UMask=0027
WorkingDirectory=/opt/dithim/backend
Environment=DITHIM_BIND_HOST=127.0.0.1
Environment=DITHIM_BIND_PORT=8090
Environment=DITHIM_SUBMISSIONS_DIR=/var/lib/dithim/submissions
Environment=DITHIM_STATE_DIR=/var/lib/dithim/state
ExecStart=/usr/bin/python3 /opt/dithim/backend/dithim-form-backend.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/dithim

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable dithim-web
sudo systemctl restart dithim-web

for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8090/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl -fsS --max-time 3 http://127.0.0.1:8090/healthz
echo ""

echo "=== Updating traffic archive classifier (/usr/local/bin/nextdp-traffic-archive) ==="
sed 's/\r$//' "$STAGE_DIR/nextdp-traffic-archive.py" | sudo tee /usr/local/bin/nextdp-traffic-archive >/dev/null
sudo chmod 0755 /usr/local/bin/nextdp-traffic-archive

echo "=== Updating and reloading Caddyfile ==="
if [ -f /etc/caddy/Caddyfile ]; then
  sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-pre-dithim
fi
sed 's/\r$//' "$STAGE_DIR/Caddyfile" | sudo tee /etc/caddy/Caddyfile.new >/dev/null
sudo chown root:root /etc/caddy/Caddyfile.new
sudo chmod 0644 /etc/caddy/Caddyfile.new
if ! sudo caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile; then
  echo "ERROR: Caddyfile validation failed; leaving live Caddyfile untouched." >&2
  sudo rm -f /etc/caddy/Caddyfile.new
  exit 1
fi
# caddy validate runs as root and creates new log files owned by root:root; fix ownership before caddy reloads.
sudo mkdir -p /var/log/caddy/live
sudo touch /var/log/caddy/live/dithim-access.log
sudo chown -R caddy:caddy /var/log/caddy/live
sudo chmod 0755 /var/log/caddy/live
sudo chmod 0644 /var/log/caddy/live/*.log

sudo mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
if systemctl is-active --quiet caddy; then
  sudo systemctl reload caddy || sudo systemctl restart caddy
else
  sudo systemctl start caddy
fi

echo "=== Local smoke check ==="
systemctl is-active dithim-web caddy
for target in "https://dithim.com/" "https://dithim.com/contact" "https://dithim.com/products/dithim-flow" "https://dithim.com/register" "https://dithim.com/nonexistent" "https://www.dithim.com/contact"; do
  host="${target#https://}"
  host="${host%%/*}"
  code="000 -> ERR"
  for _ in $(seq 1 6); do
    code="$(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' --max-time 10 --resolve "${host}:443:127.0.0.1" "$target" 2>/dev/null || echo "000 -> ERR")"
    if [ "${code%% *}" != "000" ]; then
      break
    fi
    sleep 2
  done
  printf "  %-38s %s\n" "$target" "$code"
done
