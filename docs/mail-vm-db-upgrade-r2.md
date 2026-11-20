# Mail VM: move `nextdp_mail` to the R2 backup and carry over the AWS-period data

Work plan for the AWS Lightsail **Mail VM** (`52.66.111.138`). Today NextDP Mail runs on the old 26 Aug 2026 backup. The goal is to switch it to the newest R2 backup (18 Nov 2026) and copy in everything the Mail VM received since it went live on 18 Nov.

- **Created:** 2026-11-20 01:07 IST. Live numbers in section 2 were measured at that time (read-only queries).
- **No secrets in this file.** Secrets stay in `private-data/` (gitignored) and on the VM in `/opt/nextdp/config/.env`.
- Related docs: [`session-handover-2026-11-19.md`](session-handover-2026-11-19.md), [`mail-vm-runbook.md`](mail-vm-runbook.md), `E:\Google_Drive\Dev\RAiWorks\MY-PC\Azure-Account-Suspension-Recovery.md`.

## Status (2026-11-20 10:15 IST)

**Cutover DONE on 2026-11-20 at 04:38:19–04:38:52 UTC (10:08 IST, 33 s of mail downtime).** NextDP Mail now runs on the R2 snapshot plus the AWS delta. The old August DB is kept as `nextdp_mail_aug_old`.

| Check after cutover | Result |
|---|---|
| Counts | orgs 3, domains 39, users 43, mailboxes 43, messages 6,470, raw_emails 8,712, attachments 394 (as planned) |
| Health / units | `/api/health/ready` healthy (DB + Redis up), `nextdp*`, caddy, redis, postgresql, coredns, dithim-web all active. Ports 25/465/587/143/993/110/995 listening |
| Web | `mail.`, `admin.mail.`, `super-admin.mail.nextdp.com` return 200 |
| Inbound delivery | Test mail to `rajesh@nextdp.com` via SMTP :25 delivered: message 6537, inbox UID 223 (continues after 222), `.eml` written. Port 25 on the public IP can't be reached from the VM itself because AWS blocks outbound 25; delivery from the internet is unaffected |
| Files | 5,319 Azure upload files + 30 BIMI files added, 9 AWS attachments moved to their new ids. 2 `.eml` files are unrecoverable (org 2, Sep 2026) |
| Secrets | `JWT_SECRET` and `SESSION_SECRET` rotated (everyone logged out once). `MIGRATION_ENCRYPTION_KEY` unchanged |
| IMAP | `uid_validity` = 1795149517 on all folders, so clients resync |
| Backups | `/var/backups/nextdp/cutover-20261120T043819Z/` (final August dump, storage tar, id-map, attachment map, root-only `.env`) + `D:\nmc-backup\mail-vm\cutover-20261120T043819Z\` |

**Still open:** 3.2/3.4/3.5 owner checks (log in to webmail and admin as a real user, phone/desktop IMAP resync, outbound reply via ZeptoMail). 3.6: log watch (clean so far; only normal IMAP client disconnects). 4.3: drop `nextdp_mail_aug_old` after 2026-11-27. 5.2: `cconsole_hub` → R2 snapshot (separate task).

**Phase 5.1 DONE (2026-11-20):** nightly off-site backup to R2 `nxtmngr-test/aws-mail-vm`, weekly verify + restore test, failure mail to rajesh@nextdp.com. See [`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md). **Owner:** upload `private-data/mail-vm-offsite-backup.env` to the AW Vault.

Rollback (section 6) is still possible until `nextdp_mail_aug_old` is dropped. The file moves to reverse are listed in `cutover-20261120T043819Z/attachments-moved.tsv`.

### Before cutover (kept for reference)

