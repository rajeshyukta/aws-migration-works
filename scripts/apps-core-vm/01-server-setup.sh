#!/usr/bin/env bash
# Apps-Core-VM (43.204.42.99, EC2 t3.large) — Consolidated Base Setup (Idempotent)
# Installs: 2 GiB swap, PostgreSQL 16 (3 isolated DBs), Redis 7, Caddy 2, UFW, fail2ban,
# app users/directories for Next iDP (:8080), NextDP Core (:8090), and LocalCen (:8092).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

SECRETS_FILE=/root/.apps-core-secrets.env

echo "=== [1/8] Swap (2 GiB) ==="
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-apps-core-swap.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-apps-core-swap.conf >/dev/null || true

echo "=== [2/8] Base packages ==="
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release debian-keyring debian-archive-keyring \
  apt-transport-https jq netcat-openbsd openssl dnsutils unzip ufw fail2ban \
  software-properties-common

echo "=== [3/8] Secrets file on-box (/root/.apps-core-secrets.env, 0600) ==="
if ! sudo test -f "$SECRETS_FILE"; then
  sudo tee "$SECRETS_FILE" >/dev/null <<EOF
# Generated on-box by 01-server-setup.sh — never print or copy off-box unencrypted
PG_PASS_NEXTIDP=$(openssl rand -hex 24)
PG_PASS_NEXTDP_CORE=$(openssl rand -hex 24)
PG_PASS_LOCALCEN=$(openssl rand -hex 24)
REDIS_PASSWORD=$(openssl rand -hex 24)
EOF
  sudo chmod 600 "$SECRETS_FILE"
fi
# Load secrets in subshell only when needed; never echo values
set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_FILE")
set +a

echo "=== [4/8] PostgreSQL 16 + tuning + 3 isolated databases ==="
sudo apt-get install -y postgresql postgresql-contrib
sudo tee /etc/postgresql/16/main/conf.d/99-apps-core.conf >/dev/null <<'EOF'
# Tuned for 8 GiB shared VM (Next iDP + NextDP Core + LocalCen + Redis + Caddy)
listen_addresses = 'localhost'
max_connections = 100
shared_buffers = 512MB
effective_cache_size = 2GB
work_mem = 8MB
maintenance_work_mem = 128MB
password_encryption = scram-sha-256
EOF
sudo systemctl enable --now postgresql
sudo systemctl restart postgresql

ensure_pg_db() {
  local role="$1" pass="$2" db="$3"
  (cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${role}'" | grep -q 1 \
    || sudo -u postgres psql -qc "CREATE ROLE ${role} LOGIN PASSWORD '${pass}';")
  (cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1 \
    || sudo -u postgres createdb -O "${role}" -E UTF8 "${db}")
  (cd /tmp && sudo -u postgres psql -d "${db}" -qc "ALTER DATABASE ${db} OWNER TO ${role}; GRANT ALL ON SCHEMA public TO ${role};")
}

ensure_pg_db "nextidp"     "$PG_PASS_NEXTIDP"     "nextidp"
ensure_pg_db "nextdp_core" "$PG_PASS_NEXTDP_CORE" "nextdp_core"
ensure_pg_db "localcen_u"  "$PG_PASS_LOCALCEN"    "localcen_db"

echo "=== [5/8] Redis 7 (loopback + requirepass, 512 MB allkeys-lru) ==="
sudo apt-get install -y redis-server
sudo tee /etc/redis/apps-core-override.conf >/dev/null <<EOF
bind 127.0.0.1 ::1
requirepass ${REDIS_PASSWORD}
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF
sudo chown redis:redis /etc/redis/apps-core-override.conf
sudo chmod 640 /etc/redis/apps-core-override.conf
if ! sudo grep -qE '^\s*include\s+/etc/redis/apps-core-override\.conf' /etc/redis/redis.conf; then
  echo 'include /etc/redis/apps-core-override.conf' | sudo tee -a /etc/redis/redis.conf >/dev/null
fi
sudo systemctl enable --now redis-server
sudo systemctl restart redis-server

echo "=== [6/8] Caddy 2 ==="
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y caddy
fi
sudo mkdir -p /etc/caddy/sites-enabled /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy
sudo systemctl enable caddy

echo "=== [7/8] App users & directories ==="
id -u nextidp >/dev/null 2>&1 || sudo useradd --system --home /opt/nextidp --shell /usr/sbin/nologin nextidp
id -u webapps >/dev/null 2>&1 || sudo useradd --system --home /srv/apps --shell /usr/sbin/nologin webapps
sudo usermod -aG nextidp,webapps caddy || true

sudo mkdir -p /opt/nextidp/{releases,backups,storage} /etc/nextidp
sudo chown -R nextidp:nextidp /opt/nextidp
sudo chmod 750 /opt/nextidp/backups /etc/nextidp

sudo mkdir -p /srv/apps/nextdp/{releases,shared/storage/{cache,logs,sessions,uploads},shared/geoip,logs}
sudo mkdir -p /srv/apps/localcen/{releases,shared/storage/caddy-sync-spool,shared/lang,shared/certs,shared/geo-packs,logs}
sudo chown -R webapps:webapps /srv/apps
sudo chmod 750 /srv/apps/nextdp/shared /srv/apps/localcen/shared
sudo chown -R webapps:caddy /srv/apps/nextdp/logs /srv/apps/localcen/logs
sudo chmod 775 /srv/apps/nextdp/logs /srv/apps/localcen/logs

echo "=== [8/8] Firewall (UFW 22/80/443), fail2ban, journald caps & disk alert ==="
sudo ufw --force default deny incoming >/dev/null
sudo ufw --force default allow outgoing >/dev/null
sudo ufw allow 22/tcp >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null
sudo systemctl enable --now fail2ban >/dev/null 2>&1 || true

sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-apps-core-limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
RuntimeMaxUse=150M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald

sudo tee /usr/local/bin/apps-core-diskcheck.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$USED" -ge 85 ]; then
  logger -t apps-core-diskcheck -p user.crit "DISK ALERT: root filesystem ${USED}% full"
fi
EOF
sudo chmod 0755 /usr/local/bin/apps-core-diskcheck.sh

sudo tee /etc/systemd/system/apps-core-diskcheck.service >/dev/null <<'EOF'
[Unit]
Description=Apps-Core disk space check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/apps-core-diskcheck.sh
EOF

sudo tee /etc/systemd/system/apps-core-diskcheck.timer >/dev/null <<'EOF'
[Unit]
Description=Run Apps-Core disk space check hourly
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now apps-core-diskcheck.timer

echo "=== Apps-Core-VM base setup complete ==="
psql --version
redis-server --version | head -1
caddy version
sudo -u postgres psql -Atc "SELECT datname FROM pg_database WHERE datname IN ('nextidp','nextdp_core','localcen_db') ORDER BY 1"
free -h
df -h /
sudo ufw status | head -10
