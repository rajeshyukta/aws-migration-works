#!/usr/bin/env bash
# Runs on Apps-Core-VM. Imports every domain of one OLD Azure brand (from the staged R2 copy
# nextdp_core_r2) into one LIVE brand of nextdp_core as EXTERNAL domains, with their managed-DNS
# zone rows. Registered domains (`domains`) become external too (owner decision 2026-11-20: nothing
# is registered through a registrar API yet). Ids are kept, so the dns-service zone refs (= the
# NextDP Core dns_zones.id) stay valid.
#
# Owner: every imported domain and zone goes to ONE existing live account of the destination brand,
# given by its public id (OWNER_PUBLIC_ID, e.g. xcztbuqqh = rajesh@nextdp.com). No user is ever
# created or copied (owner decision 2026-11-20).
#
# One transaction. DRY_RUN=1 (default) prints the plan and rolls back; DRY_RUN=0 commits.
# Env: SRC_BRAND_SLUG, DST_BRAND_ID, OWNER_PUBLIC_ID (required), SKIP_FQDNS (space list, optional),
#      SRC_DB (nextdp_core_r2), DST_DB (nextdp_core), DRY_RUN, REPORT_TSV (optional output file)
set -Eeuo pipefail
exec 2>&1

SRC_DB="${SRC_DB:-nextdp_core_r2}"
DST_DB="${DST_DB:-nextdp_core}"
SRC_BRAND_SLUG="${SRC_BRAND_SLUG:?SRC_BRAND_SLUG required}"
DST_BRAND_ID="${DST_BRAND_ID:?DST_BRAND_ID required}"
OWNER_PUBLIC_ID="${OWNER_PUBLIC_ID:?OWNER_PUBLIC_ID required (public id of the live owner account)}"
SKIP_FQDNS="${SKIP_FQDNS:-}"
DRY_RUN="${DRY_RUN:-1}"
REPORT_TSV="${REPORT_TSV:-}"
for v in "$SRC_DB" "$DST_DB" "$SRC_BRAND_SLUG"; do [[ "$v" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "FATAL: invalid name '$v'"; exit 1; }; done
[[ "$DST_BRAND_ID" =~ ^[0-9a-f-]{36}$ ]] || { echo "FATAL: invalid DST_BRAND_ID"; exit 1; }
[[ "$OWNER_PUBLIC_ID" =~ ^[a-z0-9]{4,32}$ ]] || { echo "FATAL: invalid OWNER_PUBLIC_ID"; exit 1; }
for f in $SKIP_FQDNS; do [[ "$f" =~ ^[a-z0-9.-]+$ ]] || { echo "FATAL: invalid fqdn in SKIP_FQDNS"; exit 1; }; done
[[ "$DRY_RUN" =~ ^[01]$ ]] || { echo "FATAL: DRY_RUN must be 0 or 1"; exit 1; }

WORK="$(sudo -u postgres mktemp -d /tmp/r2-brand-import.XXXXXX)"
cleanup() { sudo rm -rf "$WORK"; }
trap cleanup EXIT
cd /tmp
SQ() { sudo -u postgres psql -p 5432 -d "$SRC_DB" -XAt -v ON_ERROR_STOP=1 "$@"; }

SRC_BRAND_ID="$(SQ -c "SELECT id FROM brands WHERE slug = '${SRC_BRAND_SLUG}'")"
[ -n "$SRC_BRAND_ID" ] || { echo "FATAL: brand ${SRC_BRAND_SLUG} not in ${SRC_DB}"; exit 1; }
echo "source brand ${SRC_BRAND_SLUG} = ${SRC_BRAND_ID} (${SRC_DB}); destination brand ${DST_BRAND_ID} (${DST_DB}); DRY_RUN=${DRY_RUN}"

# ---- 1. export the source rows to CSV (postgres-only temp dir, removed on exit) ----
X() { SQ -c "COPY ($2) TO STDOUT WITH (FORMAT csv, HEADER)" | sudo -u postgres tee "$WORK/$1.csv" >/dev/null; }
# Every domain of the brand: external ones (owner in brand) + registered ones (brand_id or owner in brand).
X items "
  SELECT e.id, e.user_id::text AS user_id, lower(e.fqdn) AS fqdn, e.unicode_name, e.tld, e.status, e.verify_token,
         e.verified_at, e.last_checked_at, e.notes, e.created_at, e.updated_at, 'external' AS origin
  FROM external_domains e JOIN users u ON u.id = e.user_id WHERE u.brand_id = '${SRC_BRAND_ID}'
  UNION ALL
  SELECT d.id, d.user_id::text, lower(d.fqdn), d.unicode_name, d.tld, 'verified', NULL,
         COALESCE(d.registered_at, d.created_at), NULL, 'managed-dns', d.created_at, d.updated_at, 'registered'
  FROM domains d LEFT JOIN users u ON u.id = d.user_id
  WHERE d.brand_id = '${SRC_BRAND_ID}' OR (d.brand_id IS NULL AND u.brand_id = '${SRC_BRAND_ID}')"
X zones "
  SELECT z.id, z.user_id::text AS user_id, lower(z.fqdn) AS fqdn, z.source AS old_source,
         COALESCE(z.external_domain_id, z.domain_id)::text AS item_id, z.status, z.zone_created_at, z.delegated_at,
         z.armed_at, z.last_checked_at, z.check_count, z.pass_count, z.created_at, z.updated_at,
         z.ns_status, z.ns_checked_at, z.degraded_at
  FROM dns_zones z WHERE z.brand_id = '${SRC_BRAND_ID}'"

# ---- 2. one transaction on the destination ----
SKIP_ARRAY="{$(echo "$SKIP_FQDNS" | xargs -n1 2>/dev/null | paste -sd, -)}"
END_CMD="ROLLBACK"; [ "$DRY_RUN" = "0" ] && END_CMD="COMMIT"
sudo -u postgres psql -p 5432 -d "$DST_DB" -X -v ON_ERROR_STOP=1 -q \
  -v dst="$DST_BRAND_ID" -v owner_pid="$OWNER_PUBLIC_ID" -v skip="$SKIP_ARRAY" <<SQL
\\pset footer off
BEGIN;
CREATE TEMP TABLE s_items (id text, user_id text, fqdn text, unicode_name text, tld text, status text, verify_token text,
  verified_at timestamptz, last_checked_at timestamptz, notes text, created_at timestamptz, updated_at timestamptz, origin text) ON COMMIT DROP;
CREATE TEMP TABLE s_zones (id text, user_id text, fqdn text, old_source text, item_id text, status text, zone_created_at timestamptz,
  delegated_at timestamptz, armed_at timestamptz, last_checked_at timestamptz, check_count int, pass_count int,
  created_at timestamptz, updated_at timestamptz, ns_status text, ns_checked_at timestamptz, degraded_at timestamptz) ON COMMIT DROP;
\\copy s_items FROM '$WORK/items.csv' WITH (FORMAT csv, HEADER)
\\copy s_zones FROM '$WORK/zones.csv' WITH (FORMAT csv, HEADER)

CREATE TEMP TABLE params ON COMMIT DROP AS SELECT :'dst'::text AS dst,
  (SELECT u.id FROM users u WHERE u.public_id = :'owner_pid' AND u.brand_id = :'dst' AND u.deleted_at IS NULL) AS owner_id;
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM brands WHERE id = (SELECT dst FROM params)) THEN RAISE EXCEPTION 'destination brand not found'; END IF;
  IF (SELECT owner_id FROM params) IS NULL THEN RAISE EXCEPTION 'OWNER_PUBLIC_ID is not a live account of the destination brand'; END IF;
