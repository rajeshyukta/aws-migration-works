#!/usr/bin/env bash
# Runs on the DNS VM. READ-ONLY. Exports tenants, zones and zone transfers from the staged R2 copy
# of the old dns-service DB (default dns_service_r2), plus the live dns_db zones and the live
# PowerDNS zones (pdns, with record counts) for comparison, as one JSON file (OUT_FILE).
# No secret columns are selected (no passwords, key hashes, webhook secrets).
set -Eeuo pipefail
exec 2>&1

SRC_DB="${SRC_DB:-dns_service_r2}"
LIVE_DB="${LIVE_DB:-dns_db}"
PDNS_DB="${PDNS_DB:-pdns}"
OUT_FILE="${OUT_FILE:?OUT_FILE must be set}"
for d in "$SRC_DB" "$LIVE_DB" "$PDNS_DB"; do [[ "$d" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "FATAL: invalid DB name"; exit 1; }; done
[[ "$OUT_FILE" == /tmp/r2-export-*.json ]] || { echo "FATAL: OUT_FILE must be /tmp/r2-export-*.json"; exit 1; }
cd /tmp
Q() { sudo -u postgres psql -p 5432 -d "$1" -XAt -v ON_ERROR_STOP=1 -c "$2"; }

TENANTS_SQL="SELECT COALESCE(json_agg(t ORDER BY t.created_at), '[]') FROM (
    SELECT id, slug, name, brand, account, nameservers, soa_contact, status, require_connect,
           substring(webhook_url from '^[a-z]+://[^/?#]+') AS webhook_host,
           (deleted_at IS NOT NULL) AS deleted, created_at,
           (SELECT count(*) FROM api_keys k WHERE k.tenant_id = tenants.id AND k.revoked_at IS NULL AND k.deleted_at IS NULL) AS active_api_keys,
           (SELECT string_agg(u.email || ' (' || u.role || ')', ', ' ORDER BY u.email) FROM users u WHERE u.tenant_id = tenants.id AND u.deleted_at IS NULL) AS users
    FROM tenants) t"
ZONES_SQL="SELECT COALESCE(json_agg(z ORDER BY z.fqdn), '[]') FROM (
    SELECT z.fqdn, z.tenant_id, z.account, z.ref, z.source, z.status, z.zone_created_at, z.delegated_at,
           z.last_checked_at, (z.deleted_at IS NOT NULL) AS deleted, z.created_at
    FROM dns_zones z) z"

SRC_JSON="$(Q "$SRC_DB" "
SELECT json_build_object(
  'database', current_database(),
  'comment', shobj_description((SELECT oid FROM pg_database WHERE datname = current_database()), 'pg_database'),
  'super_admins', (SELECT COALESCE(json_agg(email ORDER BY email), '[]') FROM users WHERE tenant_id IS NULL AND deleted_at IS NULL),
  'tenants', ($TENANTS_SQL),
  'zones', ($ZONES_SQL),
  'transfers', (SELECT COALESCE(json_agg(x ORDER BY x.created_at), '[]') FROM (
      SELECT fqdn, from_tenant_id, to_tenant_id, redelegated, created_at FROM dns_zone_transfers) x)
)::text;")"

LIVE_JSON="$(Q "$LIVE_DB" "
SELECT json_build_object(
  'database', current_database(),
  'tenants', ($TENANTS_SQL),
  'zones', ($ZONES_SQL)
)::text;")"

PDNS_JSON="$(Q "$PDNS_DB" "
SELECT json_build_object(
  'database', current_database(),
  'zones', (SELECT COALESCE(json_agg(z ORDER BY z.name), '[]') FROM (
      SELECT d.name, d.type, d.account,
             (SELECT count(*) FROM records r WHERE r.domain_id = d.id AND r.type IS NOT NULL) AS records,
             (SELECT string_agg(DISTINCT r.content, ' ') FROM records r
               WHERE r.domain_id = d.id AND r.type = 'A' AND r.name = d.name) AS apex_a,
             (SELECT string_agg(DISTINCT r.content, ' ') FROM records r
               WHERE r.domain_id = d.id AND r.type = 'MX' AND r.name = d.name) AS apex_mx
      FROM domains d) z)
)::text;")"

umask 077
printf '{"generated_at":"%s","vm":"%s","source":%s,"live":%s,"pdns":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$SRC_JSON" "$LIVE_JSON" "$PDNS_JSON" > "$OUT_FILE"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('  exported tenants', len(d['source']['tenants']), 'zones', len(d['source']['zones']), '| live zones', len(d['live']['zones']), '| pdns zones', len(d['pdns']['zones']))" "$OUT_FILE"
