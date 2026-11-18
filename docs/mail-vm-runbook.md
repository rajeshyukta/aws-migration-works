# Mail VM Migration Runbook (`52.66.111.138`)

> **Target**: AWS Lightsail (`Ubuntu 24.04.5 LTS`, `52.66.111.138`, user `ubuntu`)
> **Source Repo**: `E:\workspace\projects\platform\nextdp-mail` (`main`)

---

## Step 1 — Base Provisioning & App Deploy

Run from `E:\workspace\aws-setup-and-migrations`:

```powershell
# 1. Provision OS, swap, PostgreSQL 16, Redis 7, Caddy 2, restic 0.19.1, boto3, /opt/nextdp, log caps
# 2. Build NextDP Go binary + 3 SPAs and upload them + Caddyfile + systemd units
powershell -NoProfile -File .\scripts\mail-vm\02-build-and-deploy.ps1 -RunSetup
```

What this does **not** do yet:
- If `/opt/nextdp/config/.env` did not exist, `02-remote-install.sh` generates strong random secrets (`DB_PASSWORD`, `REDIS_PASSWORD`, `SESSION_SECRET`, `JWT_SECRET`, `APP_KEY`, `MIGRATION_ENCRYPTION_KEY`) directly on the VM (`chmod 600`, never printed).
- By default (`-StartServices` omitted), `nextdp`, `nextdp-worker`, and `nextdp-scheduler` stay **stopped** until the database is restored from R2 (or explicitly initialized if no R2 restore is possible), while **Caddy starts immediately** to obtain Let's Encrypt TLS certificates and sync `mail.nextdp.com.crt`/`.key` for mail ports.

---

## Step 2 — Inspect Cloudflare R2 Bucket (`nxtmngr-test`)

1. Copy `templates/r2.env.example` to `private-data/r2.env` (gitignored).
2. Fill in your Cloudflare R2 Account ID / endpoint, Access Key ID, Secret Access Key, and (if known) `RESTIC_PASSWORD`.
3. Run the read-only R2 inspection script (transfers `r2.env` to `/tmp/.r2.env` with `chmod 600` and deletes it on exit via `trap`; never prints credentials):

```powershell
powershell -NoProfile -File .\scripts\mail-vm\03-check-r2.ps1
```

This reports:
- All top-level prefixes in `nxtmngr-test` (e.g. `prod-main/`, `admin/`, etc.)
- Any unencrypted `.dump`, `.sql`, `.zip`, or `.tar.gz` objects if present
- Whether `restic snapshots` unlocks the repo with `RESTIC_PASSWORD` (and lists snapshot IDs, timestamps, tags, and paths)

---

## Step 3 — Restore Database & Start Services

### Option A — Restore from Cloudflare R2 (`restic` / raw S3 dump)

Once a `RESTIC_PASSWORD` and snapshot ID (or raw object key) are available:

```powershell
# Example using a restic snapshot from prefix prod-main:
powershell -NoProfile -File .\scripts\mail-vm\04-restore-r2-db.ps1 -RepoPrefix prod-main -SnapshotId <SNAPSHOT_ID>
```

### Option B — Restore from Local Backup Archive (Used on `2026-11-18`)

Because the R2 `nxtmngr-test/prod-main` repository's auto-generated `RESTIC_PASSWORD` lives sealed in stopped Azure `nmc-main` (`backup_targets.repo_password_enc`), NextDP Mail was restored from the verified pre-Azure local backup (`aws-final-20260826`):

```powershell
powershell -NoProfile -File .\scripts\mail-vm\05-restore-local-backup.ps1 `
  -BackupDir "D:\WorkSpace\PROJECTS\NextDP_Mail\private-data\backups\aws-final-20260826"
```

The restore scripts:
1. Extract the `.dump` (R2) or upload the staged `.dump`/`.sql` + `opt-nextdp.tar.gz` (`05-restore-local-backup.ps1`).
2. Stop `nextdp*` units, copy the dump to a `0600` `postgres`-owned temp file, recreate `nextdp_mail` owned by `nextdp_mail` using `/opt/nextdp/config/.env`, and run `pg_restore --no-owner --no-acl --role=nextdp_mail`.
3. Optionally restore `/opt/nextdp/storage/{attachments,bimi,emails,uploads}` and sync `MIGRATION_ENCRYPTION_KEY` from `dot-env-config` (without printing secrets).
4. Run `cd /opt/nextdp/config && /opt/nextdp/bin/nextdp migrate` and print row counts (`organizations`, `domains`, `users`, `mailboxes`, `messages`, `raw_emails`, `attachments`).
5. Enable and start `nextdp`, `nextdp-worker`, and `nextdp-scheduler`.

### Outbound Transport & Login Notes (Restored `2026-08-26` State)

- Global `system_settings` and organizations `default` (`rajesh@nextdp.com`, including `nextdp.com`) and `rajesh-one` (`rajesh@navasanatani.com`) use **ZeptoMail API** (`region=in`, `api.zeptomail.in`), verified reachable over HTTPS from `52.66.111.138`.
- Organization `idn-mail` (`rajesh@digpre.com`: `digpre.com`, IDN domains) still has legacy SMTP relay `mailout.nextdp.com:587` configured in its org settings; update it to ZeptoMail in the Admin Console if you want outbound delivery via ZeptoMail for those domains too.
- Restored `super_admins` login: `admin@rajesh1.com` (`https://super-admin.mail.nextdp.com/` or `https://super-admin.mail.rajesh1.com/`).
- Leaving `nxtmngr-test/prod-main` untouched in R2 allows a one-command upgrade to the `2026-11-18` snapshot via `04-restore-r2-db.ps1` once Azure `nmc-main` (`RESTIC_PASSWORD`) is recovered.