| Task | Result |
|---|---|
| 0.1 Live backup (`10-backup-live-mail`) | `/var/backups/nextdp/20261120T035236Z/` + `D:\nmc-backup\mail-vm\20261120T035236Z\` (SHA-256 verified, `pg_restore --list` OK) |
| 0.2 Azure `nmc-mail-1-osdisk` (`15-fetch-azure-mail1-storage`) | 30 GB VHD downloaded in 5.5 min on the Mail VM, mounted read-only. Storage tree: 9,097 files / 8,647 `.eml`, Apr–Nov 2026. Saved as `/var/backups/nextdp/azure-mail1-storage.tar.gz` (100.7 MB) + `D:\nmc-backup\mail-vm\azure-mail1\`. Azure config saved root-only as `azure-mail1-config.tar.gz` (VM only). VHD deleted, export link revoked. `MIGRATION_ENCRYPTION_KEY` is identical on Azure and AWS |
| 0.3 db-1 disk | Skipped (owner) |
| 1.2 R2 staged (`11-stage-r2-mail-db`) | Snapshot `689c5e6a` → `nextdp_mail_r2`, `pg_restore` rc=0. R2 dump kept at `/var/backups/nextdp/r2-689c5e6a/` + `D:\nmc-backup\mail-vm\r2-689c5e6a\` |
| 1.4/1.5 Compare (`12-compare-mail-dbs`) | Schema identical. Orgs/settings/system_settings/super admin identical. Findings below |
| 1.6 Merge dry run (`13-merge-aws-delta`) | All delta rows mapped. Integrity checks pass |
| Cutover rehearsal (`14-cutover-mail-db`, no `-Cutover`) | OK. **9,070 of 9,072** files referenced by the merged DB exist. The 2 missing files are `.eml` files for org 2, Sep 2026; they are missing on the Azure disk too |

**Compare findings (the decisions follow the section 3 recommendations):**
- R2 vs August: R2 has 12 more domains and 12 more users created on Azure (daiskills.com, dithim.com, esangh.com, forbharat.in, localcen.com, ogcen.com, padmashali.org, softskills.training, startupthing.in, supportfor.in, truepf.in, yourdpm.com). 3 presencive.com users changed their passwords on Azure (R2 value kept).
- `nextidp.com` + `rajesh@nextidp.com` already exist in R2 (R2 mailbox has 11 messages). They are matched, not duplicated. **D3:** the AWS password is copied over the R2 one.
- `mrajesh.com`, `rajeshyukta.in` and their 2 users are new in R2 (new ids 38/39 and 43/42).
- **D4:** no domain has DKIM keys in either DB (outbound goes through ZeptoMail). Nothing to choose.
- **D5:** transport settings are identical. R2 has no `storage` config.
- No duplicate Message-IDs and no `public_id` collisions.
- Expected merge result: messages 6,437 → 6,470 (+33), raw_emails 8,679 → 8,712, attachments 385 → 394, domains 39, users/mailboxes 43. Of the 6 August messages marked read on AWS, 3 are unread in R2; the AWS read state wins.

**Cutover command** (run 2026-11-20; about 1–3 min of mail downtime; everyone is logged out once):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\mail-vm\14-cutover-mail-db.ps1 -Cutover
```
It stops `nextdp*`, takes a final dump and storage tar, re-stages R2 and commits the merge, moves the 9 AWS attachments to their new ids, adds the Azure files (`rsync --ignore-existing`), renames the DBs (`nextdp_mail` → `nextdp_mail_aug_old`, `nextdp_mail_r2` → `nextdp_mail`), runs `nextdp migrate`, rotates `JWT_SECRET`/`SESSION_SECRET`, flushes Redis (only if no other client is connected), starts the units and checks health and mail ports. **Any failure after the stop rolls back automatically** (DB rename back, file moves reversed, `.env` restored, services started).

---

## 1. Recommended approach

Restore the R2 dump **side by side** as a second database, merge the small AWS delta into it with SQL (new IDs, mapped by email / domain name / folder slug), then swap the two databases by renaming them. The live service keeps running until the final cutover, which takes about 10 minutes.

| Option | Verdict |
|---|---|
| **A. Side-by-side restore + SQL delta merge + rename swap** | **Recommended.** Keeps original timestamps, flags and auth results. Dry-run possible (transaction + ROLLBACK). Rollback is a rename back. |
| B. Restore R2 over `nextdp_mail`, then re-create 3 domains/users in the admin UI and re-send the 32 `.eml` files over SMTP | Faster to describe, worse result: received times become "now", SPF/DMARC results get recomputed against the local IP, attachments get new rows anyway. Only worth it if option A fails. |
| C. Keep the August DB and import the Aug→Nov data into it | More data to move (about 3 months of mail vs 2 days). No benefit. |

