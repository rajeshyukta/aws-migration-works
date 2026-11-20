#!/usr/bin/env bash
# Web-1 (3.6.143.66, Lightsail small_3_1) — Base Setup (Idempotent)
# Installs: 2 GiB swap + kernel hardening, PostgreSQL 16 (scram-sha-256, loopback),
# hardened PHP 8.4-FPM (no Apache), Caddy 2, UFW (22/80/443), fail2ban, journald caps,
# unattended security upgrades, app users, and hourly disk check.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

CADDYFILE_SRC="${CADDYFILE_SRC:?CADDYFILE_SRC must point to staged Caddyfile.web-1}"
SECRETS_FILE=/root/.web1-secrets.env

echo "=== [1/9] Swap (2 GiB) & sysctl hardening ==="
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
sudo tee /etc/sysctl.d/99-web1-hardening.conf >/dev/null <<'EOF'
vm.swappiness=10
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
fs.protected_hardlinks=1
fs.protected_symlinks=1
EOF
sudo sysctl --system >/dev/null || true

echo "=== [2/9] Base packages & ensure no Apache ==="
if dpkg -s apache2 >/dev/null 2>&1; then
  sudo systemctl disable --now apache2 || true
  sudo apt-get purge -y apache2 apache2-utils apache2-bin || true
fi
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release debian-keyring debian-archive-keyring \
  apt-transport-https jq netcat-openbsd openssl dnsutils unzip rsync ufw fail2ban \
  software-properties-common sqlite3 unattended-upgrades

echo "=== [3/9] On-box secrets (/root/.web1-secrets.env, 0600) ==="
if ! sudo test -f "$SECRETS_FILE"; then
  sudo tee "$SECRETS_FILE" >/dev/null <<EOF
# Generated on-box by 01-server-setup.sh — never print or copy off-box
PG_PASS_WEBAPPS=$(openssl rand -hex 24)
EOF
  sudo chmod 600 "$SECRETS_FILE"
fi
set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_FILE")
set +a

echo "=== [4/9] PostgreSQL 16 (loopback + scram-sha-256 + 2 GiB RAM tuning) ==="
sudo apt-get install -y --no-install-recommends postgresql postgresql-contrib
sudo tee /etc/postgresql/16/main/conf.d/99-web1.conf >/dev/null <<'EOF'
# Tuned for 2 GiB Web-1 alongside PHP 8.4-FPM + Caddy
listen_addresses = 'localhost'
max_connections = 60
shared_buffers = 256MB
effective_cache_size = 768MB
work_mem = 4MB
maintenance_work_mem = 64MB
password_encryption = scram-sha-256
ssl = on
EOF
# Ensure md5 is replaced by scram-sha-256 on loopback IPv4/IPv6
if sudo grep -qE '^host\s+all\s+all\s+(127\.0\.0\.1/32|::1/128)\s+md5' /etc/postgresql/16/main/pg_hba.conf; then
  sudo sed -i -E 's/^(host\s+all\s+all\s+(127\.0\.0\.1\/32|::1\/128)\s+)md5/\1scram-sha-256/' /etc/postgresql/16/main/pg_hba.conf
fi
sudo systemctl enable --now postgresql
sudo systemctl restart postgresql

