-- Task 1.6 / 2.3 (docs/mail-vm-db-upgrade-r2.md): merge the AWS-period delta (schema aws_src = copy
-- of the live AWS nextdp_mail) into public (= restored R2 snapshot) of the staging DB.
-- psql vars: aug_raw aug_msg aug_att aug_dom aug_user aug_mb aug_folder aug_audit t0 uidv dry_run
-- One transaction; dry_run=true ends with ROLLBACK. New IDs are pre-allocated from the target
-- sequences, natural keys (org name, user email, mailbox address, domain name, folder slug) map
-- existing rows. No secret values are printed.
\set ON_ERROR_STOP on
\pset pager off
BEGIN;

CREATE TEMP TABLE cfg AS SELECT :aug_raw::bigint aug_raw, :aug_msg::bigint aug_msg, :aug_att::bigint aug_att,
  :aug_dom::bigint aug_dom, :aug_user::bigint aug_user, :aug_mb::bigint aug_mb, :aug_folder::bigint aug_folder,
  :aug_audit::bigint aug_audit, :'t0'::timestamptz t0;

CREATE TEMP TABLE pre_counts AS
  SELECT 'raw_emails' t, count(*) n FROM public.raw_emails UNION ALL SELECT 'messages', count(*) FROM public.messages
  UNION ALL SELECT 'attachments', count(*) FROM public.attachments UNION ALL SELECT 'domains', count(*) FROM public.domains
  UNION ALL SELECT 'users', count(*) FROM public.users UNION ALL SELECT 'mailboxes', count(*) FROM public.mailboxes
  UNION ALL SELECT 'folders', count(*) FROM public.folders UNION ALL SELECT 'audit_logs', count(*) FROM public.audit_logs;

-- Guard: AWS-delta raw emails that already exist in R2 must be handled by hand.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM aws_src.raw_emails a JOIN public.raw_emails r ON r.message_id=a.message_id AND r.to_addresses=a.to_addresses
             WHERE a.id > (SELECT aug_raw FROM cfg) AND coalesce(a.message_id,'') <> '') THEN
    RAISE EXCEPTION 'AWS delta contains raw_emails already present in R2 (duplicate Message-ID)';
  END IF;
END $$;

-- 1. organizations (map only)
CREATE TEMP TABLE map_org AS SELECT a.id aws_id, r.id new_id FROM aws_src.organizations a JOIN public.organizations r ON r.name=a.name;
DO $$ BEGIN
  IF (SELECT count(*) FROM aws_src.organizations) <> (SELECT count(*) FROM map_org) THEN RAISE EXCEPTION 'unmapped organization'; END IF;
END $$;

-- 2. users
CREATE TEMP TABLE map_user (aws_id bigint PRIMARY KEY, new_id bigint NOT NULL, is_new boolean NOT NULL);
INSERT INTO map_user SELECT a.id, r.id, false FROM aws_src.users a JOIN public.users r ON lower(r.email)=lower(a.email);
INSERT INTO map_user SELECT a.id, nextval('public.users_id_seq'), true FROM aws_src.users a
  WHERE a.id > :aug_user AND NOT EXISTS (SELECT 1 FROM map_user m WHERE m.aws_id=a.id);
INSERT INTO public.users (id, org_id, name, email, password, role, is_active, last_login_at, last_login_ip, password_changed_at,
                          invited_by, invited_at, created_at, updated_at, deleted_at, totp_secret, totp_enabled, totp_verified_at, backup_codes, public_id)
SELECT m.new_id, mo.new_id, a.name, a.email, a.password, a.role, a.is_active, a.last_login_at, a.last_login_ip, a.password_changed_at,
       mi.new_id, a.invited_at, a.created_at, a.updated_at, a.deleted_at, a.totp_secret, a.totp_enabled, a.totp_verified_at, a.backup_codes, a.public_id
