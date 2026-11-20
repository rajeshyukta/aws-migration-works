#!/usr/bin/env bash
# Runs on the DNS VM. READ-ONLY report on the old Azure PowerDNS data (pdns_azure, exported from the
# nmc-dns-1 disk) against the old dns-service zone list (dns_service_r2) and the live data (dns_db, pdns).
# Shows: zones per tenant, where every A/AAAA record points (old Azure IP -> label), CNAME/MX targets,
# and for zones that already exist live, which old record sets differ from or are missing in live.
set -Eeuo pipefail
exec 2>&1
OLD="${OLD_PDNS:-pdns_azure}"; TEN="${TENANT_SLUG:-nextdp}"
cd /tmp
Q() { sudo -u postgres psql -p 5432 -d "$1" -X -v ON_ERROR_STOP=1 -P footer=off -c "$2"; }
QT() { sudo -u postgres psql -p 5432 -d "$1" -XAt -v ON_ERROR_STOP=1 -c "$2"; }

IPMAP="VALUES ('20.207.200.1','AZURE nmc-php-stage-1 (PHP/static sites)'),('20.219.8.247','AZURE nmc-apps-1 (Go apps)'),
 ('20.235.94.100','AZURE nmc-idp-1 (Next iDP, Next Pay)'),('20.207.194.99','AZURE nmc-mail-1'),('40.80.95.1','AZURE nmc-main (NMC)'),
 ('4.224.62.222','AZURE nmc-dns-1 (ns1)'),('172.198.131.111','AZURE nmc-dns-2 (ns2)'),('20.198.69.133','AZURE nmc-s3-1'),
 ('20.198.0.200','AZURE nmc-db-1'),('20.204.163.200','AZURE nmc-db-2'),('40.80.82.1','AZURE nmc-cache-1'),('172.198.131.42','AZURE esangh-dev-1'),
 ('3.6.143.66','AWS Web-1'),('43.204.42.99','AWS Apps-Core-VM'),('52.66.111.138','AWS Mail VM'),('52.66.165.1','AWS DNS VM ns1'),
 ('52.66.25.51','AWS DNS VM ns2'),('3.111.132.3','AWS LocalCen-1-VM')"

# Old zone list of the tenant from the dns-service backup, to join in pdns_azure.
TENANT_ZONES="$(QT dns_service_r2 "SELECT string_agg(quote_literal(z.fqdn), ',') FROM dns_zones z JOIN tenants t ON t.id = z.tenant_id WHERE t.slug = '$TEN' AND z.deleted_at IS NULL")"
LIVE_ZONES="$(QT pdns "SELECT string_agg(quote_literal(name), ',') FROM domains")"

echo "== 1. zones in $OLD (old Azure PowerDNS, final state 2026-11-18 10:50 IST)"
Q "$OLD" "SELECT count(*) AS zones, (SELECT count(*) FROM records WHERE type IS NOT NULL) AS records,
  count(*) FILTER (WHERE name IN ($TENANT_ZONES)) AS in_old_${TEN}_tenant,
  count(*) FILTER (WHERE name IN ($LIVE_ZONES)) AS already_live_on_aws FROM domains"
echo "== 2. old $TEN tenant zones (dns-service backup) missing from $OLD"
Q "$OLD" "SELECT f AS fqdn FROM unnest(ARRAY[$TENANT_ZONES]) f WHERE f NOT IN (SELECT name FROM domains) ORDER BY 1"
echo "== 3. zones in $OLD that are NOT in the old $TEN tenant list (other tenants or newer than 2026-11-16)"
Q "$OLD" "SELECT d.name, d.account, (SELECT r.content FROM records r WHERE r.domain_id=d.id AND r.type='NS' AND r.name=d.name ORDER BY 1 LIMIT 1) AS ns1
  FROM domains d WHERE d.name NOT IN ($TENANT_ZONES) ORDER BY 1"