Why rename instead of restore-over: the app's `.env` keeps `DB_NAME=nextdp_mail`, nothing in the app config changes, and the old database stays intact as `nextdp_mail_aug_old` until we drop it.

---

## 2. Facts measured on the Mail VM

### 2.1 Current live database (`16/main`, port 5432, DB `nextdp_mail`, 38 MB)

- Created (restored from the 26 Aug backup) on **2026-11-18 09:27 UTC (14:57 IST)**. Call this **T0**.
- First mail delivered to AWS: 2026-11-18 10:21 UTC (15:51 IST). Last at measurement: 2026-11-19 13:52 UTC.
- Storage driver `local`, files under `/opt/nextdp/storage/uploads/` (`STORAGE_LOCAL_PATH`). No org has its own storage config.
- All services active: `nextdp`, `nextdp-worker`, `nextdp-scheduler`, `redis-server`, `caddy`. Binary built from `nextdp-mail` `a387a5f`.
- Disk: 51 GB free of 58 GB. RAM: 1.9 GB (the `16/nmcmain` cluster on port 5433 also uses some; stop it during the work).

### 2.2 August baseline (highest IDs that came from the 26 Aug backup)

Every row with an ID **above** these values was created on AWS. The merge script selects the delta by these IDs, not by timestamps.

| Table | Aug max ID | Live max ID now | New rows on AWS |
|---|---|---|---|
| `raw_emails` | 3634 | 3666 | 32 |
| `messages` | 1420 | 1452 | 32 |
| `attachments` | 137 | 146 | 9 |
| `domains` | 24 | 27 | 3 |
| `users` | 28 | 31 | 3 |
| `mailboxes` | 28 | 31 | 3 |
| `folders` | 145 | 160 | 15 (5 per new mailbox) |
| `audit_logs` | 91 | 92 | 1 (`user.created`) |
| `organizations`, `system_settings`, `system_email_templates`, `mailbox_aliases`, `migration_*` | – | – | 0 |

Recheck these numbers in task 1.3 just before cutover. More mail will arrive until then.

### 2.3 What was created or changed on AWS since T0

**New domains (org `default`, id 1):** `nextidp.com`, `mrajesh.com`, `rajeshyukta.in`. Their DKIM keys were generated on AWS, and the DNS VM publishes records for them.

**New users / mailboxes (org `default`):** `rajesh@nextidp.com`, `namaste@mrajesh.com`, `namaste@rajeshyukta.in`, each with the 5 system folders (inbox, sent, drafts, trash, spam).

**New mail (all inbound, all `processed`, no sent mail, no drafts):**

| Mailbox | New inbox messages |
|---|---|
| `rajesh@nextdp.com` | 16 |
| `namaste@mrajesh.com` | 9 |
| `admin@cconsole.com` | 2 |
| `namaste@jyoth.com` | 2 |
| `rajesh@nextidp.com` | 2 |
| `namaste@rajeshyukta.in` | 1 |

**Files for the new mail:** 32 `.eml` under `uploads/emails/{1,2}/2026-11/<uuid>.eml` and 9 attachments under `uploads/attachments/1/<raw_email_id>/...` (raw IDs 3637, 3657–3663; 7 of them are Google DMARC report zips).

**Changes to old (August) rows:**
- 6 old inbox messages were marked read (`rajesh@nextdp.com` ×3, `namaste@jyoth.com` ×3).
- Users `rajesh@nextdp.com`, `admin@cconsole.com`, `namaste@jyoth.com`, `namaste@rajesh.in` logged in (only `last_login_*` changed). No password changes on AWS.
- Super admin `admin@rajesh1.com` logged in (`updated_at` changed).

### 2.4 Target: R2 snapshot

