#!/usr/bin/env bash
# Deploy all OGCEN PHP 8.4 + static sites onto Lightsail Web-1 (3.6.143.66)
# Runs inside the uploaded stage directory containing phpapps/, static/, fpm/, caddy/.
set -Eeuo pipefail

STAGE_DIR="${STAGE_DIR:?STAGE_DIR must be set}"
RELEASE="${RELEASE:?RELEASE must be set}"

echo "=== [1/8] Verify base runtime & users ==="
id webapps >/dev/null
id app-daiskills >/dev/null
id caddy >/dev/null
php -r 'foreach (["curl","mbstring","pdo_sqlite","pgsql","intl","zip","gd","xml"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "Missing PHP ext: $e\n"); exit(1); } }'
command -v caddy >/dev/null

# Deploy atomic release-symlinked PHP app (preserves shared/)
deploy_release_php() {
  local domain="$1"
  local app="/srv/phpapps/$domain"
  local rel="$app/releases/$RELEASE"
  local src="$STAGE_DIR/phpapps/$domain"

  sudo install -d -o root -g root -m 0755 "$app" "$app/releases"
  sudo mkdir -p "$rel"
  sudo cp -a "$src/." "$rel/"
  sudo chown -R root:caddy "$rel"
  sudo find "$rel" -type d -exec chmod 0755 {} +
  sudo find "$rel" -type f -exec chmod 0644 {} +

  sudo ln -s "releases/$RELEASE" "$app/.current-$RELEASE"
  sudo mv -Tf "$app/.current-$RELEASE" "$app/current"
}

# Deploy flat-layout PHP app (organicgrowth.center, nextdigital.in, proseva.org, afteraiwork.com)
# Preserves data/*.sqlite, sessions/, and app/.env.
deploy_flat_php() {
  local domain="$1"
  local has_db="$2"
  local mail_from="$3"
  local mail_name="$4"
  local app="/srv/phpapps/$domain"
  local src="$STAGE_DIR/phpapps/$domain"

  sudo install -d -o webapps -g caddy -m 0755 "$app"
  sudo rsync -a --delete \
    --exclude='data/***' \
    --exclude='sessions/***' \
    --exclude='app/.env' \
    "$src/" "$app/"

  sudo install -d -o webapps -g webapps -m 0700 "$app/sessions"
  sudo chown -R webapps:caddy "$app/public" "$app/app"
  sudo find "$app/public" "$app/app" -type d -exec chmod 0755 {} +
  sudo find "$app/public" "$app/app" -type f -exec chmod 0644 {} +
  if [ -d "$app/tools" ]; then
    sudo chown -R webapps:webapps "$app/tools"
    sudo chmod 0750 "$app/tools"
    sudo find "$app/tools" -type f -exec chmod 0640 {} +
  fi

  if [ "$has_db" = "yes" ]; then
    sudo install -d -o webapps -g webapps -m 0750 "$app/data"
    if ! sudo test -f "$app/app/.env"; then
      sudo tee "$app/app/.env" >/dev/null <<EOF
# Created by 02-deploy-ogcen-sites.sh with empty ZeptoMail token (fail-closed until configured)
ZEPTO_ENDPOINT=https://api.zeptomail.in/v1.1/email
ZEPTO_TOKEN=
MAIL_FROM=${mail_from}
MAIL_FROM_NAME=${mail_name}
MAIL_TO=rajesh.yukta@gmail.com
MAIL_TO_NAME=Rajesh
GA_MEASUREMENT_ID=
EOF
    fi
    sudo chown webapps:webapps "$app/app/.env"
    sudo chmod 0600 "$app/app/.env"
    sudo -u webapps php "$app/tools/init-db.php"
    sudo find "$app/data" -maxdepth 1 -name '*.sqlite*' -exec chown webapps:webapps {} + -exec chmod 0640 {} +
  fi
}

echo "=== [2/8] Deploy PHP 8.4 release apps ==="
# 1. softskills.training
deploy_release_php "softskills.training"
sudo install -d -o webapps -g webapps -m 0750 /srv/phpapps/softskills.training/shared /srv/phpapps/softskills.training/shared/storage
sudo install -o webapps -g caddy -m 0644 "$STAGE_DIR/fpm/app-softskills.training.conf" /etc/php/8.4/fpm/pool.d/app-softskills.training.conf