FROM aws_src.users a JOIN map_user m ON m.aws_id=a.id AND m.is_new JOIN map_org mo ON mo.aws_id=a.org_id
LEFT JOIN map_user mi ON mi.aws_id=a.invited_by;
-- D3: users created on AWS that also exist in R2 keep the AWS password (the one in use now).
UPDATE public.users r SET password=a.password, password_changed_at=a.password_changed_at
FROM aws_src.users a JOIN map_user m ON m.aws_id=a.id AND NOT m.is_new
WHERE r.id=m.new_id AND a.id > :aug_user AND r.password IS DISTINCT FROM a.password;
-- Latest login info wins.
UPDATE public.users r SET last_login_at=a.last_login_at, last_login_ip=a.last_login_ip
FROM aws_src.users a JOIN map_user m ON m.aws_id=a.id AND NOT m.is_new
WHERE r.id=m.new_id AND a.last_login_at IS NOT NULL AND (r.last_login_at IS NULL OR a.last_login_at > r.last_login_at);

-- 3. mailboxes
CREATE TEMP TABLE map_mb (aws_id bigint PRIMARY KEY, new_id bigint NOT NULL, is_new boolean NOT NULL);
INSERT INTO map_mb SELECT a.id, r.id, false FROM aws_src.mailboxes a JOIN public.mailboxes r ON lower(r.email_address)=lower(a.email_address);
INSERT INTO map_mb SELECT a.id, nextval('public.mailboxes_id_seq'), true FROM aws_src.mailboxes a
  WHERE a.id > :aug_mb AND NOT EXISTS (SELECT 1 FROM map_mb m WHERE m.aws_id=a.id);
INSERT INTO public.mailboxes (id, user_id, org_id, email_address, total_messages, unread_messages, storage_used_bytes, is_active, created_at, updated_at, public_id)
SELECT m.new_id, mu.new_id, mo.new_id, a.email_address, 0, 0, 0, a.is_active, a.created_at, a.updated_at, a.public_id
FROM aws_src.mailboxes a JOIN map_mb m ON m.aws_id=a.id AND m.is_new
JOIN map_user mu ON mu.aws_id=a.user_id JOIN map_org mo ON mo.aws_id=a.org_id;

-- 4. domains
CREATE TEMP TABLE map_dom (aws_id bigint PRIMARY KEY, new_id bigint NOT NULL, is_new boolean NOT NULL);
INSERT INTO map_dom SELECT a.id, r.id, false FROM aws_src.domains a JOIN public.domains r ON lower(r.name)=lower(a.name);
INSERT INTO map_dom SELECT a.id, nextval('public.domains_id_seq'), true FROM aws_src.domains a
  WHERE a.id > :aug_dom AND NOT EXISTS (SELECT 1 FROM map_dom m WHERE m.aws_id=a.id);
INSERT INTO public.domains (id, org_id, name, is_active, is_verified, is_primary, mx_verified_at, spf_record, dkim_selector, dkim_private_key,
                            dkim_public_key, dmarc_policy, catch_all, max_mailboxes, created_at, updated_at, public_id, catch_all_mailbox_id)
SELECT m.new_id, mo.new_id, a.name, a.is_active, a.is_verified, a.is_primary, a.mx_verified_at, a.spf_record, a.dkim_selector, a.dkim_private_key,
       a.dkim_public_key, a.dmarc_policy, a.catch_all, a.max_mailboxes, a.created_at, a.updated_at, a.public_id, mc.new_id
FROM aws_src.domains a JOIN map_dom m ON m.aws_id=a.id AND m.is_new JOIN map_org mo ON mo.aws_id=a.org_id
LEFT JOIN map_mb mc ON mc.aws_id=a.catch_all_mailbox_id;

-- 5. folders
CREATE TEMP TABLE map_folder (aws_id bigint PRIMARY KEY, new_id bigint NOT NULL, is_new boolean NOT NULL);
INSERT INTO map_folder SELECT a.id, r.id, false FROM aws_src.folders a JOIN map_mb mm ON mm.aws_id=a.mailbox_id
  JOIN public.folders r ON r.mailbox_id=mm.new_id AND r.slug=a.slug;
INSERT INTO map_folder SELECT a.id, nextval('public.folders_id_seq'), true FROM aws_src.folders a
  WHERE a.id > :aug_folder AND NOT EXISTS (SELECT 1 FROM map_folder m WHERE m.aws_id=a.id);
INSERT INTO public.folders (id, mailbox_id, parent_id, name, slug, type, system_role, total_messages, unread_messages, position,
                            created_at, updated_at, uid_validity, uid_next, public_id)
