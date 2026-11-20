#!/usr/bin/env bash
# Retire CConsole Hub (reseller-mw) on the Mail VM after it moved to Web-1 (2026-11-20).
# Removes the Caddy site, the webapps crontab and stops/disables PHP-FPM (only the hub used it).
# KEEPS /srv/phpapps/cconsole-hub (+ .env) and the cconsole_hub DB for reference; they are still in the
# nightly off-site backup. Refuses to run while any hub host still resolves to this VM on ns1/ns2.
set -Eeuo pipefail
exec 2>&1
cd /tmp
SITE=/etc/caddy/sites-enabled/cconsole-hub.caddy
HOSTS="api.hub.cconsole.com sandbox.hub.cconsole.com hub.cconsole.com admin.hub.cconsole.com docs.hub.cconsole.com"
SELF_IP="52.66.111.138"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ARCH=/var/backups/nextdp/retired-cconsole-hub-$TS

echo "=== [1/4] DNS must no longer point at the Mail VM ==="
for h in $HOSTS; do
  for ns in 52.66.165.1 52.66.25.51; do
    a=$(dig +short A "$h" @"$ns" | paste -sd,)
    [ "$a" = "$SELF_IP" ] && { echo "FATAL: $h still -> $SELF_IP on $ns" >&2; exit 1; }
  done
  printf '  %-26s -> %s\n' "$h" "$(dig +short A "$h" @52.66.165.1 | paste -sd,)"
done

echo "=== [2/4] archive config to $ARCH ==="
sudo install -d -m 0750 -o root -g ubuntu "$ARCH"
[ -f "$SITE" ] && sudo cp -p "$SITE" "$ARCH/"
sudo cp -p /etc/php/8.4/fpm/pool.d/app-cconsole-hub.conf "$ARCH/" 2>/dev/null || true
sudo crontab -u webapps -l > /tmp/.cchub-cron 2>/dev/null && sudo install -m 0640 -o root -g ubuntu /tmp/.cchub-cron "$ARCH/webapps.crontab"; rm -f /tmp/.cchub-cron
sudo ls -1 "$ARCH"

echo "=== [3/4] remove Caddy site + reload (validated as caddy user) ==="
if [ -f "$SITE" ]; then
  sudo rm -f "$SITE"
  if ! sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    echo "FATAL: Caddy config invalid without the hub site; restoring" >&2
    sudo install -m 0644 -o root -g root "$ARCH/$(basename "$SITE")" "$SITE"; exit 1
  fi
  sudo systemctl reload caddy
  echo "  removed + reloaded"
else
  echo "  site already removed"
fi

echo "=== [4/4] cron off, PHP-FPM off ==="
sudo crontab -u webapps -r 2>/dev/null && echo "  webapps crontab removed" || echo "  no webapps crontab"
others=$(ls /etc/php/8.4/fpm/pool.d/ 2>/dev/null | grep -vE '^(app-cconsole-hub\.conf|www\.conf)$' || true)
if [ -z "$others" ]; then
  sudo systemctl disable --now php8.4-fpm >/dev/null 2>&1 || true
  echo "  php8.4-fpm stopped + disabled (no other pools)"
else
  echo "  other FPM pools present ($others) - php8.4-fpm left running"
fi
systemctl is-active nextdp nextdp-worker nextdp-scheduler caddy | paste -sd' '
for u in https://mail.nextdp.com/ https://dithim.com/; do printf '  %-26s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u")"; done
free -m | awk 'NR==2{print "  RAM used "$3" / "$2" MiB"}'
echo "RETIRED. Kept: /srv/phpapps/cconsole-hub, DB cconsole_hub (see docs/TODO.md)."
