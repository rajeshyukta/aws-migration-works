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

Once a snapshot ID (from `restic`) or dump file is identified:

```powershell
# Example using a restic snapshot from prefix prod-main:
powershell -NoProfile -File .\scripts\mail-vm\04-restore-r2-db.ps1 -RepoPrefix prod-main -SnapshotId <SNAPSHOT_ID>
```

The restore script:
1. Extracts the `.dump` file from restic into `/tmp/r2-restore/` (and cleans up temp files via `trap`).
2. Stops `nextdp*` units, recreates `nextdp_mail` owned by `nextdp_mail` using the password from `/opt/nextdp/config/.env`.
3. Runs `pg_restore --no-owner --role=nextdp_mail`.
4. Runs `cd /opt/nextdp/config && /opt/nextdp/bin/nextdp migrate`.
5. Prints table row counts (`raw_emails`, `messages`, `users`, `organizations`, `domains`, `mailboxes`, `attachments`).
6. Enables and starts `nextdp`, `nextdp-worker`, and `nextdp-scheduler`.

*(Fallback if R2 snapshots cannot be decrypted yet: pass `-StartServices` to `02-build-and-deploy.ps1` and run `nextdp migrate` + `nextdp db:seed` to start with a fresh DB while waiting on Azure support.)*

---

## Step 4 — Verification & Lightsail Firewall Hardening

Check full VM health:

```powershell
powershell -NoProfile -File .\scripts\mail-vm\status.ps1
```

Once verified live, restrict the AWS Lightsail instance firewall from "All ports" to **only**:

| Protocol | Port | Purpose |
|---|---|---|
| TCP | `22` | SSH (optionally restrict to your IP) |
| TCP | `25` | Inbound SMTP (MX delivery) |
| TCP | `80` | HTTP → HTTPS redirect & ACME HTTP-01 |
| TCP | `443` | HTTPS (Webmail, Admin, Super Admin, Autoconfig) |
| TCP | `465` | SMTPS (implicit TLS submission) |
| TCP | `587` | SMTP Submission (STARTTLS) |
| TCP | `110` | POP3 (STARTTLS) |
| TCP | `995` | POP3S (implicit TLS) |
| TCP | `143` | IMAP (STARTTLS) |
| TCP | `993` | IMAPS (implicit TLS) |
