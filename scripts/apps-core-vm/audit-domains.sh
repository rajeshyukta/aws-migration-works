#!/usr/bin/env bash
# READ-ONLY audit: can Next iDP and NextDP Core switch on new domains by themselves on Apps-Core-VM?
set -uo pipefail
exec 2>&1
cd /tmp
IP=43.204.42.99
echo "=== 1. env (non-secret host/edge settings) ==="
NI=$(systemctl show nextidp -p EnvironmentFiles --value | awk '{print $1}'); echo "  nextidp env file: $NI"
sudo grep -E '^(APP_PORT|APP_URL|N1_MASTER_HOST|N1_EDGE_IPS|N1_[A-Z_]*HOST[A-Z_]*|TRUSTED_PROXIES)=' "$NI" 2>/dev/null | sed 's/^/    /'
ND=/srv/apps/nextdp/shared/.env; echo "  nextdp env file: $ND"
sudo grep -E '^(APP_PORT|APP_URL|HOST_CORE|CORE_BASE_URL|ADMIN_BASE_URL|CONSOLE_BASE_URL|MARKETING_BASE_URL|IDP_[A-Z_]*(HOST|URL|ISSUER)[A-Z_]*|TRUSTED_PROXIES|DNS_BACKEND)=' "$ND" | sed 's/^/    /'
echo "=== 2. Caddy: global ask + catch-all ==="
grep -nE 'ask |on_demand|reverse_proxy|status 421|handle_response|^https?://' /etc/caddy/Caddyfile | sed 's/^/    /'
echo "=== 3. ask answers (app endpoint / multiplexer :8099) ==="
for d in nextidp.com core.nextdp.com id.nextdp.com accounts.nextdp.com admin.nextdp.com console.nextdp.com accounts.cconsole.com console.localcen.com random-not-ours.example.org; do
  a=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/_edge/ask?domain=$d")
  b=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8090/internal/tls/ask?domain=$d")
  m=$(curl -s "http://127.0.0.1:8099/ask?domain=$d")
  printf '    %-28s nextidp=%s nextdp=%s mux=%s\n' "$d" "$a" "$b" "$(echo $m | tr -d '\n')"
done
echo "=== 4. Next iDP answers 421 for hosts it does not own (fallback to NextDP Core) ==="
for h in admin.nextdp.com console.nextdp.com console.localcen.com accounts.nextdp.com id.nextdp.com; do
  printf '    %-24s :8080 -> %s   :8090 -> %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" http://127.0.0.1:8080/)" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" http://127.0.0.1:8090/)"
done
echo "=== 5. Through Caddy (local) ==="
for h in nextidp.com core.nextdp.com id.nextdp.com accounts.nextdp.com accounts.cconsole.com admin.nextdp.com console.nextdp.com; do
  r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 --resolve "$h:443:127.0.0.1" "https://$h/")
  iss=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | sed 's/issuer=//' | paste -sd' ')
  printf '    %-24s %s | %s\n' "$h" "${r:0:90}" "${iss:-NO CERT}"
done
echo "=== 6. DNS of IdP/brand hosts (1.1.1.1) ==="
for h in nextidp.com core.nextdp.com id.nextdp.com accounts.nextdp.com admin.nextdp.com console.nextdp.com accounts.cconsole.com admin.localcen.com console.localcen.com accounts.localcen.com; do
  a=$(dig +short A "$h" @1.1.1.1 | tail -1); printf '    %-24s %-15s %s\n' "$h" "${a:--}" "$([ "$a" = $IP ] && echo ok || echo 'NOT this VM')"
done
echo "    TXT _n1-verify.accounts.nextdp.com: $(dig +short TXT _n1-verify.accounts.nextdp.com @1.1.1.1 | paste -sd' ')"
echo "=== 7. realms + brands (DB) ==="
sudo -u postgres psql -X -P pager=off -d nextidp -c "SELECT slug, issuer_host, host_status, status FROM realms ORDER BY created_at" 2>&1 | cut -c1-160
sudo -u postgres psql -X -P pager=off -d nextdp_core -c "SELECT slug, admin_domain, console_domain, idp_host, idp_status, status FROM brands" 2>&1 | cut -c1-160
echo "=== 8. recent ACME / ask errors in Caddy log (24 h) ==="
sudo journalctl -u caddy --since -24h --no-pager -o cat | grep -iE 'obtain|ask|error|failed' | grep -v 'certificate obtained successfully' | tail -8 | cut -c1-220