| Item | Value |
|---|---|
| Restic repo | `nxtmngr-test/prod-main` on Cloudflare R2 (verified clean, 698/698 snapshots) |
| Snapshot | **`689c5e6a`**, plan `mail-db-nextdp-mail-daily`, node `nmc-db-1` |
| Taken | 2026-11-18 03:00 UTC (**08:30 IST**) |
| Size | 38,654,160 bytes, 204 TOC entries, `pg_restore --list` OK |
| Repo password and R2 keys | Sealed in `backup_targets` (cluster `nmcmain`, port 5433). Unsealed in memory with `JWT_SECRET` from `private-data/nmc-main-env.txt`, same method as `scripts/mail-vm/03b-check-nmc-r2-backups.sh`. **Needs owner approval in chat** (secret access gate). |

### 2.5 What the R2 backup does NOT contain

NMC only backed up **databases** for mail (`kind = db`). There is no file backup of `nmc-mail-1` storage. So:

1. **Aug→Nov mail files** (`.eml` and attachments for mail received on Azure) are only on the Azure disk `nmc-mail-1-osdisk` (30 GB). After the switch, webmail still shows these messages, because subject and body come from the database (`raw_emails.text_body` / `html_body`). These actions will fail until the files are recovered: opening attachments, "download .eml", and full-message fetch over IMAP/POP3.
2. **Mail received on Azure after 08:30 IST on 18 Nov** (until the MX traffic reached AWS, first AWS mail at 15:51 IST) is in neither backup. It exists only in the final state of `nmc-db-1-osdisk` (64 GB), if Azure mail-1 kept accepting mail during that window.

Owner decision (2026-11-20): recover point 1 only (`nmc-mail-1-osdisk`, task 0.2). Point 2 is accepted as lost. The export works only while Azure allows `az disk grant-access` (recovery doc, section 9) and may stop without warning, so task 0.2 is the most time-sensitive task.

---

## 3. Decisions for the owner (answer before Phase 2)

| # | Question | Recommendation |
|---|---|---|
| D1 | Export `nmc-mail-1-osdisk` now to recover the Aug→Nov mail files? | **Approved (2026-11-20).** Downloaded and extracted directly on the Mail VM. No extra VM. |
| D2 | Export `nmc-db-1-osdisk` (64 GB) to close the 08:30–15:51 IST gap? | **No (owner, 2026-11-20).** All DBs come from R2; the gap mail is accepted as lost. |
| D3 | If an AWS-created user (`rajesh@nextidp.com`, `namaste@mrajesh.com`, `namaste@rajeshyukta.in`) also exists in R2, whose password wins? | AWS password (the one in use now). The script reports the overlap first. |
| D4 | If an AWS-created domain also exists in R2, whose DKIM key wins? | Whichever matches the DKIM TXT record the DNS VM publishes now (checked in task 1.5). |
| D5 | Outbound transport (`settings.transport` per org and in `system_settings`): R2 may still point at old relays. | Keep the AWS values (ZeptoMail, working now) if R2 differs. The compare report shows which keys differ (hashes only, no values). |
| D6 | OK to log every webmail/admin user out at cutover (JWT secret rotation)? | **Required**, see section 5 rule 4. |
| D7 | Downtime window for cutover (~10 min, SMTP senders retry automatically). | Pick a quiet hour, e.g. 23:00 IST. |

---

## 4. Task list

Run everything from `E:\workspace\aws-setup-and-migrations` on this PC unless noted. Scripts marked **(new)** still have to be written. They follow the existing pattern: a `.ps1` wrapper that uses `common.ps1` and a `.sh` that runs on the VM, with secrets passed as `0600` temp files deleted on `EXIT`.

### Phase 0: Safety and time-sensitive recovery (no downtime)