# 2. nextskillclub.com
deploy_release_php "nextskillclub.com"
sudo install -d -o webapps -g webapps -m 0750 /srv/phpapps/nextskillclub.com/shared /srv/phpapps/nextskillclub.com/shared/storage
sudo install -o webapps -g caddy -m 0644 "$STAGE_DIR/fpm/app-nextskillclub.com.conf" /etc/php/8.4/fpm/pool.d/app-nextskillclub.com.conf

# 3. localcen.com (v6)
deploy_release_php "localcen.com"
sudo install -d -o webapps -g webapps -m 0750 /srv/phpapps/localcen.com/shared
sudo install -d -o webapps -g webapps -m 0700 /srv/phpapps/localcen.com/shared/contact /srv/phpapps/localcen.com/shared/sessions
if ! sudo test -f /srv/phpapps/localcen.com/shared/.env; then
  sudo install -o webapps -g webapps -m 0640 "$STAGE_DIR/env/localcen.com.env" /srv/phpapps/localcen.com/shared/.env
fi
sudo install -o root -g root -m 0644 "$STAGE_DIR/fpm/app-localcen.com.conf" /etc/php/8.4/fpm/pool.d/app-localcen.com.conf

# 4. mrajesh.com
deploy_release_php "mrajesh.com"
sudo install -d -o webapps -g webapps -m 0750 /srv/phpapps/mrajesh.com/shared
sudo install -d -o webapps -g webapps -m 0700 /srv/phpapps/mrajesh.com/shared/contact /srv/phpapps/mrajesh.com/shared/sessions
if ! sudo test -f /srv/phpapps/mrajesh.com/shared/.env; then
  sudo install -o webapps -g webapps -m 0640 "$STAGE_DIR/env/mrajesh.com.env" /srv/phpapps/mrajesh.com/shared/.env
fi
sudo install -o root -g root -m 0644 "$STAGE_DIR/fpm/app-mrajesh.com.conf" /etc/php/8.4/fpm/pool.d/app-mrajesh.com.conf

# 5. daiskills.com (isolated user app-daiskills + SQLite enquiries + outbox timer)
deploy_release_php "daiskills.com"
sudo chown -R root:app-daiskills /srv/phpapps/daiskills.com/current/app
sudo find /srv/phpapps/daiskills.com/current/app -type d -exec chmod 0750 {} +
sudo find /srv/phpapps/daiskills.com/current/app -type f -exec chmod 0640 {} +
sudo install -d -o app-daiskills -g app-daiskills -m 0700 /srv/phpapps/daiskills.com/shared /srv/phpapps/daiskills.com/shared/sessions
if ! sudo test -f /srv/phpapps/daiskills.com/shared/config.json; then
  DAI_HASH=$(openssl rand -hex 32)
  sudo tee /srv/phpapps/daiskills.com/shared/config.json >/dev/null <<EOF
{
  "hash_key": "${DAI_HASH}",
  "mail": {
    "endpoint": "https://api.zeptomail.in/v1.1/email",
    "token": "",
    "from": "noreply@daiskills.com",
    "to": "rajesh.yukta@gmail.com",
    "to_name": "DAI Skills"
  }
}
EOF
fi
sudo chown app-daiskills:app-daiskills /srv/phpapps/daiskills.com/shared/config.json
sudo chmod 0600 /srv/phpapps/daiskills.com/shared/config.json
sudo -u app-daiskills env DAI_SHARED_DIR=/srv/phpapps/daiskills.com/shared \
  php -r 'umask(0077); require $argv[1]."/app/forms.php"; $c=require $argv[1]."/app/config.php"; enquiry_db($c);' \
  /srv/phpapps/daiskills.com/current
sudo chmod 0600 /srv/phpapps/daiskills.com/shared/enquiries.sqlite
sudo chown app-daiskills:app-daiskills /srv/phpapps/daiskills.com/shared/enquiries.sqlite

sudo tee /etc/php/8.4/fpm/pool.d/app-daiskills.com.conf >/dev/null <<'EOF'
; Managed: DAI Skills PHP deployment (Web-1)
[app-daiskills.com]
user = app-daiskills
group = app-daiskills
listen = /run/php/app-daiskills.com.sock
listen.owner = app-daiskills
listen.group = caddy
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 15s
pm.max_requests = 400
request_terminate_timeout = 30s
clear_env = yes
security.limit_extensions = .php
env[DAI_SHARED_DIR] = /srv/phpapps/daiskills.com/shared
php_admin_value[memory_limit] = 128M
php_admin_value[post_max_size] = 32K
php_admin_value[upload_max_filesize] = 1K
php_admin_value[max_execution_time] = 25
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /srv/phpapps/daiskills.com/shared/php-errors.log
php_admin_value[open_basedir] = /srv/phpapps/daiskills.com:/etc/ssl/certs:/usr/share/ca-certificates
php_admin_value[session.save_path] = /srv/phpapps/daiskills.com/shared/sessions
php_admin_value[session.gc_maxlifetime] = 7200
php_admin_value[expose_php] = 0
EOF

