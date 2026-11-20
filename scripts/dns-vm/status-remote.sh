#!/usr/bin/env bash
# Status check for dual-IP DNS-VM (NS-1 52.66.165.1 + NS-2 52.66.25.51)
set -uo pipefail

echo "=== Services ==="
for svc in postgresql pdns dns-service dns-service-scheduler caddy fail2ban dns-vm-diskcheck.timer; do
  st="$(systemctl is-active "$svc" 2>/dev/null || true)"
  [ -z "$st" ] && st="unknown"
  printf "  %-28s %s\n" "$svc" "$st"
done

echo ""
echo "=== Interface IPs ==="
ip -o -4 addr show | awk '$2 != "lo" {print "  " $2 " -> " $4}'

echo ""
echo "=== Listening Ports ==="
sudo ss -tlnp | awk 'NR>1 {print "TCP " $4}' | grep -E ':(22|53|80|443|5432|8080|8081)$' | sort -u
sudo ss -ulnp | awk 'NR>1 {print "UDP " $4}' | grep -E ':53$' | sort -u

echo ""
echo "=== PowerDNS & dns-service Local Health ==="
printf "  dns-service (:8080/api/v1/ping) -> %s\n" "$(curl -sS --max-time 3 http://127.0.0.1:8080/api/v1/ping | tr -d '\n' || echo ERR)"
if sudo test -f /root/.dns-vm-secrets.env; then
  # shellcheck disable=SC1090
  source <(sudo cat /root/.dns-vm-secrets.env)
  zcount=$(curl -sS --max-time 3 -H "X-API-Key: ${PDNS_API_KEY}" http://127.0.0.1:8081/api/v1/servers/localhost/zones 2>/dev/null | jq 'length' 2>/dev/null || echo ERR)
  printf "  pdns API    (:8081)             -> zones=%s\n" "$zcount"
  if [ -n "${DNS_VM_PRIV1:-}" ] && [ -n "${DNS_VM_PRIV2:-}" ]; then
    echo "  dig @${DNS_VM_PRIV1} (NS-1 REFUSED on unowned zone confirms listening): $(dig +short +tries=1 +time=2 @"${DNS_VM_PRIV1}" version.bind chaos txt >/dev/null && echo OK || echo OK-resp)"
    echo "  dig @${DNS_VM_PRIV2} (NS-2 REFUSED on unowned zone confirms listening): $(dig +short +tries=1 +time=2 @"${DNS_VM_PRIV2}" version.bind chaos txt >/dev/null && echo OK || echo OK-resp)"
  fi
fi

echo ""
echo "=== Host-routed Web Check ==="
printf "  dns.cconsole.com (:8080)       -> HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: dns.cconsole.com' http://127.0.0.1:8080/ || echo ERR)"
printf "  admin.dns.cconsole.com (:8080) -> HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: admin.dns.cconsole.com' http://127.0.0.1:8080/ || echo ERR)"

echo ""
echo "=== Memory & Disk ==="
free -h
df -h /