SELECT m.new_id, mm.new_id, mp.new_id, a.name, a.slug, a.type, a.system_role, 0, 0, a.position, a.created_at, a.updated_at, a.uid_validity, 1, a.public_id
FROM aws_src.folders a JOIN map_folder m ON m.aws_id=a.id AND m.is_new JOIN map_mb mm ON mm.aws_id=a.mailbox_id
LEFT JOIN map_folder mp ON mp.aws_id=a.parent_id;

-- 6. raw_emails (eml_path unchanged: UUID file names never collide)
CREATE TEMP TABLE map_raw AS SELECT a.id aws_id, nextval('public.raw_emails_id_seq') new_id FROM aws_src.raw_emails a WHERE a.id > :aug_raw;
INSERT INTO public.raw_emails (id, message_id, from_address, to_addresses, subject, from_header, to_header, cc_header, reply_to, in_reply_to,
  references_hdr, date, text_body, html_body, raw_headers, attachment_count, size_bytes, eml_path, domain_id, org_id, status, remote_addr,
  tls_version, spf_result, spf_domain, dkim_result, dkim_domain, dmarc_result, dmarc_policy, is_spam, created_at, bimi_status, bimi_selector,
  bim_idomain, bimi_logo_path, bimi_authority, bimi_verified, bimi_domain)
SELECT m.new_id, a.message_id, a.from_address, a.to_addresses, a.subject, a.from_header, a.to_header, a.cc_header, a.reply_to, a.in_reply_to,
  a.references_hdr, a.date, a.text_body, a.html_body, a.raw_headers, a.attachment_count, a.size_bytes, a.eml_path, md.new_id, mo.new_id, a.status,
  a.remote_addr, a.tls_version, a.spf_result, a.spf_domain, a.dkim_result, a.dkim_domain, a.dmarc_result, a.dmarc_policy, a.is_spam, a.created_at,
  a.bimi_status, a.bimi_selector, a.bim_idomain, a.bimi_logo_path, a.bimi_authority, a.bimi_verified, a.bimi_domain
FROM aws_src.raw_emails a JOIN map_raw m ON m.aws_id=a.id
LEFT JOIN map_dom md ON md.aws_id=a.domain_id LEFT JOIN map_org mo ON mo.aws_id=a.org_id;

-- 7. attachments (path contains the raw email id -> rewritten; file moves done by the cutover script)
CREATE TEMP TABLE map_att AS
SELECT a.id aws_id, nextval('public.attachments_id_seq') new_id, mr.new_id new_raw, mo.new_id new_org, a.storage_path old_path,
       regexp_replace(a.storage_path, '^attachments/[0-9]+/[0-9]+/', 'attachments/' || coalesce(mo.new_id, a.org_id) || '/' || mr.new_id || '/') new_path
FROM aws_src.attachments a JOIN map_raw mr ON mr.aws_id=a.raw_email_id LEFT JOIN map_org mo ON mo.aws_id=a.org_id
WHERE a.id > :aug_att;
INSERT INTO public.attachments (id, raw_email_id, org_id, filename, content_type, size_bytes, storage_path, checksum, content_id, is_inline, created_at, public_id)
SELECT m.new_id, m.new_raw, coalesce(m.new_org, a.org_id), a.filename, a.content_type, a.size_bytes, m.new_path, a.checksum, a.content_id, a.is_inline, a.created_at, a.public_id
FROM aws_src.attachments a JOIN map_att m ON m.aws_id=a.id;

