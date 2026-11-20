#!/usr/bin/env bash
# Status check for consolidated Apps-Core-VM (43.204.42.99)
set -uo pipefail

echo "=== Services ==="
for svc in postgresql redis-server caddy apps-core-tls-ask nextidp nextidp-worker nextdp nextdp-worker nextdp-scheduler localcen localcen-worker localcen-caddy-sync.path localcen-caddy-sync.timer localcen-cleanup.timer; do
  st="$(systemctl is-active "$svc" 2>/dev/null || true)"
  [ -z "$st" ] && st="unknown"
  printf "  %-30s %s\n" "$svc" "$st"
done

echo ""
echo "=== Listening Ports ==="
sudo ss -tlnp | awk 'NR>1 {print "TCP " $4}' | grep -E ':(22|80|443|5432|6379|8080|8090|8092|8099)$' | sort -u -t: -k2 -n

echo ""
echo "=== Local Backend Health ==="
printf "  apps-core-tls-ask (:8099) -> %s\n" "$(curl -sS --max-time 3 http://127.0.0.1:8099/healthz | tr -d '\n' || echo ERR)"
printf "  nextidp           (:8080) -> %s\n" "$(curl -sS --max-time 3 http://127.0.0.1:8080/health/version | tr -d '\n' || echo ERR)"
printf "  nextdp-core       (:8090) -> %s\n" "$(curl -sS --max-time 3 http://127.0.0.1:8090/health | tr -d '\n' || echo ERR)"
printf "  localcen          (:8092) -> %s\n" "$(curl -sS --max-time 3 http://127.0.0.1:8092/healthz | tr -d '\n' || echo ERR)"

echo ""
echo "=== Caddy Local Routing Check (--resolve -k) ==="
for h in nextidp.com core.nextdp.com localcen.cconsole.com admin.localcen.cconsole.com; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null || echo "ERR")
  printf "  %-30s -> HTTP %s\n" "$h" "$code"
done

echo ""
echo "=== Memory & Disk ==="
free -h
df -h /
