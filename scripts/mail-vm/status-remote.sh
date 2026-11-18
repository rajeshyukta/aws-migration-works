#!/usr/bin/env bash
# Check status of standalone NextDP Mail AWS Lightsail VM
set -uo pipefail

echo "=== Services ==="
for svc in postgresql redis-server caddy nextdp nextdp-worker nextdp-scheduler nextdp-certwatch.path nextdp-diskcheck.timer; do
  st="$(systemctl is-active "$svc" 2>/dev/null || true)"
  [ -z "$st" ] && st="unknown"
  printf "  %-24s %s\n" "$svc" "$st"
done

echo ""
echo "=== Listening TCP Ports ==="
sudo ss -tlnp | awk 'NR>1 {print $4}' | grep -oE ':(22|25|80|110|143|443|465|587|993|995|5432|6379|8080)$' | sort -u -t: -k2 -n

echo ""
echo "=== Local Health (/api/health/ready) ==="
curl -sS --max-time 5 http://127.0.0.1:8080/api/health/ready || echo "(nextdp not responding on :8080)"
echo ""

echo "=== HTTPS Endpoints (local resolve) ==="
for h in mail.nextdp.com admin.mail.nextdp.com super-admin.mail.nextdp.com autoconfig.nextdp.com mail.rajesh1.com admin.mail.rajesh1.com super-admin.mail.rajesh1.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null || echo "ERR")
  printf "  %-32s -> HTTP %s\n" "$h" "$code"
done

echo ""
echo "=== Mail TLS Cert (/opt/nextdp/config/tls/mail.nextdp.com.crt) ==="
if [ -f /opt/nextdp/config/tls/mail.nextdp.com.crt ]; then
  openssl x509 -in /opt/nextdp/config/tls/mail.nextdp.com.crt -noout -subject -enddate
else
  echo "  (not synced yet)"
fi

echo ""
echo "=== Database Row Counts (nextdp_mail) ==="
(cd /tmp && sudo -u postgres psql -d nextdp_mail -At \
  -c "SELECT 'organizations='||count(*) FROM organizations" \
  -c "SELECT 'domains='||count(*) FROM domains" \
  -c "SELECT 'users='||count(*) FROM users" \
  -c "SELECT 'mailboxes='||count(*) FROM mailboxes" \
  -c "SELECT 'messages='||count(*) FROM messages" \
  -c "SELECT 'raw_emails='||count(*) FROM raw_emails" 2>/dev/null) || echo "  (tables not migrated yet)"

echo ""
echo "=== Memory & Disk ==="
free -h
df -h /