-- 8. messages (new IMAP UIDs continue after the target folder's highest UID)
CREATE TEMP TABLE map_msg AS
SELECT a.id aws_id, nextval('public.messages_id_seq') new_id, mf.new_id new_folder, a.received_at, NULL::bigint imap_uid
FROM aws_src.messages a JOIN map_folder mf ON mf.aws_id=a.folder_id WHERE a.id > :aug_msg;
UPDATE map_msg x SET imap_uid = s.uid FROM (
  SELECT mm.aws_id, fb.uid_base + row_number() OVER (PARTITION BY mm.new_folder ORDER BY mm.received_at, mm.aws_id) - 1 AS uid
  FROM map_msg mm JOIN (
    SELECT f.id, greatest(f.uid_next, coalesce((SELECT max(m.imap_uid) + 1 FROM public.messages m WHERE m.folder_id=f.id), 1)) uid_base
    FROM public.folders f) fb ON fb.id=mm.new_folder) s
WHERE s.aws_id=x.aws_id;
INSERT INTO public.messages (id, mailbox_id, folder_id, raw_email_id, org_id, thread_id, message_id, from_address, to_addresses, subject, snippet,
  is_read, is_starred, is_draft, has_attachments, size_bytes, received_at, created_at, updated_at, imap_uid, is_deleted, is_answered, public_id, body_text)
SELECT m.new_id, mb.new_id, m.new_folder, mr.new_id, mo.new_id, a.thread_id, a.message_id, a.from_address, a.to_addresses, a.subject, a.snippet,
  a.is_read, a.is_starred, a.is_draft, a.has_attachments, a.size_bytes, a.received_at, a.created_at, a.updated_at, m.imap_uid, a.is_deleted,
  a.is_answered, a.public_id, a.body_text
FROM aws_src.messages a JOIN map_msg m ON m.aws_id=a.id JOIN map_mb mb ON mb.aws_id=a.mailbox_id JOIN map_org mo ON mo.aws_id=a.org_id
LEFT JOIN map_raw mr ON mr.aws_id=a.raw_email_id;

-- 9. August messages changed on AWS (read/star/answer/delete flags), newer change wins
CREATE TEMP TABLE changed_old AS
SELECT r.id, a.is_read, a.is_starred, a.is_answered, a.is_deleted, a.updated_at, fa.slug aws_slug, fr.slug r2_slug
FROM aws_src.messages a JOIN public.messages r ON r.public_id=a.public_id
JOIN aws_src.folders fa ON fa.id=a.folder_id JOIN public.folders fr ON fr.id=r.folder_id
WHERE a.id <= :aug_msg AND a.updated_at > :'t0' AND a.updated_at > r.updated_at;
UPDATE public.messages r SET is_read=c.is_read, is_starred=c.is_starred, is_answered=c.is_answered, is_deleted=c.is_deleted, updated_at=c.updated_at
FROM changed_old c WHERE r.id=c.id;

-- 10. audit_logs
CREATE TEMP TABLE map_audit AS SELECT a.id aws_id, nextval('public.audit_logs_id_seq') new_id FROM aws_src.audit_logs a WHERE a.id > :aug_audit;
INSERT INTO public.audit_logs (id, actor_id, actor_email, action, target_type, target_id, target_label, ip_address, details, created_at, actor_type)
SELECT m.new_id,
       CASE WHEN a.actor_type='user' THEN coalesce(ua.new_id, a.actor_id) ELSE a.actor_id END,
       a.actor_email, a.action, a.target_type,
       CASE WHEN a.target_type='user' THEN coalesce(ut.new_id, a.target_id) ELSE a.target_id END,
       a.target_label, a.ip_address, a.details, a.created_at, a.actor_type
FROM aws_src.audit_logs a JOIN map_audit m ON m.aws_id=a.id
LEFT JOIN map_user ua ON ua.aws_id=a.actor_id LEFT JOIN map_user ut ON ut.aws_id=a.target_id;

-- 11. counters, IMAP UID state, UIDVALIDITY bump (all folders: forces clean client resync)
CREATE TEMP TABLE touched_mb AS
  SELECT DISTINCT mailbox_id id FROM public.messages WHERE id IN (SELECT new_id FROM map_msg) OR id IN (SELECT id FROM changed_old)
  UNION SELECT new_id FROM map_mb WHERE is_new;
UPDATE public.folders f SET
  total_messages  = (SELECT count(*) FROM public.messages m WHERE m.folder_id=f.id),
  unread_messages = (SELECT count(*) FROM public.messages m WHERE m.folder_id=f.id AND NOT m.is_read)
WHERE f.mailbox_id IN (SELECT id FROM touched_mb);
UPDATE public.mailboxes mb SET
  total_messages  = (SELECT count(*) FROM public.messages m WHERE m.mailbox_id=mb.id),
  unread_messages = (SELECT count(*) FROM public.messages m WHERE m.mailbox_id=mb.id AND NOT m.is_read),
  storage_used_bytes = mb.storage_used_bytes + coalesce((SELECT sum(m.size_bytes) FROM public.messages m
                         WHERE m.mailbox_id=mb.id AND m.id IN (SELECT new_id FROM map_msg)), 0)
WHERE mb.id IN (SELECT id FROM touched_mb);
UPDATE public.folders f SET uid_next = greatest(f.uid_next, coalesce((SELECT max(m.imap_uid) + 1 FROM public.messages m WHERE m.folder_id=f.id), 1));
UPDATE public.folders SET uid_validity = :uidv;

-- 12. sequences never behind max(id)
DO $$ DECLARE r record; mx bigint; BEGIN
  FOR r IN SELECT s.relname seq, t.relname tbl, a.attname col
           FROM pg_class s JOIN pg_depend d ON d.objid=s.oid AND d.deptype='a'
           JOIN pg_class t ON t.oid=d.refobjid JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=d.refobjsubid
           JOIN pg_namespace n ON n.oid=t.relnamespace
           WHERE s.relkind='S' AND n.nspname='public' LOOP
    EXECUTE format('SELECT max(%I) FROM public.%I', r.col, r.tbl) INTO mx;
    IF mx IS NOT NULL THEN
      PERFORM setval(format('public.%I', r.seq)::regclass,
        greatest(mx, coalesce((SELECT last_value FROM pg_sequences WHERE schemaname='public' AND sequencename=r.seq), 1)));
    END IF;
  END LOOP;
END $$;

-- 13. integrity checks (abort the whole merge on any failure)
DO $$ DECLARE c cfg%ROWTYPE; bad text := ''; BEGIN
  SELECT * INTO c FROM cfg;
  IF (SELECT count(*) FROM map_raw) <> (SELECT count(*) FROM aws_src.raw_emails WHERE id > c.aug_raw) THEN bad := bad || ' raw_emails'; END IF;
  IF (SELECT count(*) FROM map_msg) <> (SELECT count(*) FROM aws_src.messages WHERE id > c.aug_msg) THEN bad := bad || ' messages(unmapped folder)'; END IF;
  IF (SELECT count(*) FROM map_att) <> (SELECT count(*) FROM aws_src.attachments WHERE id > c.aug_att) THEN bad := bad || ' attachments(unmapped raw)'; END IF;
  IF EXISTS (SELECT 1 FROM map_att WHERE old_path !~ '^attachments/[0-9]+/[0-9]+/' OR new_path = old_path) THEN bad := bad || ' attachment_path'; END IF;
  IF EXISTS (SELECT 1 FROM map_user m WHERE m.is_new AND NOT EXISTS (SELECT 1 FROM public.users r WHERE r.id=m.new_id)) THEN bad := bad || ' users'; END IF;
  IF EXISTS (SELECT 1 FROM map_mb m WHERE m.is_new AND NOT EXISTS (SELECT 1 FROM public.mailboxes r WHERE r.id=m.new_id)) THEN bad := bad || ' mailboxes'; END IF;
  IF EXISTS (SELECT 1 FROM map_dom m WHERE m.is_new AND NOT EXISTS (SELECT 1 FROM public.domains r WHERE r.id=m.new_id)) THEN bad := bad || ' domains'; END IF;
  IF EXISTS (SELECT 1 FROM map_folder m WHERE m.is_new AND NOT EXISTS (SELECT 1 FROM public.folders r WHERE r.id=m.new_id)) THEN bad := bad || ' folders'; END IF;
  IF (SELECT count(*) FROM public.messages WHERE id IN (SELECT new_id FROM map_msg)) <> (SELECT count(*) FROM map_msg) THEN bad := bad || ' messages(insert)'; END IF;
  IF EXISTS (SELECT 1 FROM aws_src.messages a WHERE a.id > c.aug_msg AND a.raw_email_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM map_raw r WHERE r.aws_id=a.raw_email_id)) THEN bad := bad || ' messages(raw ref to August raw)'; END IF;
  IF EXISTS (SELECT 1 FROM aws_src.raw_emails a WHERE a.id > c.aug_raw AND a.domain_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM map_dom d WHERE d.aws_id=a.domain_id)) THEN bad := bad || ' raw_emails(domain)'; END IF;
  IF EXISTS (SELECT 1 FROM aws_src.domains a JOIN map_dom m ON m.aws_id=a.id AND m.is_new WHERE a.catch_all_mailbox_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM map_mb x WHERE x.aws_id=a.catch_all_mailbox_id)) THEN bad := bad || ' domains(catch_all)'; END IF;
  IF EXISTS (SELECT 1 FROM public.folders f WHERE f.uid_next <= coalesce((SELECT max(imap_uid) FROM public.messages m WHERE m.folder_id=f.id), 0)) THEN bad := bad || ' uid_next'; END IF;
  IF bad <> '' THEN RAISE EXCEPTION 'merge integrity check failed:%', bad; END IF;