(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='webapps'" | grep -q 1 \
  || sudo -u postgres psql -qc "CREATE ROLE webapps LOGIN PASSWORD '${PG_PASS_WEBAPPS}';")
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='web1_apps'" | grep -q 1 \
  || sudo -u postgres createdb -O webapps -E UTF8 web1_apps)
(cd /tmp && sudo -u postgres psql -d web1_apps -qc "ALTER DATABASE web1_apps OWNER TO webapps; GRANT ALL ON SCHEMA public TO webapps;")

echo "=== [5/9] Secure PHP 8.4 + FPM hardening ==="
if ! dpkg -s php8.4-fpm >/dev/null 2>&1; then
  sudo add-apt-repository -y ppa:ondrej/php
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    php8.4-fpm php8.4-cli php8.4-common \
    php8.4-pgsql php8.4-sqlite3 php8.4-mbstring php8.4-curl \
    php8.4-xml php8.4-intl php8.4-zip php8.4-gd php8.4-opcache
fi

sudo tee /etc/php/8.4/fpm/conf.d/99-web1-security.ini >/dev/null <<'EOF'
; Global PHP 8.4-FPM hardening for Web-1
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
cgi.fix_pathinfo = 0
allow_url_include = Off
file_uploads = Off
enable_dl = Off
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec,dl,show_source
session.cookie_httponly = 1
session.cookie_secure = 1
session.cookie_samesite = Lax
session.use_strict_mode = 1
session.use_only_cookies = 1
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
EOF

sudo tee /etc/php/8.4/cli/conf.d/99-web1-security.ini >/dev/null <<'EOF'
expose_php = Off
display_errors = Off
log_errors = On
EOF

sudo php-fpm8.4 -t
sudo systemctl enable --now php8.4-fpm
sudo systemctl restart php8.4-fpm

echo "=== [6/9] Caddy 2 ==="
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
sudo chmod 0750 /var/log/caddy
sudo install -o root -g root -m 0644 "$CADDYFILE_SRC" /etc/caddy/Caddyfile
sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo systemctl enable --now caddy
sudo systemctl restart caddy

echo "=== [7/9] Isolated app users & directory skeleton ==="
id -u webapps >/dev/null 2>&1 || sudo useradd --system --home /srv/phpapps --shell /usr/sbin/nologin webapps
id -u app-daiskills >/dev/null 2>&1 || sudo useradd --system --home /srv/phpapps/daiskills.com --shell /usr/sbin/nologin app-daiskills
sudo usermod -aG webapps,app-daiskills caddy || true

sudo mkdir -p /srv/phpapps /srv/static /srv/backups /var/log/php-fpm
sudo chown root:root /srv/phpapps /srv/static
sudo chmod 0755 /srv/phpapps /srv/static
sudo chmod 0700 /srv/backups
sudo chown root:webapps /var/log/php-fpm
sudo chmod 0775 /var/log/php-fpm

sudo tee /etc/logrotate.d/web1-php-fpm >/dev/null <<'EOF'
/var/log/php-fpm/*.log /srv/phpapps/*/shared/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/php/php8.4-fpm-reopenlogs >/dev/null 2>&1 || true
    endscript
}
EOF

echo "=== [8/9] Firewall (UFW 22/80/443), fail2ban, unattended-upgrades ==="
sudo ufw --force default deny incoming >/dev/null
sudo ufw --force default allow outgoing >/dev/null
sudo ufw allow 22/tcp >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null

sudo tee /etc/fail2ban/jail.d/sshd-web1.conf >/dev/null <<'EOF'
[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
EOF
sudo systemctl enable --now fail2ban >/dev/null 2>&1 || true
sudo systemctl restart fail2ban >/dev/null 2>&1 || true

sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

echo "=== [9/9] Journald limits & hourly disk alert ==="
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-web1-limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald

sudo tee /usr/local/bin/web1-diskcheck.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$USED" -ge 85 ]; then
  logger -t web1-diskcheck -p user.crit "DISK ALERT: root filesystem ${USED}% full"
fi
EOF
sudo chmod 0755 /usr/local/bin/web1-diskcheck.sh

sudo tee /etc/systemd/system/web1-diskcheck.service >/dev/null <<'EOF'
[Unit]
Description=Web-1 disk space check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/web1-diskcheck.sh
EOF

sudo tee /etc/systemd/system/web1-diskcheck.timer >/dev/null <<'EOF'
[Unit]
Description=Run Web-1 disk space check hourly
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now web1-diskcheck.timer

echo "=== Web-1 base setup complete ==="
php -v | head -n 1
php -m | tr '\n' ' ' && echo
psql --version
caddy version
systemctl is-active postgresql php8.4-fpm caddy fail2ban web1-diskcheck.timer
free -h
df -h /
sudo ufw status | head -n 10
