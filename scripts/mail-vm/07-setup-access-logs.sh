#!/usr/bin/env bash
# Deploy trimmed daily Caddy access logging + nightly IST splitter/analyzer on Mail VM.
set -euo pipefail

STAGE="${STAGE_DIR:-/tmp/nextdp-logs-stage}"
if [ ! -d "$STAGE" ]; then
  echo "FATAL: stage dir missing: $STAGE" >&2
  exit 1
fi

sed -i 's/\r$//' "$STAGE/Caddyfile" "$STAGE/nextdp-traffic-archive.py"

echo "=== [1/4] Prepare /var/log/caddy directories ==="
sudo mkdir -p /var/log/caddy/live /var/log/caddy/daily /var/log/caddy/legacy
# Preserve any existing root-level nextdp-*.log files into legacy/ so today's traffic is archived
for oldf in /var/log/caddy/nextdp-*.log; do
  if [ -e "$oldf" ]; then
    sudo mv -n "$oldf" /var/log/caddy/legacy/ || true
  fi
done

echo "=== [2/4] Install updated Caddyfile & restart Caddy onto live/*.log ==="
sudo cp "$STAGE/Caddyfile" /etc/caddy/Caddyfile
sudo chown root:root /etc/caddy/Caddyfile
sudo chmod 644 /etc/caddy/Caddyfile
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
for lf in $(grep -oE '/var/log/caddy/[A-Za-z0-9._/-]+\.log' /etc/caddy/Caddyfile | sort -u); do
  sudo mkdir -p "$(dirname "$lf")"
  sudo touch "$lf"
done
sudo chown -R caddy:caddy /var/log/caddy/live
sudo chown caddy:caddy /var/log/caddy
sudo chown -R ubuntu:ubuntu /var/log/caddy/daily
sudo caddy validate --config /etc/caddy/Caddyfile
# Restart required when switching log file paths so Caddy opens /var/log/caddy/live/*.log cleanly
sudo systemctl restart caddy
sleep 2
systemctl is-active caddy

echo "=== [3/4] Install nextdp-traffic-archive.py + nextdp-traffic CLI + systemd timer (00:05 IST) ==="
sudo install -m 0755 -o root -g root "$STAGE/nextdp-traffic-archive.py" /usr/local/bin/nextdp-traffic-archive.py

sudo tee /usr/local/bin/nextdp-traffic >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ $# -eq 0 ]; then
  exec sudo /usr/bin/python3 /usr/local/bin/nextdp-traffic-archive.py --today --report --no-write
else
  exec sudo /usr/bin/python3 /usr/local/bin/nextdp-traffic-archive.py --report --no-write "$@"
fi
EOF
sudo chmod 0755 /usr/local/bin/nextdp-traffic

sudo tee /etc/systemd/system/nextdp-traffic-archive.service >/dev/null <<'EOF'
[Unit]
Description=Daily Caddy traffic log splitter and domain summary archiver

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/nextdp-traffic-archive.py --keep-days 30
EOF

sudo tee /etc/systemd/system/nextdp-traffic-archive.timer >/dev/null <<'EOF'
[Unit]
Description=Run daily Caddy access log archive at 00:05 IST

[Timer]
OnCalendar=*-*-* 00:05:00 Asia/Kolkata
Persistent=true
RandomizedDelaySec=15

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nextdp-traffic-archive.timer

echo "=== [4/4] Run initial daily archive for today (IST) and verify outputs ==="
sudo /usr/bin/python3 /usr/local/bin/nextdp-traffic-archive.py --today --report --keep-days 30
TODAY_IST="$(TZ=Asia/Kolkata date +%F)"
echo ""
echo "=== Generated files in /var/log/caddy/daily/${TODAY_IST} ==="
ls -lh "/var/log/caddy/daily/${TODAY_IST}/"
echo "by-domain count: $(find "/var/log/caddy/daily/${TODAY_IST}/by-domain" -type f | wc -l)"
echo "=== Live Caddy logs (/var/log/caddy/live) ==="
ls -lh /var/log/caddy/live/
echo "=== Active timers ==="
systemctl list-timers nextdp-traffic-archive.timer --no-pager
