#!/usr/bin/env bash
# Runs on Apps-Core-VM. READ-ONLY. Exports brands and every domain linked to a brand from the
# staged R2 copy (default nextdp_core_r2), plus the brands of the live nextdp_core for comparison,
# as one JSON file (OUT_FILE). No secret columns are selected (no keys, secrets, passwords,
# auth codes, contact details).
set -Eeuo pipefail
exec 2>&1

SRC_DB="${SRC_DB:-nextdp_core_r2}"
LIVE_DB="${LIVE_DB:-nextdp_core}"
OUT_FILE="${OUT_FILE:?OUT_FILE must be set}"
[[ "$SRC_DB" =~ ^[a-z][a-z0-9_]*$ && "$LIVE_DB" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "FATAL: invalid DB name"; exit 1; }
[[ "$OUT_FILE" == /tmp/r2-export-*.json ]] || { echo "FATAL: OUT_FILE must be /tmp/r2-export-*.json"; exit 1; }
cd /tmp
Q() { sudo -u postgres psql -p 5432 -d "$1" -XAt -v ON_ERROR_STOP=1 -c "$2"; }

SRC_JSON="$(Q "$SRC_DB" "
SELECT json_build_object(
  'database', current_database(),
  'comment', shobj_description((SELECT oid FROM pg_database WHERE datname = current_database()), 'pg_database'),
  'brands', (SELECT COALESCE(json_agg(b ORDER BY b.created_at), '[]') FROM (
      SELECT id, slug, name, legal_name, status, primary_domain, admin_domain, console_domain,
             idp_host, idp_status, primary_product, sender_email, nameservers, created_at
      FROM brands) b),
  'features', (SELECT COALESCE(json_agg(f ORDER BY f.brand_id, f.feature_key), '[]') FROM (
      SELECT brand_id, feature_key, is_enabled FROM brand_features) f),
  'connections', (SELECT COALESCE(json_agg(c ORDER BY c.brand_id, c.kind), '[]') FROM (
      SELECT brand_id, kind, base_url, nameservers, active FROM brand_service_connections) c),
  'users', (SELECT COALESCE(json_agg(u ORDER BY u.created_at), '[]') FROM (
      SELECT u.id::text, u.brand_id, u.name, u.active, (u.deleted_at IS NOT NULL) AS deleted, u.created_at,
             -- Shield keeps the login email in auth_identities.secret (secret2 is the hash: never selected)
             COALESCE(NULLIF(u.email, ''), (SELECT i.secret FROM auth_identities i
                      WHERE i.user_id = u.id AND i.type = 'email_password' ORDER BY i.id LIMIT 1)) AS email
      FROM users u) u),
  'domains', (SELECT COALESCE(json_agg(d ORDER BY d.fqdn), '[]') FROM (
      SELECT d.id::text, d.fqdn, d.status, d.registered_at, d.expires_at, d.auto_renew, d.brand_id,
             d.user_id::text, p.key AS provider,
             (SELECT string_agg(n.host, ' ' ORDER BY n.sort_order) FROM domain_nameservers n WHERE n.domain_id = d.id) AS nameservers
      FROM domains d LEFT JOIN domain_providers p ON p.id = d.provider_id) d),
  'external_domains', (SELECT COALESCE(json_agg(e ORDER BY e.fqdn), '[]') FROM (
      SELECT id::text, fqdn, status, verified_at, user_id::text, created_at FROM external_domains) e),
  'dns_zones', (SELECT COALESCE(json_agg(z ORDER BY z.fqdn), '[]') FROM (
      SELECT fqdn, status, source, brand_id, user_id::text, domain_id::text, external_domain_id::text,
             delegated_at, created_at FROM dns_zones) z),
  'sites', (SELECT COALESCE(json_agg(s ORDER BY s.host), '[]') FROM (
      SELECT 'local' AS kind, host, status, dns_status, domain_source, brand_id, user_id::text, title FROM local_sites
      UNION ALL SELECT 'blog', host, status, dns_status, domain_source, brand_id, user_id::text, title FROM blog_sites
      UNION ALL SELECT 'docs', host, status, dns_status, domain_source, brand_id, user_id::text, title FROM docs_sites
      UNION ALL SELECT 'handcraft', host, status, dns_status, domain_source, brand_id, user_id::text, title FROM handcraft_sites) s)
)::text;")"

LIVE_JSON="$(Q "$LIVE_DB" "
SELECT json_build_object(
  'database', current_database(),
  'brands', (SELECT COALESCE(json_agg(b ORDER BY b.slug), '[]') FROM (
      SELECT slug, name, status, primary_domain, admin_domain, console_domain FROM brands) b),
  'domains', (SELECT COALESCE(json_agg(fqdn ORDER BY fqdn), '[]') FROM domains),
  'external_domains', (SELECT COALESCE(json_agg(fqdn ORDER BY fqdn), '[]') FROM external_domains),
  'dns_zones', (SELECT COALESCE(json_agg(fqdn ORDER BY fqdn), '[]') FROM dns_zones)
)::text;")"

umask 077
printf '{"generated_at":"%s","vm":"%s","source":%s,"live":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$SRC_JSON" "$LIVE_JSON" > "$OUT_FILE"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); s=d['source']; print('  exported', {k: len(v) for k, v in s.items() if isinstance(v, list)}, 'live brands', len(d['live']['brands']))" "$OUT_FILE"
