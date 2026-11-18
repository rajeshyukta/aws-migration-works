#!/usr/bin/env bash
# NextDP Mail — Standalone Ubuntu 24.04 Lightsail Server Setup (Idempotent)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

RESTIC_VERSION="0.19.1"
RESTIC_SHA256="f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c"

echo "=== [1/8] Swap (2 GiB) ==="
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-nextdp-swap.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-nextdp-swap.conf >/dev/null || true

echo "=== [2/8] Base packages + Python boto3 ==="
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release debian-keyring debian-archive-keyring \
  apt-transport-https bzip2 jq netcat-openbsd openssl python3 python3-boto3

echo "=== [3/8] PostgreSQL 16 ==="
sudo apt-get install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='nextdp_mail'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE USER nextdp_mail WITH PASSWORD 'initial-placeholder-will-be-rotated';")
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='nextdp_mail'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE nextdp_mail OWNER nextdp_mail;")
(cd /tmp && sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE nextdp_mail TO nextdp_mail;" >/dev/null)

echo "=== [4/8] Redis 7 (loopback + requirepass) ==="
sudo apt-get install -y redis-server
if [ ! -f /etc/redis/nextdp-override.conf ]; then
  REDIS_PW="$(openssl rand -hex 24)"
  sudo tee /etc/redis/nextdp-override.conf >/dev/null <<EOF
bind 127.0.0.1 ::1
requirepass ${REDIS_PW}
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF
  unset REDIS_PW
  sudo chown redis:redis /etc/redis/nextdp-override.conf
  sudo chmod 640 /etc/redis/nextdp-override.conf
fi
if ! sudo grep -qE '^\s*include\s+/etc/redis/nextdp-override\.conf' /etc/redis/redis.conf; then
  echo 'include /etc/redis/nextdp-override.conf' | sudo tee -a /etc/redis/redis.conf >/dev/null
fi
sudo systemctl enable --now redis-server
sudo systemctl restart redis-server

echo "=== [5/8] Caddy 2 ==="
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y caddy
fi
sudo systemctl enable caddy
sudo mkdir -p /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy

echo "=== [6/8] Upstream restic ${RESTIC_VERSION} (SHA-256 verified) ==="
need_restic=1
if command -v restic >/dev/null 2>&1 && restic version | grep -q "restic ${RESTIC_VERSION}"; then
  need_restic=0
fi
if [ "$need_restic" -eq 1 ]; then
  TMP_BZ2="$(mktemp /tmp/restic.XXXXXX.bz2)"
  curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" -o "$TMP_BZ2"
  echo "${RESTIC_SHA256}  ${TMP_BZ2}" | sha256sum -c -
  bzip2 -dc "$TMP_BZ2" | sudo tee /usr/local/bin/restic >/dev/null
  rm -f "$TMP_BZ2"
  sudo chmod 0755 /usr/local/bin/restic
fi
restic version

echo "=== [7/8] /opt/nextdp directory layout ==="
sudo mkdir -p /opt/nextdp/{bin,config,config/tls,storage/{emails,attachments,bimi,logs,cache,uploads},web/{super-admin,admin,webmail}}
sudo chown -R ubuntu:ubuntu /opt/nextdp
chmod 750 /opt/nextdp/config /opt/nextdp/config/tls

echo "=== [8/8] Logging caps & hourly disk alarm ==="
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-nextdp-limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald

sudo tee /etc/rsyslog.d/99-nextdp-drop-app.conf >/dev/null <<'EOF'
:programname, isequal, "nextdp" stop
:programname, isequal, "nextdp-worker" stop
:programname, isequal, "nextdp-scheduler" stop
EOF
sudo systemctl restart rsyslog 2>/dev/null || true

sudo tee /etc/logrotate.d/nextdp-syslog-cap >/dev/null <<'EOF'
/var/log/syslog
{
    su root syslog
    rotate 4
    daily
    maxsize 200M
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

sudo tee /usr/local/bin/nextdp-diskcheck.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$USED" -ge 85 ]; then
  logger -t nextdp-diskcheck -p user.crit "DISK ALERT: root filesystem ${USED}% full"
fi
EOF
sudo chmod 0755 /usr/local/bin/nextdp-diskcheck.sh

sudo tee /etc/systemd/system/nextdp-diskcheck.service >/dev/null <<'EOF'
[Unit]
Description=NextDP disk space check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nextdp-diskcheck.sh
EOF

sudo tee /etc/systemd/system/nextdp-diskcheck.timer >/dev/null <<'EOF'
[Unit]
Description=Run NextDP disk space check hourly
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nextdp-diskcheck.timer

echo "=== Server setup complete ==="
psql --version
redis-server --version | head -1
caddy version
free -h
df -h /
