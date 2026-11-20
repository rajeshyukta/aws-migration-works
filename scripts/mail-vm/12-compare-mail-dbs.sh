#!/usr/bin/env bash
# Tasks 1.4 + 1.5 (docs/mail-vm-db-upgrade-r2.md): compare the live AWS nextdp_mail with the staged
# R2 copy (nextdp_mail_r2). Writes ONLY to the staging DB (schema aws_src = copy of live tables).
# Never prints secret values: passwords, DKIM keys and settings are compared by md5 only.
set -Eeuo pipefail
exec 2>&1

LIVE_DB="${LIVE_DB:-nextdp_mail}"
STAGE_DB="${STAGE_DB:-nextdp_mail_r2}"
DNS_SERVER="${DNS_SERVER:-52.66.165.1}"
case "$STAGE_DB" in nextdp_mail_*) ;; *) echo "FATAL: STAGE_DB must be nextdp_mail_<suffix>" >&2; exit 1 ;; esac
cd /tmp
L() { sudo -u postgres psql -p 5432 -d "$LIVE_DB" -X "$@"; }
S() { sudo -u postgres psql -p 5432 -d "$STAGE_DB" -X "$@"; }

echo "=== [1/4] Schema diff (live vs staged R2) ==="
norm() { grep -vE '^(--|SET |SELECT pg_catalog|\\(un)?restrict )' | sed '/^$/d'; }
sudo -u postgres pg_dump -p 5432 --schema-only --no-owner --no-acl "$LIVE_DB" | norm > /tmp/.schema-live.$$
sudo -u postgres pg_dump -p 5432 --schema-only --no-owner --no-acl -N aws_src "$STAGE_DB" | norm > /tmp/.schema-r2.$$
if diff -q /tmp/.schema-live.$$ /tmp/.schema-r2.$$ >/dev/null; then echo "  schemas identical"; else echo "  SCHEMA DIFFERS:"; diff /tmp/.schema-live.$$ /tmp/.schema-r2.$$ | head -40; fi
rm -f /tmp/.schema-live.$$ /tmp/.schema-r2.$$
echo "  live migrations tracked: $(L -At -c 'SELECT count(*) FROM schema_migrations')  r2: $(S -At -c 'SELECT count(*) FROM schema_migrations')"

echo "=== [2/4] Copy live tables into ${STAGE_DB}.aws_src (staging DB only) ==="
S -q -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS aws_src CASCADE; CREATE SCHEMA aws_src;"
for t in $(L -At -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1"); do
  cols=$(S -At -c "SELECT string_agg(quote_ident(c.column_name), ',' ORDER BY c.ordinal_position)
                   FROM information_schema.columns c
                   WHERE c.table_schema='public' AND c.table_name='$t' AND c.is_generated='NEVER'
                     AND c.column_name IN (SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t')")
  S -q -v ON_ERROR_STOP=1 -c "CREATE TABLE aws_src.\"$t\" (LIKE public.\"$t\" INCLUDING DEFAULTS);"
  L -q -v ON_ERROR_STOP=1 -c "\\copy (SELECT $cols FROM public.\"$t\") TO STDOUT" | S -q -v ON_ERROR_STOP=1 -c "\\copy aws_src.\"$t\" ($cols) FROM STDIN"
  printf '  %-24s live=%-6s copied=%s\n' "$t" "$(L -At -c "SELECT count(*) FROM public.\"$t\"")" "$(S -At -c "SELECT count(*) FROM aws_src.\"$t\"")"
done

echo "=== [3/4] Comparison report ==="
S -P pager=off -v ON_ERROR_STOP=1 <<'SQL'
\echo '--- 3.1 baseline sanity: AWS rows above the August max id must all be created after T0 (2026-11-18 09:27 UTC)'
WITH b(t, aug_max) AS (VALUES ('raw_emails',3634),('messages',1420),('attachments',137),('domains',24),('users',28),('mailboxes',28),('folders',145),('audit_logs',91))
SELECT b.t, b.aug_max,
  CASE b.t
    WHEN 'raw_emails'  THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>3634), count(*) FILTER (WHERE (id>3634) <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.raw_emails)
    WHEN 'messages'    THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>1420), count(*) FILTER (WHERE (id>1420) <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.messages)
    WHEN 'attachments' THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>137),  count(*) FILTER (WHERE (id>137)  <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.attachments)
    WHEN 'domains'     THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>24),   count(*) FILTER (WHERE (id>24)   <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.domains)
    WHEN 'users'       THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>28),   count(*) FILTER (WHERE (id>28)   <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.users)
    WHEN 'mailboxes'   THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>28),   count(*) FILTER (WHERE (id>28)   <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.mailboxes)
    WHEN 'folders'     THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>145),  count(*) FILTER (WHERE (id>145)  <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.folders)
    WHEN 'audit_logs'  THEN (SELECT format('%s new / %s misplaced', count(*) FILTER (WHERE id>91),   count(*) FILTER (WHERE (id>91)   <> (created_at>'2026-11-18 09:27+00'))) FROM aws_src.audit_logs)
  END AS aws_delta