- [ ] **0.1 Full backup of the live mail state** (new: `scripts/mail-vm/10-backup-live-mail.{ps1,sh}`)
  - On the VM: `pg_dump -Fc nextdp_mail` and `pg_dump -Fc cconsole_hub` into `/var/backups/nextdp/<ts>/`, plus `tar czf storage-<ts>.tar.gz -C /opt/nextdp storage` and a root-only copy of `/opt/nextdp/config/.env`.
  - Download the dumps and the storage tar (not the `.env`) to `D:\nmc-backup\mail-vm\<ts>\`.
  - Check: `pg_restore --list` works on the local copy, and the tar lists the 32 new `.eml` files.
- [ ] **0.2 Export `nmc-mail-1-osdisk`** (D1). Plan:
  1. This PC: `az disk grant-access --subscription 53b184f6-7bb2-4fb9-9970-bc1aaf1e5818 -g EMAIL -n nmc-mail-1-osdisk --duration-in-seconds 86400 --access-level Read`, and save `accessSAS` to a `0600` file in `private-data/`. Never print it.
  2. Mail VM (no extra VM needed; 51 GB free, the VHD is 30 GB): download with AzCopy to `/var/tmp/nmc-mail-1.vhd` (~5–10 min inside AWS Mumbai), then check that the size equals 30 GiB + 512 bytes and the footer starts with `conectix`.
  3. Mail VM: `sudo losetup -r -P -f --show /var/tmp/nmc-mail-1.vhd`, then `sudo mount -o ro,noload /dev/loopXp1 /mnt/mail1`. A fixed VHD is a raw image plus a 512-byte footer, so no conversion is needed.
  4. Read `/mnt/mail1/opt/nextdp/config/.env` (keys only, not values) to find its `STORAGE_LOCAL_PATH`. Tar only that storage tree (`emails/`, `attachments/`, `bimi/`) to `/var/backups/nextdp/mail1-storage.tar.gz` and copy it to this PC.
  5. Unmount, `losetup -d`, delete the VHD, `az disk revoke-access`.
  - The files are **merged in Phase 4**, after the cutover (see rule 6).
- [ ] **0.3 (skipped by owner, 2026-11-20)** `nmc-db-1-osdisk` is not exported. All databases come from R2. Accepted loss: mail that reached Azure between 08:30 and ~15:51 IST on 18 Nov (see 2.5 point 2).

### Phase 1: Stage and dry run (no downtime)

- [ ] **1.1 Owner approval** in chat to unseal the R2 restic password (secret access gate, AGENTS.md §5.2).
- [ ] **1.2 Restore R2 snapshot into `nextdp_mail_r2`** (new: `scripts/mail-vm/11-stage-r2-mail-db.{ps1,sh}`)
  - Reuse the unseal code from `03b-check-nmc-r2-backups.sh`. Run `restic dump 689c5e6a <path-of-.dump>` into a `0600` temp file.
  - `CREATE DATABASE nextdp_mail_r2 OWNER nextdp_mail`, then `pg_restore -d nextdp_mail_r2 --no-owner --no-acl --role=nextdp_mail`.
  - **Do not** stop services and **do not** touch `nextdp_mail`. (The existing `04-restore-r2-db.sh` drops `nextdp_mail`, so it must not be used here.)
  - Start `16/nmcmain` only for the unseal step, then stop it again to free RAM.
- [ ] **1.3 Re-measure the delta** with `temp/mail-delta-inspect.sh` and `temp/mail-delta-detail.sh` (read-only; outputs in `temp/*-out.txt`).
- [ ] **1.4 Compare the two databases** (new, read-only: `scripts/mail-vm/12-compare-mail-dbs.sh`). Report:
  - Schema: `pg_dump --schema-only` of both, diffed. They must match. If R2 is older, `nextdp migrate` runs against it in task 2.6.
  - Row counts per table, and the R2 max IDs (expected far above the August values).
  - Overlap by natural key: the 3 AWS domains (by `name`), the 3 AWS users (`email`), the 3 mailboxes (`email_address`). This answers D3/D4.
  - The 6 changed old messages: do they exist in R2 by `public_id`?
  - `organizations.settings` and `system_settings`: list keys that differ, comparing `md5(value)` only (D5). Also check that R2 has no `storage` config pointing to the dead `s3.nextdp.com`.
  - `super_admins`: is `admin@rajesh1.com` the same password hash (compare `md5(password)` only)?
  - Duplicate guard: any AWS `raw_emails.message_id` already present in R2 (expected none).
- [ ] **1.5 DKIM check** for all domains: compare the DKIM TXT record served by the DNS VM (`dig +short TXT <selector>._domainkey.<domain> @52.66.165.1`) with `dkim_public_key` in **both** DBs. Record the result per domain (D4). Outbound mail goes through the ZeptoMail API, so a mismatch is not urgent, but fix it before any direct SMTP sending.
- [ ] **1.6 Dry-run the merge** (new: `scripts/mail-vm/13-merge-aws-delta.{ps1,sh}` + `13-merge-aws-delta.sql`, `DRY_RUN=1` by default)
  - Runs the full merge (section 5) inside one transaction on `nextdp_mail_r2`, prints the ID mapping and the before/after counts, then `ROLLBACK`.
  - Pass: every delta row is mapped, no FK/unique errors, and the counts equal R2 counts plus the delta counts.

### Phase 2: Cutover (about 10 minutes of downtime)

All steps go into one script with stop-on-error (new: `scripts/mail-vm/14-cutover-mail-db.{ps1,sh}`).

- [ ] **2.1** Stop `nextdp-scheduler`, `nextdp-worker`, `nextdp`. SMTP/IMAP/POP3 and the web APIs go offline, while Caddy stays up. Sending servers queue inbound mail and retry.
  - Before stopping, check the worker queue is empty, so no pending job refers to old IDs.
- [ ] **2.2** Final `pg_dump -Fc nextdp_mail` (frozen state) to `/var/backups/nextdp/<ts>-final/` and download it to this PC.
- [ ] **2.3** Re-stage: drop and re-restore `nextdp_mail_r2` from the R2 dump (clean base, 1–2 min), then run the merge with `DRY_RUN=0` (COMMIT). Save the ID mapping to `/var/backups/nextdp/<ts>-final/id-map.csv`.
- [ ] **2.4** Files:
  - Copy the 32 delta `.eml` files as they are. Their paths contain UUIDs, so nothing collides, and `eml_path` stays the same.
  - Copy each delta attachment to `attachments/<new_org_id>/<new_raw_email_id>/<filename>`, matching the rewritten `storage_path`. Then **remove** the old copies at `attachments/1/<aws_raw_id>/` (they are in the 2.2/0.1 backups). This frees those paths for the Azure files that belong to R2's rows with the same IDs (Phase 4).
  - `chown -R ubuntu:ubuntu /opt/nextdp/storage`.
- [ ] **2.5** Swap databases: terminate connections, `ALTER DATABASE nextdp_mail RENAME TO nextdp_mail_aug_old`, `ALTER DATABASE nextdp_mail_r2 RENAME TO nextdp_mail`.
- [ ] **2.6** Post-swap fixes on the new `nextdp_mail`:
  - `cd /opt/nextdp/config && /opt/nextdp/bin/nextdp migrate`.
  - `setval` every sequence to `max(id)`.
  - Recompute `folders.total_messages/unread_messages` and `mailboxes.total_messages/unread_messages/storage_used_bytes`. Confirm the formula in `nextdp-mail` code when writing the script.
  - Bump `folders.uid_validity` for **all** folders (rule 5), and set `uid_next = max(imap_uid) + 1`.
- [ ] **2.7** Invalidate logins (rule 4): replace `JWT_SECRET` and `SESSION_SECRET` in `/opt/nextdp/config/.env` with new random values generated on the VM (never printed), and delete NextDP's Redis keys (check key prefixes first; `cconsole_hub`/others may share Redis).
- [ ] **2.8** Start `nextdp`, `nextdp-worker`, `nextdp-scheduler`. Check `curl http://127.0.0.1:8080/api/health/ready` and `scripts/mail-vm/status.ps1`.

### Phase 3: Verify (right after cutover)

- [ ] **3.1** Counts: organizations/domains/users/mailboxes/messages = R2 + delta. All 27+ domains present.
- [ ] **3.2** Log in to webmail as `rajesh@nextdp.com` and one AWS-created user. The 16 / 2 / ... AWS-period messages appear in the inbox with their original dates. Open one of them, and open the AWS attachment of raw email 3637 (now under its new ID).
- [ ] **3.3** Send a test mail from an outside account to `rajesh@nextdp.com` and `namaste@mrajesh.com`: it arrives. Reply from webmail: it goes out through ZeptoMail.
- [ ] **3.4** IMAP client (Thunderbird/phone): it resyncs the folders (new UIDVALIDITY) without errors.
- [ ] **3.5** Admin console and super admin console log in (`super-admin.mail.nextdp.com`). Check org transport settings (D5).
- [ ] **3.6** Watch `journalctl -u nextdp -u nextdp-worker -f` for 15 minutes for `failed to read .eml` / FK errors. Expect `.eml` errors only for Aug→Nov messages until Phase 4.
- [ ] **3.7** Update `docs/mail-vm-runbook.md` ("Restored state" section) and this doc's status, then commit (scripts and docs only, nothing from `private-data/` or `temp/`).

### Phase 4: Fill the remaining gaps (after cutover)

- [ ] **4.1** Merge the `nmc-mail-1` storage tree from 0.2 into `/opt/nextdp/storage/uploads/` with `rsync -a --ignore-existing` (keeps the AWS files; August files are identical). Then count `raw_emails.eml_path` and `attachments.storage_path` rows whose file is still missing; expect 0 except gap mail.
- [ ] **4.2** Skipped (D2 = no).
- [ ] **4.3** Drop `nextdp_mail_aug_old` after one week without problems (keep the local dumps).

### Phase 5: Don't get caught again

- [x] **5.1** (done 2026-11-20, [`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md); weekly restore test instead of monthly) Nightly off-site backup from the Mail VM: `pg_dump nextdp_mail` + `restic backup /opt/nextdp/storage` to an R2 bucket/prefix that does not depend on NMC (new restic password stored only in `private-data/` + AW Vault). Add a monthly restore test.
- [ ] **5.2** Repeat the same pattern for `cconsole_hub` on this VM (R2 snapshot `677d331a`, 2026-11-18 09:30 IST), if it also got writes on AWS. This is a separate small task.

---

## 5. Merge rules (what `13-merge-aws-delta.sql` must do)

Source = the live AWS DB (copied into a schema `aws_delta` inside `nextdp_mail_r2` with `psql \copy ... | psql \copy`, no extension needed). Target = `public` in `nextdp_mail_r2`. Delta = rows with ID above the August baseline (section 2.2), plus the changed old rows listed below.

1. **Map by natural key, insert with new IDs** (the target's own sequences assign IDs, which are all above R2's maxima):

   | Table | Match key in target | If found | If not found |
   |---|---|---|---|
   | `organizations` | `name` | map ID | (none expected) stop with error |
   | `domains` | `name` | map ID. DKIM per D4 | insert, remap `org_id`, `catch_all_mailbox_id` (after mailboxes) |
   | `users` | `lower(email)` | map ID. Password/TOTP per D3 | insert, remap `org_id`, `invited_by` |
   | `mailboxes` | `lower(email_address)` | map ID | insert, remap `user_id`, `org_id` |
   | `folders` | (`mailbox_id`, `slug`) | map ID | insert, remap `mailbox_id`, `parent_id` |
   | `raw_emails` | none (dedupe guard on `message_id` + recipient) | skip and report | insert, remap `domain_id`, `org_id`. `eml_path` unchanged |
   | `attachments` | none | – | insert, remap `raw_email_id`, `org_id`. `storage_path` → `attachments/<org>/<new_raw_id>/<filename>` |
   | `messages` | `public_id` | skip and report | insert, remap `mailbox_id`, `folder_id`, `raw_email_id`, `org_id`. `imap_uid` = target folder's `uid_next` + row number by `received_at` |
   | `audit_logs` | none | – | insert, remap `actor_id`/`target_id` where they point at users |

   Keep `public_id` values from the source (they are UUIDs and don't collide).
   Skip `search_histories` and `migration_*` (empty or not needed).
2. **Changed old rows:** for the 6 August messages, find them in the target by `public_id` and copy `is_read`, `is_starred`, `is_answered`, `is_deleted` and the folder (by slug) **only if** the target row's `updated_at` is older than the source's. Copy users' `last_login_at` the same way. Everything else in old rows keeps the R2 value.
3. **Settings:** copy `settings->'transport'` per org and the `transport` row in `system_settings` from the source only if D5 says so.
4. **Rotate `JWT_SECRET` at cutover.** Tokens carry the numeric `user_id`/`admin_id` (`auth_service.go`). After the swap, the same number can belong to a different user (AWS user 29 is `rajesh@nextidp.com`; in R2, user 29 is probably a user created on Azure), so an old token would open the wrong mailbox. `JWT_SECRET` only signs tokens, so rotating it is safe. `MIGRATION_ENCRYPTION_KEY` must **not** change (it decrypts `migration_jobs` passwords).
5. **Bump UIDVALIDITY.** The AWS server gave UIDs to the new messages starting from the August `uid_next`, and R2 used those same UIDs for different (Aug→Nov) messages. IMAP clients that synced either server have caches that no longer match. A new `uid_validity` (e.g. the Unix time of the cutover, fits in 32 bits) makes every client resync cleanly.
6. **Attachment path collision.** Attachment paths contain the raw email ID. AWS raw IDs 3637 and 3657–3663 are the same numbers R2 uses for Azure-period emails, whose files will come from `nmc-mail-1` in Phase 4. Moving the AWS files to their new IDs (task 2.4) prevents an Azure file from being skipped or the wrong attachment from being served.
7. **One transaction.** The whole merge runs in a single transaction with `ON_ERROR_STOP=1`. `DRY_RUN=1` ends with `ROLLBACK`.

---

## 6. Rollback

Usable at any point up to a week after cutover (until `nextdp_mail_aug_old` is dropped):

1. Stop `nextdp-scheduler nextdp-worker nextdp`.
2. `ALTER DATABASE nextdp_mail RENAME TO nextdp_mail_r2_failed`, then `ALTER DATABASE nextdp_mail_aug_old RENAME TO nextdp_mail`.
3. Restore the AWS attachment files from the task 2.2 tar into their old paths (`attachments/1/<aws_raw_id>/`).
4. Rotate `JWT_SECRET` again and clear NextDP Redis keys (same reason as rule 4).
5. Start the services. Mail received after the cutover is in `nextdp_mail_r2_failed` and has to be merged back with the same delta script.

If the VM itself is lost: the dumps and storage tar from 0.1 / 2.2 are on this PC under `D:\nmc-backup\mail-vm\`.

---

## 7. Quick reference

| What | Value |
|---|---|
| Mail VM | `52.66.111.138`, `ubuntu`, key path in `private-data/vms-details.txt` |
| Connect helper | `. .\scripts\mail-vm\common.ps1; $vm = Get-VmTarget -Name "Mail VM"` then `Invoke-VmScript -Vm $vm -LocalScriptPath <file.sh>` |
| Mail DB | cluster `16/main`, port 5432, DB `nextdp_mail`, owner `nextdp_mail` |
| NMC DB (for unsealing only) | cluster `16/nmcmain`, port 5433, DB `nextmanager_core`. `sudo pg_ctlcluster 16 nmcmain start|stop` |
| App | `/opt/nextdp/{bin,config,storage,web}`, units `nextdp`, `nextdp-worker`, `nextdp-scheduler` |
| Storage | `/opt/nextdp/storage/uploads/{emails,attachments}/<org_id>/...` |
| Path formats (code) | `.eml`: `emails/<org>/<YYYY-MM>/<uuid>.eml` (`inbound_mail_service.go`). Attachment: `attachments/<org>/<raw_email_id>/<filename>` |
| Body source in webmail | `raw_emails.text_body/html_body` in DB. `.eml` file needed for download, IMAP full fetch, sending |
| Read-only inspection scripts | `temp/mail-delta-inspect.sh`, `temp/mail-delta-detail.sh`, `temp/nmc-mail-plans.sh` (scratch, not committed) |
| R2 snapshot for mail | `689c5e6a` (2026-11-18 08:30 IST) |
| Azure disk to export | `nmc-mail-1-osdisk` (RG `EMAIL`, 30 GB, Linux), subscription `53b184f6-7bb2-4fb9-9970-bc1aaf1e5818` |