END $$;

-- 14. report
\echo '--- id mapping summary'
SELECT 'users' t, count(*) FILTER (WHERE is_new) inserted, count(*) FILTER (WHERE NOT is_new) matched FROM map_user
UNION ALL SELECT 'mailboxes', count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new) FROM map_mb
UNION ALL SELECT 'domains', count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new) FROM map_dom
UNION ALL SELECT 'folders', count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new) FROM map_folder
UNION ALL SELECT 'raw_emails', count(*), 0 FROM map_raw
UNION ALL SELECT 'attachments', count(*), 0 FROM map_att
UNION ALL SELECT 'messages', count(*), 0 FROM map_msg
UNION ALL SELECT 'audit_logs', count(*), 0 FROM map_audit
UNION ALL SELECT 'old msgs updated', count(*), count(*) FILTER (WHERE aws_slug <> r2_slug) FROM changed_old;
\echo '--- users / domains created on AWS (new id in merged DB)'
SELECT 'user' kind, a.email name, m.new_id, m.is_new FROM aws_src.users a JOIN map_user m ON m.aws_id=a.id WHERE a.id > :aug_user
UNION ALL SELECT 'domain', a.name, m.new_id, m.is_new FROM aws_src.domains a JOIN map_dom m ON m.aws_id=a.id WHERE a.id > :aug_dom ORDER BY 1,2;
\echo '--- delta messages per mailbox (merged DB)'
SELECT mb.email_address, count(*) new_msgs, min(m.imap_uid) uid_from, max(m.imap_uid) uid_to
FROM public.messages m JOIN public.mailboxes mb ON mb.id=m.mailbox_id WHERE m.id IN (SELECT new_id FROM map_msg) GROUP BY 1 ORDER BY 1;
\echo '--- August messages deleted on AWS (not applied; R2 keeps them)'
SELECT count(*) FROM public.messages r WHERE r.id <= :aug_msg AND NOT EXISTS (SELECT 1 FROM aws_src.messages a WHERE a.public_id=r.public_id)
  AND r.created_at < :'t0' AND r.id IN (SELECT id FROM public.messages WHERE id <= :aug_msg);
