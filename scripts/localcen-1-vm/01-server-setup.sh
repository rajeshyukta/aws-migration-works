#!/usr/bin/env bash
# LocalCen-1-VM (3.111.132.3, EC2 i-007e720a8c578aad7) - base setup (idempotent).
# Dedicated VM for LocalCen (customer domains via Caddy on-demand TLS) and later NextBuilder.
# Installs: 2 GiB swap, PostgreSQL 16 (localhost, tuned for 4 GB), Caddy 2, jq/dig, UFW (22/80/443 tcp + 443 udp),
# fail2ban, journald caps, hourly disk check, webapps user + /srv/apps layout. No Redis: LocalCen uses the DB for
# sessions/queue and in-memory cache. Secrets are generated on the VM (/root/.localcen-1-secrets.env) and never printed.
set -Eeuo pipefail
exec 2>&1
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
SECRETS_FILE=/root/.localcen-1-secrets.env

echo "=== [1/8] swap 2 GiB ==="
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-localcen-1-swap.conf >/dev/null
sudo sysctl -q -p /etc/sysctl.d/99-localcen-1-swap.conf || true
swapon --show --noheadings

echo "=== [2/8] base packages ==="
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg debian-keyring debian-archive-keyring \
  apt-transport-https jq dnsutils unzip ufw fail2ban rsync >/dev/null
echo "  ok"

echo "=== [3/8] on-box secrets ($SECRETS_FILE, 0600) ==="
if ! sudo test -f "$SECRETS_FILE"; then
  printf '# Generated on LocalCen-1-VM by 01-server-setup.sh. Never print or copy off-box unencrypted.\nPG_PASS_LOCALCEN=%s\n' "$(openssl rand -hex 24)" \
    | sudo tee "$SECRETS_FILE" >/dev/null
  sudo chmod 600 "$SECRETS_FILE"; echo "  created"
else echo "  exists"; fi
PG_PASS_LOCALCEN="$(sudo grep -E '^PG_PASS_LOCALCEN=' "$SECRETS_FILE" | cut -d= -f2-)"

echo "=== [4/8] PostgreSQL 16 + localcen_db ==="
sudo apt-get install -y -qq postgresql postgresql-contrib >/dev/null
sudo tee /etc/postgresql/16/main/conf.d/99-localcen-1.conf >/dev/null <<'EOF'
# LocalCen-1-VM: 4 GB RAM, PostgreSQL shared with LocalCen (+ NextBuilder later)
listen_addresses = 'localhost'
max_connections = 100
shared_buffers = 512MB
effective_cache_size = 2GB
work_mem = 8MB
maintenance_work_mem = 128MB
password_encryption = scram-sha-256
EOF
sudo systemctl enable -q --now postgresql
sudo systemctl restart postgresql
cd /tmp
if sudo -u postgres psql -XAtc "SELECT 1 FROM pg_roles WHERE rolname='localcen_u'" | grep -q 1; then
  sudo -u postgres psql -Xq -c "ALTER ROLE localcen_u LOGIN PASSWORD '${PG_PASS_LOCALCEN}';"
else
  sudo -u postgres psql -Xq -c "CREATE ROLE localcen_u LOGIN PASSWORD '${PG_PASS_LOCALCEN}';"
fi
unset PG_PASS_LOCALCEN
sudo -u postgres psql -XAtc "SELECT 1 FROM pg_database WHERE datname='localcen_db'" | grep -q 1 || sudo -u postgres createdb -O localcen_u -E UTF8 localcen_db
sudo -u postgres psql -Xq -d localcen_db -c "ALTER DATABASE localcen_db OWNER TO localcen_u; GRANT ALL ON SCHEMA public TO localcen_u;"
echo "  $(psql --version | awk '{print $3}'), db localcen_db ready"

echo "=== [5/8] Caddy 2 ==="
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq caddy >/dev/null
fi
sudo mkdir -p /etc/caddy/sites-enabled /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy
# Until the LocalCen site is installed (02 -Phase sites), serve only a 404 on :80 so no certificates are requested.
if ! sudo grep -q 'LocalCen-1-VM' /etc/caddy/Caddyfile 2>/dev/null; then
  printf '# LocalCen-1-VM placeholder (replaced by templates/Caddyfile.localcen-1-vm in Phase sites)\n:80 {\n\trespond "Not Found" 404\n}\n' | sudo tee /etc/caddy/Caddyfile >/dev/null
fi
sudo systemctl enable -q caddy; sudo systemctl restart caddy
echo "  $(caddy version | cut -d' ' -f1)"

echo "=== [6/8] webapps user + /srv/apps/localcen layout ==="
id -u webapps >/dev/null 2>&1 || sudo useradd --system --create-home --home-dir /srv/apps --shell /usr/sbin/nologin webapps
sudo usermod -aG webapps caddy || true
sudo mkdir -p /srv/apps/localcen/{releases,shared/storage,shared/lang,shared/certs,shared/geo-packs,logs}
sudo chown -R webapps:webapps /srv/apps
sudo chmod 750 /srv/apps/localcen/shared
sudo chown webapps:caddy /srv/apps/localcen/logs; sudo chmod 775 /srv/apps/localcen/logs
sudo chmod 755 /srv/apps /srv/apps/localcen /srv/apps/localcen/releases
echo "  ok"

echo "=== [7/8] UFW (22, 80, 443 tcp + 443 udp), fail2ban ==="
sudo ufw --force default deny incoming >/dev/null
sudo ufw --force default allow outgoing >/dev/null
for r in 22/tcp 80/tcp 443/tcp 443/udp; do sudo ufw allow "$r" >/dev/null; done
sudo ufw --force enable >/dev/null
sudo systemctl enable -q --now fail2ban
sudo ufw status | grep -E 'ALLOW' | grep -v v6 | awk '{print "  "$1}' | paste -sd' '

echo "=== [8/8] journald caps + hourly disk check ==="
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=1G\nSystemMaxFileSize=100M\nRuntimeMaxUse=150M\nMaxRetentionSec=14day\n' | sudo tee /etc/systemd/journald.conf.d/99-localcen-1-limits.conf >/dev/null
sudo systemctl restart systemd-journald
sudo tee /usr/local/bin/localcen-1-diskcheck.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$USED" -ge 85 ] && logger -t localcen-1-diskcheck -p user.crit "DISK ALERT: root filesystem ${USED}% full"
exit 0
EOF
sudo chmod 0755 /usr/local/bin/localcen-1-diskcheck.sh
printf '[Unit]\nDescription=LocalCen-1 disk space check\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/localcen-1-diskcheck.sh\n' | sudo tee /etc/systemd/system/localcen-1-diskcheck.service >/dev/null
printf '[Unit]\nDescription=Hourly LocalCen-1 disk space check\n[Timer]\nOnBootSec=10min\nOnUnitActiveSec=1h\n[Install]\nWantedBy=timers.target\n' | sudo tee /etc/systemd/system/localcen-1-diskcheck.timer >/dev/null
sudo systemctl daemon-reload; sudo systemctl enable -q --now localcen-1-diskcheck.timer
echo "  ok"

echo "=== summary ==="
systemctl is-active postgresql caddy fail2ban localcen-1-diskcheck.timer | paste -sd' '
free -m | awk 'NR==2{print "  RAM used "$3" / "$2" MiB"}'; df -h / | awk 'NR==2{print "  disk "$3" / "$2}'
echo "BASE_SETUP_OK"