sudo tee /etc/systemd/system/daiskills-mail.service >/dev/null <<'EOF'
[Unit]
Description=DAI Skills enquiry notification retries and retention
After=network-online.target
[Service]
Type=oneshot
User=app-daiskills
Group=app-daiskills
Environment=DAI_SHARED_DIR=/srv/phpapps/daiskills.com/shared
ExecStart=/usr/bin/php /srv/phpapps/daiskills.com/current/tools/process-outbox.php
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/srv/phpapps/daiskills.com/shared
EOF

sudo tee /etc/systemd/system/daiskills-mail.timer >/dev/null <<'EOF'
[Unit]
Description=Process DAI Skills enquiry notifications every five minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF

# 6. dev.srikalabhairavam.com
deploy_release_php "dev.srikalabhairavam.com"
sudo install -o root -g root -m 0644 "$STAGE_DIR/fpm/app-dev.srikalabhairavam.com.conf" /etc/php/8.4/fpm/pool.d/app-dev.srikalabhairavam.com.conf

echo "=== [3/8] Deploy flat PHP 8.4 sites + pools ==="
deploy_flat_php "organicgrowth.center" "yes" "noreply@ogcen.com" "Organic Growth Center"
deploy_flat_php "nextdigital.in" "yes" "noreply@nextdigital.in" "Next Digital"
deploy_flat_php "proseva.org" "yes" "noreply@proseva.org" "ProSeva"
deploy_flat_php "afteraiwork.com" "no" "" ""

for domain in organicgrowth.center nextdigital.in proseva.org afteraiwork.com; do
  sudo tee "/etc/php/8.4/fpm/pool.d/app-${domain}.conf" >/dev/null <<EOF
[app-${domain}]
user = webapps
group = webapps
listen = /run/php/app-${domain}.sock
listen.owner = webapps
listen.group = caddy
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 15s
pm.max_requests = 500
request_terminate_timeout = 20s
clear_env = yes
security.limit_extensions = .php
php_admin_value[memory_limit] = 64M
php_admin_value[post_max_size] = 64K
php_admin_value[max_execution_time] = 15
php_admin_flag[file_uploads] = off
php_admin_value[error_log] = /var/log/php-fpm/${domain}.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[open_basedir] = /srv/phpapps/${domain}:/etc/ssl/certs:/usr/share/ca-certificates:/tmp:/usr/share/php
php_admin_value[session.save_path] = /srv/phpapps/${domain}/sessions
php_admin_value[expose_php] = 0
EOF
done

echo "=== [4/8] Lint all deployed PHP files ==="
sudo find "$STAGE_DIR/phpapps" -type f -name '*.php' -print0 | xargs -0 -n1 php -l >/dev/null
PHP_COUNT=$(sudo find /srv/phpapps -type f -name '*.php' | wc -l)
echo "PHP syntax lint OK across ${PHP_COUNT} files"

echo "=== [5/8] Deploy static sites ==="
deploy_static_root() {
  local domain="$1"
  local dest="$2"
  local owner="$3"
  sudo install -d -o root -g caddy -m 0755 "$dest"
  sudo rsync -a --delete "$STAGE_DIR/static/$domain/" "$dest/"
  sudo chown -R "$owner" "$dest"
  sudo find "$dest" -type d -exec chmod 0755 {} +
  sudo find "$dest" -type f -exec chmod 0644 {} +
}

deploy_static_release() {
  local domain="$1"
  local base="$2"
  local owner="$3"
  local rel="$base/releases/$RELEASE"
  local sub="$4"
  sudo install -d -o root -g caddy -m 0755 "$base" "$base/releases"
  if [ -n "$sub" ]; then
    sudo mkdir -p "$rel/$sub"
    sudo cp -a "$STAGE_DIR/static/$domain/." "$rel/$sub/"
  else
    sudo mkdir -p "$rel"
    sudo cp -a "$STAGE_DIR/static/$domain/." "$rel/"
  fi
  sudo chown -R "$owner" "$rel"
  sudo find "$rel" -type d -exec chmod 0755 {} +
  sudo find "$rel" -type f -exec chmod 0644 {} +
  sudo ln -s "$rel" "$base/.current-$RELEASE"
  sudo mv -Tf "$base/.current-$RELEASE" "$base/current"
}