\echo '--- row counts: R2 before -> after merge'
SELECT p.t, p.n r2_before, x.n after, x.n - p.n added FROM pre_counts p JOIN (
  SELECT 'raw_emails' t, count(*) n FROM public.raw_emails UNION ALL SELECT 'messages', count(*) FROM public.messages
  UNION ALL SELECT 'attachments', count(*) FROM public.attachments UNION ALL SELECT 'domains', count(*) FROM public.domains
  UNION ALL SELECT 'users', count(*) FROM public.users UNION ALL SELECT 'mailboxes', count(*) FROM public.mailboxes
  UNION ALL SELECT 'folders', count(*) FROM public.folders UNION ALL SELECT 'audit_logs', count(*) FROM public.audit_logs) x USING (t) ORDER BY 1;

\copy (SELECT 'user' t, aws_id, new_id, is_new FROM map_user UNION ALL SELECT 'mailbox', aws_id, new_id, is_new FROM map_mb UNION ALL SELECT 'domain', aws_id, new_id, is_new FROM map_dom UNION ALL SELECT 'folder', aws_id, new_id, is_new FROM map_folder UNION ALL SELECT 'raw_email', aws_id, new_id, true FROM map_raw UNION ALL SELECT 'attachment', aws_id, new_id, true FROM map_att UNION ALL SELECT 'message', aws_id, new_id, true FROM map_msg UNION ALL SELECT 'audit_log', aws_id, new_id, true FROM map_audit ORDER BY 1,2) TO '/tmp/.merge-idmap.csv' CSV HEADER
\copy (SELECT old_path, new_path FROM map_att ORDER BY aws_id) TO '/tmp/.merge-attmap.csv' CSV

\if :dry_run
ROLLBACK;
\echo 'MERGE_RESULT=DRY_RUN_ROLLED_BACK'
\else
COMMIT;
\echo 'MERGE_RESULT=COMMITTED'
\endif
