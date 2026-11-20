#!/usr/bin/env bash
# DNS-VM (EC2 t3.small, Ubuntu 24.04) — Base Setup (Idempotent)
# Configures secondary private IP (for NS-2 EIP), 2 GiB swap, PostgreSQL 16 (pdns + dns_db),
# PowerDNS authoritative server bound explicitly to both private IPs (NS-1 + NS-2) + loopback API,
# Caddy 2, /srv/apps/dns-service layout, UFW (22, 53 tcp+udp, 80, 443), fail2ban, journald caps, disk check.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

SECRETS_FILE=/root/.dns-vm-secrets.env

echo "=== [1/8] Configure dual EC2 private IPs (NS-1 + NS-2) persistently via Netplan ==="
IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
MAC=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/mac")
PRIV1=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/local-ipv4")
SUBNET_CIDR=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/subnet-ipv4-cidr-block")
CIDR_PREFIX="${SUBNET_CIDR#*/}"
ALL_IPS=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/local-ipv4s")
PRIV2=""
while IFS= read -r ip; do
  ip=$(echo "$ip" | tr -d '\r ')
  if [ -n "$ip" ] && [ "$ip" != "$PRIV1" ]; then
    PRIV2="$ip"
    break
  fi
done <<< "$ALL_IPS"

[ -n "$PRIV1" ] || { echo "FATAL: could not resolve primary private IP from IMDS"; exit 1; }
[ -n "$PRIV2" ] || { echo "FATAL: secondary private IP not found in IMDS"; exit 1; }

IFACE=$(ip -o -4 addr show | awk -v ip="$PRIV1" '$4 ~ ("^" ip "/") {print $2; exit}')
[ -n "$IFACE" ] || { echo "FATAL: could not find network interface for $PRIV1"; exit 1; }
echo "  Interface=$IFACE PrimaryPriv=$PRIV1 SecondaryPriv=$PRIV2/$CIDR_PREFIX"

sudo tee /etc/netplan/60-ns2-secondary.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      addresses:
        - ${PRIV2}/${CIDR_PREFIX}
EOF
sudo chmod 600 /etc/netplan/60-ns2-secondary.yaml
sudo netplan apply
ip -4 addr show dev "$IFACE" | grep -q "$PRIV2/" || { echo "FATAL: secondary IP $PRIV2 missing after netplan apply"; exit 1; }

echo "=== [2/8] Swap (2 GiB) & base packages ==="
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-dns-vm-swap.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-dns-vm-swap.conf >/dev/null || true

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release debian-keyring debian-archive-keyring \
  apt-transport-https jq netcat-openbsd openssl dnsutils unzip ufw fail2ban

echo "=== [3/8] On-box secrets (/root/.dns-vm-secrets.env, 0600) ==="
if ! sudo test -f "$SECRETS_FILE"; then
  sudo tee "$SECRETS_FILE" >/dev/null <<EOF
# Generated on-box by 01-server-setup.sh — never print or copy off-box unencrypted
PG_PASS_PDNS=$(openssl rand -hex 24)
PG_PASS_DNS_SVC=$(openssl rand -hex 24)
PDNS_API_KEY=$(openssl rand -hex 32)
CONNECT_SECRET=$(openssl rand -hex 32)
DNS_VM_PRIV1=${PRIV1}
DNS_VM_PRIV2=${PRIV2}
EOF
  sudo chmod 600 "$SECRETS_FILE"
fi
set -a
# shellcheck disable=SC1090
source <(sudo cat "$SECRETS_FILE")
set +a

echo "=== [4/8] PostgreSQL 16 (pdns + dns_db, loopback-only) ==="
sudo apt-get install -y postgresql postgresql-contrib
sudo tee /etc/postgresql/16/main/conf.d/99-dns-vm.conf >/dev/null <<'EOF'
# Tuned for 2 GiB shared DNS-VM (PowerDNS + dns-service + Caddy)
listen_addresses = 'localhost'
max_connections = 80
shared_buffers = 256MB
effective_cache_size = 1GB
work_mem = 4MB
maintenance_work_mem = 64MB
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

ensure_pg_db "pdns"  "$PG_PASS_PDNS"    "pdns"
ensure_pg_db "dns_u" "$PG_PASS_DNS_SVC" "dns_db"

echo "=== [5/8] PowerDNS Authoritative Server (dual-IP NS-1 + NS-2 + loopback HTTP API) ==="
sudo apt-get install -y pdns-server pdns-backend-pgsql

PDNS_SCHEMA=""
for cand in /usr/share/pdns-backend-pgsql/schema/schema.pgsql.sql /usr/share/doc/pdns-backend-pgsql/schema.pgsql.sql; do
  if [ -f "$cand" ]; then
    PDNS_SCHEMA="$cand"
    break
  fi
done
[ -n "$PDNS_SCHEMA" ] || { echo "FATAL: PowerDNS schema.pgsql.sql not found"; exit 1; }

