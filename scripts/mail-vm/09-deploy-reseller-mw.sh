#!/usr/bin/env bash
# OBSOLETE since 2026-11-20: CConsole Hub moved to Web-1 (scripts/web-1-vm/06-deploy-cconsole-hub.*).
# Kept for history only. Do NOT run: it would re-add the hub to the Mail VM.
# Deploy CConsole Hub (reseller-mw) onto the Mail VM (52.66.111.138)
# Installs PHP 8.4-FPM (pm=ondemand), Composer deps, PG db cconsole_hub (Redis DB 1),
# Caddy site blocks, migrations + PlatformSettingsSeeder, and cron jobs.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

STAGE_DIR="${STAGE_DIR:?STAGE_DIR must be set}"
APP_DIR=/srv/phpapps/cconsole-hub
CI4_DIR=$APP_DIR/ci4-app
ENV_FILE=$CI4_DIR/.env
CADDYFILE=/etc/caddy/Caddyfile

echo "=== [1/8] PHP 8.4-FPM + extensions (no Apache) ==="
if ! dpkg -s php8.4-fpm >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends software-properties-common
  sudo add-apt-repository -y ppa:ondrej/php
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    php8.4-fpm php8.4-cli php8.4-common \
    php8.4-pgsql php8.4-mbstring php8.4-curl \
    php8.4-gd php8.4-intl php8.4-zip php8.4-opcache \
    php8.4-redis php8.4-xml php8.4-bcmath unzip
fi

if ! command -v composer >/dev/null 2>&1; then
  TMP_C=$(mktemp)
  curl -fsSL https://getcomposer.org/installer -o "$TMP_C"
  sudo php "$TMP_C" -- --install-dir=/usr/local/bin --filename=composer >/dev/null
  rm -f "$TMP_C"
fi
php -v | head -n 1

echo "=== [2/8] webapps user & directory layout ==="
id -u webapps >/dev/null 2>&1 || sudo useradd --system --home /srv/phpapps --shell /usr/sbin/nologin webapps
sudo usermod -aG webapps caddy || true
sudo mkdir -p "$APP_DIR" "$CI4_DIR/writable"/{cache,logs,session,uploads,keys} \
  "$APP_DIR/frontend/admin/dist" "$APP_DIR/frontend/tenant/dist"

echo "=== [3/8] PostgreSQL 16 database cconsole_hub ==="
DB_PASS_FILE=/root/.cconsole-hub-db-pass
if ! sudo test -f "$DB_PASS_FILE"; then
  openssl rand -hex 24 | sudo tee "$DB_PASS_FILE" >/dev/null
  sudo chmod 600 "$DB_PASS_FILE"
fi
DB_PASS=$(sudo cat "$DB_PASS_FILE")
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='cconsole_hub'" | grep -q 1 \
  || sudo -u postgres psql -qc "CREATE ROLE cconsole_hub LOGIN PASSWORD '${DB_PASS}';")
(cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='cconsole_hub'" | grep -q 1 \
  || sudo -u postgres createdb -O cconsole_hub -E UTF8 cconsole_hub)
(cd /tmp && sudo -u postgres psql -d cconsole_hub -qc "ALTER DATABASE cconsole_hub OWNER TO cconsole_hub; GRANT ALL ON SCHEMA public TO cconsole_hub;")

echo "=== [4/8] Extract app & frontend dists ==="
sudo tar -xzf "$STAGE_DIR/reseller-mw.tar.gz" -C "$APP_DIR"
sudo mkdir -p "$CI4_DIR/writable"/{cache,logs,session,uploads,keys}
sudo chown -R webapps:caddy "$APP_DIR"
sudo chmod -R u=rwX,g=rX,o= "$APP_DIR"
sudo chmod -R 775 "$CI4_DIR/writable"

echo "=== [5/8] .env (Redis DB 1 isolated from nextdp_mail DB 0) ==="
if ! sudo test -f "$ENV_FILE"; then
  REDIS_PW=$(sudo grep -E '^requirepass\s+' /etc/redis/nextdp-override.conf | awk '{print $2}' | head -n 1)
  JWT_SECRET=$(openssl rand -hex 32)
  ENC_KEY="hex2bin:$(openssl rand -hex 32)"
  sudo tee "$ENV_FILE" >/dev/null <<EOF
CI_ENVIRONMENT = production

app.baseURL = 'https://api.hub.cconsole.com/'
app.forceGlobalSecureRequests = true
encryption.key = '${ENC_KEY}'

database.default.hostname = 127.0.0.1
database.default.database = cconsole_hub
database.default.username = cconsole_hub
database.default.password = '${DB_PASS}'
database.default.DBDriver = Postgre
database.default.port = 5432
database.default.charset = utf8

REDIS_HOST = 127.0.0.1
REDIS_PORT = 6379
REDIS_PASSWORD = '${REDIS_PW}'
REDIS_DATABASE = 1
cache.prefix = 'cchub_'

CORS_ALLOWED_ORIGINS = 'https://hub.cconsole.com,https://admin.hub.cconsole.com'

JWT_SECRET = '${JWT_SECRET}'

ZEPTO_MAIL_API_KEY = __SET_ON_SERVER__
ZEPTO_MAIL_FROM_EMAIL = noreply@cconsole.com
ZEPTO_MAIL_FROM_NAME = 'CConsole Hub'

RESELLERCLUB_AUTH_USERID = __SET_ON_SERVER__
RESELLERCLUB_API_KEY = __SET_ON_SERVER__
RESELLERCLUB_CUSTOMER_ID = __SET_ON_SERVER__
RESELLERCLUB_SANDBOX = true
RESELLERCLUB_API_URL = https://httpapi.com/api/
RESELLERCLUB_SANDBOX_URL = https://test.httpapi.com/api/
RESELLERCLUB_DOMAINCHECK_URL = https://domaincheck.httpapi.com/api/

APP_URL = https://api.hub.cconsole.com
ADMIN_URL = https://admin.hub.cconsole.com
TENANT_URL = https://hub.cconsole.com
EOF
  sudo chown webapps:caddy "$ENV_FILE"
  sudo chmod 640 "$ENV_FILE"
fi

echo "=== [6/8] Composer install, migrations & seeders ==="
sudo -u webapps bash -c "cd '$CI4_DIR' && COMPOSER_HOME=/tmp/composer-webapps COMPOSER_ALLOW_SUPERUSER=0 composer install --no-dev --optimize-autoloader --no-interaction --quiet"
sudo chown -R webapps:caddy "$CI4_DIR/vendor"
sudo -u webapps bash -c "cd '$CI4_DIR' && php spark migrate --all && php spark db:seed PlatformSettingsSeeder"

echo "=== [7/8] PHP 8.4-FPM dedicated pool (pm=ondemand) & OPcache ==="
sudo tee /etc/php/8.4/fpm/conf.d/99-cconsole-hub.ini >/dev/null <<'EOF'
opcache.enable=1
opcache.validate_timestamps=0
opcache.memory_consumption=64
opcache.max_accelerated_files=10000
realpath_cache_size=2M
realpath_cache_ttl=600
EOF

sudo tee /etc/php/8.4/fpm/pool.d/app-cconsole-hub.conf >/dev/null <<'EOF'
[app-cconsole-hub]
user = webapps
group = webapps
listen = /run/php/app-cconsole-hub.sock
listen.owner = caddy
listen.group = caddy
listen.mode = 0660

pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500

env[CI_ENVIRONMENT] = production
php_admin_value[open_basedir] = /srv/phpapps/cconsole-hub:/tmp
php_admin_value[memory_limit] = 128M
php_admin_value[upload_max_filesize] = 10M
php_admin_value[post_max_size] = 12M
EOF
sudo php-fpm8.4 -t
sudo systemctl enable --now php8.4-fpm
sudo systemctl restart php8.4-fpm

echo "=== [8/8] Caddy site block & cron ==="
sudo install -d -o caddy -g caddy -m 0755 /var/log/caddy/live
sudo touch /var/log/caddy/live/cconsole-hub-access.log
sudo chown caddy:caddy /var/log/caddy/live/cconsole-hub-access.log
sudo chmod 0644 /var/log/caddy/live/cconsole-hub-access.log
sudo mkdir -p /etc/caddy/sites-enabled
sudo install -m 0644 -o root -g root "$STAGE_DIR/cconsole-hub.caddy" /etc/caddy/sites-enabled/cconsole-hub.caddy
if [ ! -f "$CADDYFILE.bak-pre-cchub" ]; then
  sudo cp -p "$CADDYFILE" "$CADDYFILE.bak-pre-cchub"
fi
sudo install -m 0644 -o root -g root "$STAGE_DIR/Caddyfile.mail-vm" "$CADDYFILE"
sudo caddy validate --config "$CADDYFILE" --adapter caddyfile
sudo chown caddy:caddy /var/log/caddy/live/*.log 2>/dev/null || true
sudo systemctl reload caddy

# Cron jobs for webapps
CRON_TMP=$(mktemp)
cat > "$CRON_TMP" <<'EOF'
15 3 * * * cd /srv/phpapps/cconsole-hub/ci4-app && php spark api:logs-prune --days=90 >> writable/logs/prune.log 2>&1
0 */6 * * * cd /srv/phpapps/cconsole-hub/ci4-app && php spark domains:sync >> writable/logs/domains-sync.log 2>&1
0 4 * * * cd /srv/phpapps/cconsole-hub/ci4-app && php spark domains:renewals >> writable/logs/domains-renewals.log 2>&1
EOF
sudo crontab -u webapps "$CRON_TMP"
rm -f "$CRON_TMP"

echo "=== Verification (local resolve) ==="
systemctl is-active php8.4-fpm caddy postgresql redis-server
for h in api.hub.cconsole.com sandbox.hub.cconsole.com hub.cconsole.com admin.hub.cconsole.com docs.hub.cconsole.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$h:443:127.0.0.1" "https://$h/" || echo "ERR")
  printf "  %-28s -> HTTP %s\n" "$h" "$code"
done
free -h