FROM b;

\echo '--- 3.2 organizations: same id <-> name in both?'
SELECT a.id aws_id, a.name, r.id r2_id, md5(a.settings::text)=md5(r.settings::text) same_settings
FROM aws_src.organizations a FULL JOIN public.organizations r ON r.name=a.name ORDER BY 1;

\echo '--- 3.3 org settings: differing top-level keys (md5 only)'
SELECT a.name, s.k, coalesce(a.settings,'{}') ? s.k AS in_aws, coalesce(r.settings,'{}') ? s.k AS in_r2,
       left(md5(coalesce((a.settings->s.k)::text,'')),8) aws_md5, left(md5(coalesce((r.settings->s.k)::text,'')),8) r2_md5
FROM aws_src.organizations a JOIN public.organizations r ON r.name=a.name
CROSS JOIN LATERAL (SELECT jsonb_object_keys(coalesce(a.settings,'{}')) UNION SELECT jsonb_object_keys(coalesce(r.settings,'{}'))) s(k)
WHERE (a.settings->s.k) IS DISTINCT FROM (r.settings->s.k) ORDER BY 1,2;

\echo '--- 3.4 system_settings: keys that differ (md5 only)'
SELECT coalesce(a.key,r.key) AS key, a.key IS NOT NULL in_aws, r.key IS NOT NULL in_r2
FROM aws_src.system_settings a FULL JOIN public.system_settings r ON r.key=a.key
WHERE md5(coalesce(a.value::text,'')) <> md5(coalesce(r.value::text,'')) OR a.key IS NULL OR r.key IS NULL ORDER BY 1;
\echo '    storage config present in R2 settings? (must be no; s3.nextdp.com is gone)'
SELECT 'system_settings' src, key FROM public.system_settings WHERE key ILIKE '%storage%' OR value::text ILIKE '%s3.nextdp%'
UNION ALL SELECT 'org:'||name, 'storage' FROM public.organizations WHERE settings ? 'storage';

\echo '--- 3.5 super_admins'
SELECT coalesce(a.email,r.email) email, a.email IS NOT NULL in_aws, r.email IS NOT NULL in_r2, md5(a.password)=md5(r.password) same_pw
FROM aws_src.super_admins a FULL JOIN public.super_admins r ON lower(r.email)=lower(a.email);

\echo '--- 3.6 AWS-created domains (id>24): already in R2?'
SELECT a.name, ao.name org, r.id r2_id, ro.name r2_org,
       md5(a.dkim_public_key)=md5(r.dkim_public_key) same_dkim, a.dkim_selector aws_sel, r.dkim_selector r2_sel
FROM aws_src.domains a JOIN aws_src.organizations ao ON ao.id=a.org_id
LEFT JOIN public.domains r ON lower(r.name)=lower(a.name) LEFT JOIN public.organizations ro ON ro.id=r.org_id
WHERE a.id>24 ORDER BY a.id;

\echo '--- 3.7 AWS-created users (id>28): already in R2?'
SELECT a.email, r.id r2_id, md5(a.password)=md5(r.password) same_pw, a.role aws_role, r.role r2_role,
       (SELECT count(*) FROM public.messages m JOIN public.mailboxes mb ON mb.id=m.mailbox_id WHERE mb.user_id=r.id) r2_msgs
FROM aws_src.users a LEFT JOIN public.users r ON lower(r.email)=lower(a.email) WHERE a.id>28 ORDER BY a.id;

\echo '--- 3.8 August users whose password differs in R2 (changed on Azure; R2 value wins)'
SELECT a.email, a.password_changed_at aws_changed, r.password_changed_at r2_changed
FROM aws_src.users a JOIN public.users r ON lower(r.email)=lower(a.email)
WHERE a.id<=28 AND md5(a.password)<>md5(r.password) ORDER BY 1;