END \$\$;

-- One row per fqdn: an external row wins over a registered row for the same name.
CREATE TEMP TABLE plan ON COMMIT DROP AS
SELECT DISTINCT ON (fqdn) * FROM s_items WHERE NOT (fqdn = ANY (:'skip'::text[]))
ORDER BY fqdn, (origin = 'external') DESC, created_at;

-- Every domain goes to the one owner account.
CREATE TEMP TABLE owner_map ON COMMIT DROP AS
SELECT DISTINCT p.user_id AS old_id, (SELECT owner_id FROM params) AS new_id FROM plan p;
\\echo '== owner'
SELECT u.public_id, u.id, (SELECT count(*) FROM plan) AS domains FROM users u WHERE u.id = (SELECT owner_id FROM params);
-- Conflicts with what the live brand already has.
CREATE TEMP TABLE result ON COMMIT DROP AS
SELECT p.fqdn, p.origin, p.id AS ext_id, m.new_id AS owner_id,
  (SELECT e.id FROM external_domains e JOIN users u ON u.id = e.user_id WHERE lower(e.fqdn) = p.fqdn AND u.brand_id = :'dst' LIMIT 1) AS live_ext_id,
  EXISTS (SELECT 1 FROM external_domains e WHERE e.id = p.id) AS id_taken,
  z.id AS zone_id, z.status AS zone_status,
  (SELECT lz.brand_id || ':' || lz.status FROM dns_zones lz WHERE lz.fqdn = p.fqdn LIMIT 1) AS live_zone,
  ''::text AS action