echo "== 4. where A/AAAA records point (tenant $TEN zones)"
Q "$OLD" "WITH m(ip, label) AS ($IPMAP)
  SELECT r.type, r.content AS ip, COALESCE(m.label, 'other / external') AS host, count(*) AS records, count(DISTINCT r.domain_id) AS zones
  FROM records r JOIN domains d ON d.id = r.domain_id LEFT JOIN m ON m.ip = r.content
  WHERE r.type IN ('A','AAAA') AND d.name IN ($TENANT_ZONES) GROUP BY 1,2,3 ORDER BY 4 DESC"
echo "== 5. CNAME / MX / NS(sub) targets (tenant $TEN zones)"
Q "$OLD" "SELECT r.type, CASE WHEN r.type='MX' THEN r.prio || ' ' || r.content ELSE r.content END AS target, count(*) AS records
  FROM records r JOIN domains d ON d.id = r.domain_id
  WHERE d.name IN ($TENANT_ZONES) AND (r.type IN ('CNAME','MX') OR (r.type='NS' AND r.name <> d.name))
  GROUP BY 1,2 ORDER BY 1, 3 DESC"
echo "== 6. records on old Azure IPs other than the PHP VM (need a decision)"
Q "$OLD" "WITH m(ip, label) AS ($IPMAP)
  SELECT d.name AS zone, r.name, r.type, r.content, m.label FROM records r JOIN domains d ON d.id=r.domain_id JOIN m ON m.ip=r.content
  WHERE d.name IN ($TENANT_ZONES) AND m.label LIKE 'AZURE%' AND r.content <> '20.207.200.1' ORDER BY 1,2"
echo "== 7. record types per zone (tenant $TEN zones)"
Q "$OLD" "SELECT d.name AS zone, count(*) FILTER (WHERE r.type NOT IN ('SOA','NS') OR r.name<>d.name) AS records,
  string_agg(DISTINCT r.type, ',') AS types FROM domains d JOIN records r ON r.domain_id=d.id AND r.type IS NOT NULL
  WHERE d.name IN ($TENANT_ZONES) GROUP BY 1 ORDER BY 1"

echo "== 8. zones already live on AWS: old record sets missing in live, or different"
sudo -u postgres psql -p 5432 -d "$OLD" -XAt -F$'\t' -c "
  SELECT d.name, r.name, r.type, CASE WHEN r.type IN ('MX','SRV') THEN r.prio || ' ' || r.content ELSE r.content END
  FROM records r JOIN domains d ON d.id=r.domain_id
  WHERE r.type IS NOT NULL AND r.type NOT IN ('SOA') AND NOT (r.type='NS' AND r.name=d.name) AND d.name IN ($LIVE_ZONES)" | sort > /tmp/.old-rr.$$
sudo -u postgres psql -p 5432 -d pdns -XAt -F$'\t' -c "
  SELECT d.name, r.name, r.type, CASE WHEN r.type IN ('MX','SRV') THEN r.prio || ' ' || r.content ELSE r.content END
  FROM records r JOIN domains d ON d.id=r.domain_id
  WHERE r.type IS NOT NULL AND r.type NOT IN ('SOA') AND NOT (r.type='NS' AND r.name=d.name)" | sort > /tmp/.new-rr.$$
python3 - /tmp/.old-rr.$$ /tmp/.new-rr.$$ <<'PY'
import sys
from collections import defaultdict
def load(p):
    s = defaultdict(set)
    for line in open(p):
        z, n, t, c = line.rstrip("\n").split("\t")
        s[(z, n, t)].add(c.rstrip("."))
    return s
old, new = load(sys.argv[1]), load(sys.argv[2])
missing = [k for k in old if k not in new]
differ = [k for k in old if k in new and old[k] != new[k]]
print(f"  old record sets in live zones: {len(old)}; missing in live: {len(missing)}; different in live: {len(differ)}")
for k in sorted(missing):
    print(f"  MISSING  {k[0]:24} {k[1]:40} {k[2]:5} {' | '.join(sorted(old[k]))[:110]}")
for k in sorted(differ):
    print(f"  DIFFERS  {k[0]:24} {k[1]:40} {k[2]:5} old: {' | '.join(sorted(old[k]))[:60]}  live: {' | '.join(sorted(new[k]))[:60]}")
PY
rm -f /tmp/.old-rr.$$ /tmp/.new-rr.$$