\echo '--- 3.9 domains / users only on one side (August rows missing in R2 = deleted on Azure?)'
SELECT 'domain' kind, a.name, 'aws only (aug)' side FROM aws_src.domains a WHERE a.id<=24 AND NOT EXISTS (SELECT 1 FROM public.domains r WHERE lower(r.name)=lower(a.name))
UNION ALL SELECT 'user', a.email, 'aws only (aug)' FROM aws_src.users a WHERE a.id<=28 AND NOT EXISTS (SELECT 1 FROM public.users r WHERE lower(r.email)=lower(a.email))
UNION ALL SELECT 'domain', r.name, 'r2 only' FROM public.domains r WHERE NOT EXISTS (SELECT 1 FROM aws_src.domains a WHERE lower(a.name)=lower(r.name))
UNION ALL SELECT 'user', r.email, 'r2 only' FROM public.users r WHERE NOT EXISTS (SELECT 1 FROM aws_src.users a WHERE lower(a.email)=lower(r.email))
ORDER BY 1,3,2;

\echo '--- 3.10 the August messages changed on AWS: present in R2 (by public_id)?'
SELECT a.id aws_id, r.id r2_id, a.is_read aws_read, r.is_read r2_read, a.updated_at aws_upd, r.updated_at r2_upd
FROM aws_src.messages a LEFT JOIN public.messages r ON r.public_id=a.public_id
WHERE a.id<=1420 AND a.updated_at>'2026-11-18 09:27+00' ORDER BY 1;

\echo '--- 3.11 duplicate guard: AWS-delta raw_emails whose Message-ID already exists in R2'
SELECT a.id, left(a.message_id,60) message_id, r.id r2_id
FROM aws_src.raw_emails a JOIN public.raw_emails r ON r.message_id=a.message_id AND r.to_addresses=a.to_addresses
WHERE a.id>3634 ORDER BY 1;

\echo '--- 3.12 public_id collisions between AWS delta and R2 (expected none)'
SELECT 'messages' t, count(*) FROM aws_src.messages a JOIN public.messages r USING (public_id) WHERE a.id>1420
UNION ALL SELECT 'attachments', count(*) FROM aws_src.attachments a JOIN public.attachments r USING (public_id) WHERE a.id>137
UNION ALL SELECT 'folders', count(*) FROM aws_src.folders a JOIN public.folders r USING (public_id) WHERE a.id>145
UNION ALL SELECT 'mailboxes', count(*) FROM aws_src.mailboxes a JOIN public.mailboxes r USING (public_id) WHERE a.id>28
UNION ALL SELECT 'users', count(*) FROM aws_src.users a JOIN public.users r USING (public_id) WHERE a.id>28
UNION ALL SELECT 'domains', count(*) FROM aws_src.domains a JOIN public.domains r USING (public_id) WHERE a.id>24;
SQL

echo "=== [4/4] DKIM: DNS (${DNS_SERVER} and 1.1.1.1) vs dkim_public_key in AWS and R2 ==="
command -v dig >/dev/null || sudo apt-get install -y -qq bind9-dnsutils >/dev/null
S -At -F $'\t' -c "
  SELECT coalesce(r.name,a.name), coalesce(a.dkim_selector,''), coalesce(r.dkim_selector,''),
         coalesce(regexp_replace(a.dkim_public_key,'-----[^-]+-----|\s','','g'),''),
         coalesce(regexp_replace(r.dkim_public_key,'-----[^-]+-----|\s','','g'),'')
  FROM public.domains r FULL JOIN aws_src.domains a ON lower(a.name)=lower(r.name) ORDER BY 1" |
while IFS=$'\t' read -r dom asel rsel akey rkey; do
  res=""
  for ns in "$DNS_SERVER" 1.1.1.1; do
    for sel in $(printf '%s\n%s\n' "$asel" "$rsel" | sort -u | sed '/^$/d'); do
      p=$(dig +short +time=2 +tries=1 TXT "${sel}._domainkey.${dom}" @"$ns" 2>/dev/null | tr -d '" \n' | sed -nE 's/.*p=([^;]*).*/\1/p')
      if [ -z "$p" ]; then m="none"
      elif [ -n "$akey" ] && [ "$p" = "$akey" ] && [ "$p" = "$rkey" ]; then m="both"
      elif [ -n "$akey" ] && [ "$p" = "$akey" ]; then m="AWS"
      elif [ -n "$rkey" ] && [ "$p" = "$rkey" ]; then m="R2"
      else m="neither"; fi
      res="$res ${ns%%.*}:${sel}=$m"
    done
  done
  same="n/a"; [ -n "$akey" ] && [ -n "$rkey" ] && { [ "$akey" = "$rkey" ] && same=same || same=DIFF; }
  printf '  %-28s aws=%-3s r2=%-3s keys:%-5s dns:%s\n' "$dom" "$([ -n "$akey" ] && echo y || echo -)" "$([ -n "$rkey" ] && echo y || echo -)" "$same" "$res"
done
echo "COMPARE_DONE"