deploy_static_root "rajeshforbharat.com" "/srv/static/rajeshforbharat.com" "webapps:caddy"
deploy_static_root "forbharat.in" "/srv/static/forbharat.in" "root:caddy"
deploy_static_root "haindaviswaraj.org.in" "/srv/static/haindaviswaraj.org.in" "root:caddy"
deploy_static_root "dev.haindaviswaraj.org.in" "/srv/static/dev.haindaviswaraj.org.in" "webapps:caddy"
deploy_static_root "srikalabhairavam.com" "/srv/static/srikalabhairavam.com" "root:caddy"
deploy_static_root "kalabhairavam.com" "/srv/static/kalabhairavam.com" "webapps:caddy"

deploy_static_release "jyothularajesh.com" "/srv/static/jyothularajesh.com" "root:caddy" ""
deploy_static_release "navduta.com" "/srv/phpapps/navduta.com" "webapps:caddy" "public"
deploy_static_release "dev2.srikalabhairavam.com" "/srv/static/dev2.srikalabhairavam.com" "root:caddy" ""
deploy_static_release "dev8.srikalabhairavam.com" "/srv/static/dev8.srikalabhairavam.com" "root:caddy" ""
deploy_static_release "dev9.srikalabhairavam.com" "/srv/static/dev9.srikalabhairavam.com" "root:caddy" ""
deploy_static_release "dev10.srikalabhairavam.com" "/srv/static/dev10.srikalabhairavam.com" "root:caddy" ""

echo "=== [6/8] Disable default www.conf FPM pool & validate/restart php8.4-fpm ==="
if sudo test -f /etc/php/8.4/fpm/pool.d/www.conf; then
  sudo mv /etc/php/8.4/fpm/pool.d/www.conf /etc/php/8.4/fpm/pool.d/www.conf.disabled
fi
sudo php-fpm8.4 -t
sudo systemctl restart php8.4-fpm
sudo systemctl daemon-reload
sudo systemctl enable --now daiskills-mail.timer

echo "=== [7/8] Install Caddy site files, pre-create logs & validate/reload Caddy ==="
sudo find "$STAGE_DIR/caddy" -maxdepth 1 -name '*.caddy' -exec install -o root -g root -m 0644 {} /etc/caddy/sites-enabled/ \;
sudo install -d -o caddy -g caddy -m 0750 /var/log/caddy
while IFS= read -r logfile; do
  [ -n "$logfile" ] || continue
  sudo install -d -o caddy -g caddy -m 0750 "$(dirname "$logfile")"
  if ! sudo test -e "$logfile"; then
    sudo install -o caddy -g caddy -m 0640 /dev/null "$logfile"
  else
    sudo chown caddy:caddy "$logfile"
    sudo chmod 0640 "$logfile"
  fi
done < <(grep -RhoE '/var/log/caddy/[A-Za-z0-9._/-]+\.log' /etc/caddy/sites-enabled/*.caddy | sort -u)

sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo systemctl reload caddy
sleep 1

echo "=== [8/8] Run PHP site test suites & summary ==="
cp -a "$STAGE_DIR/caddy/softskills.training.caddy" "$STAGE_DIR/phpapps/softskills.training.caddy"
php "$STAGE_DIR/phpapps/softskills.training/tests/run.php"
sudo -u webapps php /srv/phpapps/nextskillclub.com/current/tests/run.php
sudo -u webapps php /srv/phpapps/localcen.com/current/tests/run.php
sudo -u webapps php /srv/phpapps/mrajesh.com/current/tests/run.php
sudo -u app-daiskills php /srv/phpapps/daiskills.com/current/tools/test.php >/dev/null && echo "daiskills test.php OK"

systemctl is-active --quiet postgresql php8.4-fpm caddy fail2ban daiskills-mail.timer web1-diskcheck.timer
echo "Active sockets in /run/php:"
ls -1 /run/php/app-*.sock | wc -l
echo "Enabled Caddy site files:"
ls -1 /etc/caddy/sites-enabled/*.caddy | wc -l
echo "Deploy release $RELEASE completed."
