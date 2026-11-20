#!/usr/bin/env bash
# Install rajeshyukta.in.caddy on Web-1, pre-create log owned by caddy, reload Caddy cleanly,
# and verify automatic Let's Encrypt TLS certificate acquisition for rajeshyukta.in & www.rajeshyukta.in.
set -Eeuo pipefail

CADDY_STAGE="${CADDY_STAGE:?CADDY_STAGE must be set}"
[ -f "$CADDY_STAGE" ] || { echo "FATAL: missing $CADDY_STAGE" >&2; exit 1; }

echo "=== [1/4] Pre-create log file owned by caddy:caddy ==="
sudo install -d -o caddy -g caddy -m 0750 /var/log/caddy
if sudo test -e /var/log/caddy/rajeshyukta.in.log; then
  sudo chown caddy:caddy /var/log/caddy/rajeshyukta.in.log
  sudo chmod 0640 /var/log/caddy/rajeshyukta.in.log
else
  sudo install -o caddy -g caddy -m 0640 /dev/null /var/log/caddy/rajeshyukta.in.log
fi

echo "=== [2/4] Install /etc/caddy/sites-enabled/rajeshyukta.in.caddy & reload Caddy ==="
sed 's/\r$//' "$CADDY_STAGE" | sudo tee /etc/caddy/sites-enabled/rajeshyukta.in.caddy >/dev/null
sudo chown root:root /etc/caddy/sites-enabled/rajeshyukta.in.caddy
sudo chmod 0644 /etc/caddy/sites-enabled/rajeshyukta.in.caddy

sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo systemctl reload caddy

echo "=== [3/4] Wait for Let's Encrypt SSL certificates (rajeshyukta.in & www.rajeshyukta.in) ==="
for host in rajeshyukta.in www.rajeshyukta.in; do
  ok=0
  for attempt in $(seq 1 15); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${host}:443:127.0.0.1" "https://${host}/" 2>/dev/null || echo 000)"
    if [ "$code" = "301" ] || [ "$code" = "308" ] || [ "$code" = "200" ]; then
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    echo "FATAL: TLS/HTTPS did not become ready for $host (last HTTP $code)" >&2
    sudo journalctl -u caddy -n 30 --no-pager >&2 || true
    exit 1
  fi
  echo "  $host -> HTTPS HTTP $code"
done

echo "=== [4/4] Inspect issued certificates (local TLS) ==="
for host in rajeshyukta.in www.rajeshyukta.in; do
  echo "--- $host ---"
  echo | openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null | openssl x509 -noout -subject -issuer -dates
done