if ! sudo -u postgres psql -d pdns -tAc "SELECT to_regclass('public.domains')" | grep -qx 'domains'; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d pdns -f "$PDNS_SCHEMA" >/dev/null
fi
sudo -u postgres psql -d pdns -qc "REASSIGN OWNED BY postgres TO pdns; GRANT ALL ON ALL TABLES IN SCHEMA public TO pdns; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO pdns;" 2>/dev/null || \
  sudo -u postgres psql -d pdns -qc "GRANT ALL ON ALL TABLES IN SCHEMA public TO pdns; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO pdns;"

# Remove vendor drop-ins that conflict with our explicit gpgsql/no-bind config
sudo rm -f /etc/powerdns/pdns.d/bind.conf /etc/powerdns/pdns.d/pdns.local.gpgsql.conf

sudo tee /etc/powerdns/pdns.conf >/dev/null <<EOF
# Managed by aws-setup-and-migrations — DNS-VM dual-IP primary (NS-1 + NS-2)
include-dir=/etc/powerdns/pdns.d
setuid=pdns
setgid=pdns
local-address=${PRIV1},${PRIV2}
local-port=53
primary=yes
default-soa-content=ns1.presencive.com dns-admin.presencive.com 0 10800 3600 1209600 300
security-poll-suffix=
version-string=anonymous
api=yes
webserver=yes
webserver-address=127.0.0.1
webserver-port=8081
webserver-allow-from=127.0.0.0/8
EOF
sudo chmod 0644 /etc/powerdns/pdns.conf

sudo tee /etc/powerdns/pdns.d/00-gpgsql.conf >/dev/null <<EOF
launch=gpgsql
gpgsql-host=127.0.0.1
gpgsql-port=5432
gpgsql-dbname=pdns
gpgsql-user=pdns
gpgsql-password=${PG_PASS_PDNS}
gpgsql-dnssec=no
EOF
sudo chown root:pdns /etc/powerdns/pdns.d/00-gpgsql.conf
sudo chmod 0640 /etc/powerdns/pdns.d/00-gpgsql.conf

sudo tee /etc/powerdns/pdns.d/10-api.conf >/dev/null <<EOF
api-key=${PDNS_API_KEY}
EOF
sudo chown root:pdns /etc/powerdns/pdns.d/10-api.conf
sudo chmod 0640 /etc/powerdns/pdns.d/10-api.conf

sudo systemctl enable --now pdns
if ! sudo systemctl restart pdns; then
  sudo journalctl -u pdns -n 30 --no-pager || true
  exit 1
fi
sleep 2
sudo systemctl is-active pdns
curl -fsS -H "X-API-Key: ${PDNS_API_KEY}" "http://127.0.0.1:8081/api/v1/servers/localhost/zones" >/dev/null
echo "  PowerDNS API ok (127.0.0.1:8081)"

echo "=== [6/8] Caddy 2 ==="
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y caddy
fi
sudo mkdir -p /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy
sudo systemctl enable caddy

echo "=== [7/8] App user & directory layout ==="
id -u webapps >/dev/null 2>&1 || sudo useradd --system --home /srv/apps --shell /usr/sbin/nologin webapps
sudo usermod -aG webapps caddy || true
sudo install -d -o webapps -g webapps /srv/apps/dns-service/{releases,shared,logs}
sudo chmod 750 /srv/apps/dns-service/shared
sudo chown webapps:caddy /srv/apps/dns-service/logs
sudo chmod 775 /srv/apps/dns-service/logs

echo "=== [8/8] Firewall (UFW 22, 53 tcp+udp, 80, 443), fail2ban, journald caps & disk alert ==="
sudo ufw --force default deny incoming >/dev/null
sudo ufw --force default allow outgoing >/dev/null
sudo ufw allow 22/tcp >/dev/null
sudo ufw allow 53/tcp >/dev/null
sudo ufw allow 53/udp >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null
sudo systemctl enable --now fail2ban >/dev/null 2>&1 || true

sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-dns-vm-limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald

sudo tee /usr/local/bin/dns-vm-diskcheck.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$USED" -ge 85 ]; then
  logger -t dns-vm-diskcheck -p user.crit "DISK ALERT: root filesystem ${USED}% full"
fi
EOF
sudo chmod 0755 /usr/local/bin/dns-vm-diskcheck.sh

sudo tee /etc/systemd/system/dns-vm-diskcheck.service >/dev/null <<'EOF'
[Unit]
Description=DNS-VM disk space check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns-vm-diskcheck.sh
EOF

sudo tee /etc/systemd/system/dns-vm-diskcheck.timer >/dev/null <<'EOF'
[Unit]
Description=Run DNS-VM disk space check hourly
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dns-vm-diskcheck.timer

echo "=== DNS-VM base setup complete ==="
psql --version
pdns_server --version 2>&1 | sed -n '1p'
sudo ss -ulnp | grep ':53' || true
free -h
df -h /
sudo ufw status
