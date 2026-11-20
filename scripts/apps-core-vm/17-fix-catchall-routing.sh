#!/usr/bin/env bash
# Runs on Apps-Core-VM. Installs the host router (/route in apps-core-tls-ask.py) and the catch-all
# that uses it (templates/Caddyfile.apps-core-vm), so POST bodies reach NextDP Core on brand hosts.
# Backs up both live files, validates as the caddy user, reloads Caddy (no restart), runs the tests,
# and restores the backups automatically if anything fails. Env: NEW_CADDYFILE, NEW_ASK (uploaded).
set -Eeuo pipefail
exec 2>&1
NEW_CADDYFILE="${NEW_CADDYFILE:?}"; NEW_ASK="${NEW_ASK:?}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BK="/var/backups/caddy/pre-routing-fix-$TS"
sudo install -d -m 0750 "$BK"
sudo cp -a /etc/caddy/Caddyfile "$BK/Caddyfile"
sudo cp -a /usr/local/bin/apps-core-tls-ask.py "$BK/apps-core-tls-ask.py"
echo "backup: $BK"

rollback() {
  echo "!! rolling back"
  sudo install -m 0644 "$BK/Caddyfile" /etc/caddy/Caddyfile
  sudo install -m 0755 "$BK/apps-core-tls-ask.py" /usr/local/bin/apps-core-tls-ask.py
  sudo systemctl restart apps-core-tls-ask
  sudo systemctl reload caddy
  echo "!! restored $BK"
}

echo "== validate new Caddyfile as the caddy user"
sudo install -o caddy -g caddy -m 0640 "$NEW_CADDYFILE" /tmp/Caddyfile.candidate
sudo -u caddy caddy adapt --config /tmp/Caddyfile.candidate --adapter caddyfile >/dev/null
sudo rm -f /tmp/Caddyfile.candidate
python3 -m py_compile "$NEW_ASK"

trap 'rc=$?; [ $rc -ne 0 ] && rollback; rm -f "$NEW_CADDYFILE" "$NEW_ASK"; exit $rc' EXIT
echo "== install router (apps-core-tls-ask) and Caddyfile"
sudo install -m 0755 "$NEW_ASK" /usr/local/bin/apps-core-tls-ask.py
sudo systemctl restart apps-core-tls-ask
for i in $(seq 1 20); do curl -fsS http://127.0.0.1:8099/healthz >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS http://127.0.0.1:8099/healthz >/dev/null
sudo install -m 0644 "$NEW_CADDYFILE" /etc/caddy/Caddyfile
sudo systemctl reload caddy
sleep 2
systemctl is-active --quiet caddy

echo "== tests through live Caddy"
fail=0
chk() { # want url curl-args...
  local want="$1" label="$2"; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@")
  if [[ " $want " == *" $got "* ]]; then echo "  ok   $label -> $got"; else echo "  FAIL $label -> $got (want $want)"; fail=1; fi
}
for h in console.nextdp.com admin.nextdp.com; do
  chk "200" "GET  $h/login" --resolve "$h:443:127.0.0.1" "https://$h/login"
  chk "403 419" "POST $h/login (CSRF reject, not 502)" --resolve "$h:443:127.0.0.1" -X POST -d 'x=1' "https://$h/login"
done
chk "401" "POST console.nextdp.com/webhooks/dns (bad signature, not 502)" --resolve "console.nextdp.com:443:127.0.0.1" -X POST -H 'Content-Type: application/json' -d '{"event":"webhook.test"}' https://console.nextdp.com/webhooks/dns
chk "200" "GET  accounts.nextdp.com/ (Next iDP)" --resolve "accounts.nextdp.com:443:127.0.0.1" https://accounts.nextdp.com/
chk "200" "GET  nextidp.com/ (Next iDP)" --resolve "nextidp.com:443:127.0.0.1" https://nextidp.com/
chk "200 302" "GET  core.nextdp.com/login" --resolve "core.nextdp.com:443:127.0.0.1" https://core.nextdp.com/login
chk "200" "ask  console.nextdp.com" "http://127.0.0.1:8099/ask?domain=console.nextdp.com"
chk "200" "ask  accounts.nextdp.com" "http://127.0.0.1:8099/ask?domain=accounts.nextdp.com"
chk "403" "ask  not-ours.example.com" "http://127.0.0.1:8099/ask?domain=not-ours.example.com"
since="$(date -u -d '-1 min' '+%Y-%m-%d %H:%M:%S')"
n=$(sudo journalctl -u caddy --since "$since" --no-pager | grep -c 'Body length 0' || true)
echo "  caddy 'Body length 0' errors in the last minute: $n"
[ "$n" = 0 ] || fail=1
[ "$fail" = 0 ] || { echo "TESTS FAILED"; exit 1; }
echo "ROUTING_FIX_OK (backup $BK)"