FROM plan p JOIN owner_map m ON m.old_id = p.user_id
LEFT JOIN s_zones z ON z.fqdn = p.fqdn;
UPDATE result SET action = CASE
  WHEN live_ext_id IS NOT NULL THEN 'skip: already an external domain of the live brand'
  WHEN id_taken THEN 'skip: external domain id already used'
  WHEN live_zone IS NOT NULL THEN 'external only: a live dns_zones row already exists (' || live_zone || ')'
  WHEN zone_id IS NULL THEN 'external only (no managed-DNS zone in the old brand)'
  ELSE 'external + zone' END;

INSERT INTO external_domains (id, user_id, fqdn, unicode_name, tld, status, verify_token, verified_at, last_checked_at, notes, created_at, updated_at)
SELECT p.id, r.owner_id, p.fqdn, p.unicode_name, p.tld, p.status, p.verify_token, p.verified_at, p.last_checked_at, p.notes, p.created_at, now()
FROM plan p JOIN result r ON r.fqdn = p.fqdn WHERE r.action NOT LIKE 'skip:%';

-- Zone rows: zone_created_at is set because the import into dns-service creates every zone with
-- ref = this id; next_check_at = now() so the poller re-checks the delegation against AWS DNS.
INSERT INTO dns_zones (id, user_id, fqdn, source, domain_id, external_domain_id, status, zone_created_at, delegated_at, armed_at,
  last_checked_at, next_check_at, check_count, pass_count, created_at, updated_at, brand_id, ns_status, ns_checked_at, degraded_at)
SELECT z.id, r.owner_id, z.fqdn, 'external', NULL, r.ext_id, z.status, COALESCE(z.zone_created_at, now()), z.delegated_at, z.armed_at,
  z.last_checked_at, now(), z.check_count, z.pass_count, z.created_at, now(), :'dst', z.ns_status, z.ns_checked_at, z.degraded_at
FROM result r JOIN s_zones z ON z.id = r.zone_id WHERE r.action = 'external + zone'
  AND NOT EXISTS (SELECT 1 FROM dns_zones x WHERE x.id = z.id);

\\echo '== plan per domain'
SELECT r.fqdn, r.origin, COALESCE(r.zone_status, '-') AS old_zone_status, r.zone_id, r.action FROM result r ORDER BY r.fqdn;
\\echo '== totals'
SELECT action, count(*) FROM result GROUP BY 1 ORDER BY 1;
SELECT (SELECT count(*) FROM external_domains e JOIN users u ON u.id = e.user_id WHERE u.brand_id = :'dst') AS live_external_after,
       (SELECT count(*) FROM dns_zones WHERE brand_id = :'dst') AS live_zones_after,
       (SELECT count(*) FROM users WHERE brand_id = :'dst') AS live_users_after;
\\o $WORK/report.tsv
\\pset format unaligned
\\pset fieldsep '\t'
SELECT fqdn, origin, ext_id, zone_id, COALESCE(zone_status, ''), action FROM result ORDER BY fqdn;
\\o
$END_CMD;
\\echo '== ended with $END_CMD'
SQL
if [ -n "$REPORT_TSV" ]; then
  [[ "$REPORT_TSV" == /tmp/r2-import-*.tsv ]] || { echo "FATAL: REPORT_TSV must be /tmp/r2-import-*.tsv"; exit 1; }
  sudo cat "$WORK/report.tsv" > "$REPORT_TSV"
fi
