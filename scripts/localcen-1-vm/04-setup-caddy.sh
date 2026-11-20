#!/usr/bin/env bash
# Install the LocalCen Caddyfile on LocalCen-1-VM.
#   MODE=validate : adapt the staged Caddyfile only (no change).
#   MODE=apply    : DNS gate (all 4 console hosts -> this VM on their authoritative servers), install, reload,
#                   wait for certificates, HTTPS checks. Restores the previous Caddyfile if it does not validate.
set -Eeuo pipefail
exec 2>&1
MODE="${MODE:?validate|apply}"
STAGE_DIR="${STAGE_DIR:?}"
SRC="$STAGE_DIR/Caddyfile"
PUBLIC_IP=3.111.132.3
HOSTS="${HOSTS:-localcen.cconsole.com admin.localcen.cconsole.com console.localcen.com admin.localcen.com}"
trap 'rm -rf "$STAGE_DIR"' EXIT
cd /tmp
for f in admin-localcen.access.log localcen.access.log public-localcen.access.log; do
  [ -f /var/log/caddy/$f ] || sudo install -o caddy -g caddy -m 0640 /dev/null /var/log/caddy/$f
done
sudo install -m 0644 "$SRC" /tmp/.Caddyfile.lc1
if ! sudo -u caddy caddy adapt --config /tmp/.Caddyfile.lc1 --adapter caddyfile >/dev/null; then echo "FATAL: Caddyfile does not adapt" >&2; exit 1; fi
echo "  Caddyfile adapts OK"
if [ "$MODE" = validate ]; then sudo rm -f /tmp/.Caddyfile.lc1; echo "VALIDATE_OK"; exit 0; fi

echo "=== DNS gate ==="
bad=0
for h in $HOSTS; do
  zone=$(echo "$h" | awk -F. '{print $(NF-1)"."$NF}')
  ns=$(dig +short NS "$zone" @1.1.1.1 | head -1)
  a=$(dig +short A "$h" @"${ns%.}" | tail -1); p=$(dig +short A "$h" @1.1.1.1 | tail -1)
  printf '  %-30s auth(%s)=%-15s 1.1.1.1=%s\n' "$h" "${ns%.}" "$a" "$p"
  [ "$a" = "$PUBLIC_IP" ] || bad=1
done
[ "$bad" = 0 ] || { echo "FATAL: not all console hosts point to $PUBLIC_IP yet" >&2; sudo rm -f /tmp/.Caddyfile.lc1; exit 1; }

echo "=== install + reload ==="
TS=$(date -u +%Y%m%dT%H%M%SZ)
sudo cp -p /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak-$TS"
sudo install -m 0644 -o root -g root /tmp/.Caddyfile.lc1 /etc/caddy/Caddyfile; sudo rm -f /tmp/.Caddyfile.lc1
if ! sudo systemctl reload caddy; then
  sudo cp -p "/etc/caddy/Caddyfile.bak-$TS" /etc/caddy/Caddyfile; sudo systemctl reload caddy || true
  echo "FATAL: reload failed - previous Caddyfile restored" >&2; exit 1
fi
echo "  reloaded"

echo "=== certificates + HTTPS ==="
for h in $HOSTS; do
  ok=no
  for i in $(seq 1 36); do curl -sS -o /dev/null --max-time 8 --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null && { ok=yes; break; }; sleep 5; done
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$h:443:127.0.0.1" "https://$h/")
  api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$h:443:127.0.0.1" "https://$h/v1/me")
  issuer=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  printf '  %-30s tls=%-3s /=%s /v1/me=%s issuer=%s\n' "$h" "$ok" "$code" "$api" "${issuer:-none}"
done
echo "  unknown host (must get no cert): $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve not-a-customer.example.org:443:127.0.0.1 https://not-a-customer.example.org/ 2>/dev/null || echo refused)"
echo "APPLY_DONE"