---

## Step 4 — Authoritative CoreDNS + Catch-All Maintenance Page (`ns1`/`ns2.nextdp.com`)

Deploys **CoreDNS v1.15.0** (authoritative-only wildcard/template responder on `:53`) + Caddy catch-all HTTP/HTTPS maintenance site (`503 Service Unavailable`, `Retry-After: 3600`) guarded by `nextdp-tls-ask` (`127.0.0.1:9055`):

```powershell
powershell -NoProfile -File .\scripts\mail-vm\06-setup-dns-and-maintenance.ps1
```

What this configures:
- **CoreDNS (`/etc/coredns/Corefile`)**: binds ONLY to the VM's primary NIC (`172.26.3.188`) and `127.0.0.1` so Ubuntu's `systemd-resolved` stub (`127.0.0.53`) keeps working cleanly.
  - Answers authoritatively (`aa=1`, `ra=0`) for any valid domain pointed to `ns1.nextdp.com` / `ns2.nextdp.com`:
    - `A` (`@`, `www`, `*`) → `52.66.111.138` (TTL 300)
    - `MX` → `0 mx.nextdp.com.` (TTL 3600)
    - `NS` → `ns1.nextdp.com.`, `ns2.nextdp.com.` (TTL 3600, glue additional `52.66.111.138`)
    - `SOA` → `ns1.nextdp.com. dns-admin.nextdp.com.`
    - Unsupported query types (`AAAA`, `CAA`, `TXT`, etc.) → `NOERROR` NODATA + `SOA` authority (required so ACME/Let's Encrypt CAA validation passes).
- **Maintenance HTML (`/opt/nextdp/maintenance/index.html`) + Caddy Catch-All (`https://`)**:
  - Serves every unmatched domain over HTTPS with automatic on-demand Let's Encrypt certs.
  - Guarded by `nextdp-tls-ask.service` (`http://127.0.0.1:9055/ask`), which rejects IP literals, `.local`/`.arpa`/internal names, deep label fuzzing, unpointed hosts (`A != 52.66.111.138`), and exceeds-cap bots (`max 10` hosts per base domain, `max 500/hour`).
  - Returns `HTTP 503` + `Retry-After: 3600` + `X-Robots-Tag: noindex, nofollow` to protect SEO indexing while sites are under maintenance.

---

## Step 5 — Daily Access Logs & Traffic Analytics

Deploys trimmed JSON access logging (`50 MiB` roll, `72h` live buffer, stripping noisy response/TLS/client-hint headers) plus a nightly `00:05 IST` archiver & domain traffic analyzer:

```powershell
powershell -NoProfile -File .\scripts\mail-vm\07-setup-access-logs.ps1
```

Outputs on the VM under `/var/log/caddy/daily/<YYYY-MM-DD>/` (`30`-day retention):
- `all-domains-<YYYY-MM-DD>.jsonl.gz` — unified parked-domain traffic
- `mail-services-<YYYY-MM-DD>.jsonl.gz` — Webmail, Admin, Super Admin, Autoconfig traffic
- `by-domain/<domain>-<YYYY-MM-DD>.jsonl.gz` — separate dated file per domain
- `summary-<YYYY-MM-DD>.csv` & `summary-<YYYY-MM-DD>.json` — per-domain `human_likely_hits`, `search_bot_hits`, `scanner_hits`, `unique_ips`, top paths & referers

Run a live traffic report anytime via SSH:
```bash
sudo nextdp-traffic                   # today's IST traffic table
sudo nextdp-traffic --date 2026-11-18 # specific IST date
```

---

## Step 6 — Verification & Lightsail Firewall Hardening

Check full VM health:

```powershell
powershell -NoProfile -File .\scripts\mail-vm\status.ps1
```

Once verified live, restrict the AWS Lightsail instance firewall from "All ports" to **only**:

| Protocol | Port | Purpose |
|---|---|---|
| TCP | `22` | SSH (optionally restrict to your IP) |
| TCP | `25` | Inbound SMTP (MX delivery) |
| UDP + TCP | `53` | CoreDNS authoritative DNS (`ns1`/`ns2.nextdp.com`) |
| TCP | `80` | HTTP → HTTPS redirect & ACME HTTP-01 |
| TCP | `443` | HTTPS (Webmail, Admin, Super Admin, Autoconfig, Maintenance) |
| TCP | `465` | SMTPS (implicit TLS submission) |
| TCP | `587` | SMTP Submission (STARTTLS) |
| TCP | `110` | POP3 (STARTTLS) |
| TCP | `995` | POP3S (implicit TLS) |
| TCP | `143` | IMAP (STARTTLS) |
| TCP | `993` | IMAPS (implicit TLS) |
