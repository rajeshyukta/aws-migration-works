# Mail VM off-site backup (restic → Cloudflare R2)

Nightly backup of the AWS Lightsail **Mail VM** (`52.66.111.138`) to its own encrypted restic repository on Cloudflare R2. It does not depend on NextManager Core, Azure, or the VM itself. Set up on 2026-11-20 (Phase 5 of [`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md)).

- **No secrets in this file.**
- **Owner action (required):** upload `private-data/mail-vm-offsite-backup.env` to the AW Vault (project `dev-workspace`). It holds the only copy of the repository password outside the VM. Without it, the backup cannot be restored.

---

## 1. What runs

| Item | Value |
|---|---|
| Repository | `s3:<account>.r2.cloudflarestorage.com/nxtmngr-test/aws-mail-vm` (restic repo id `dc5ab80661`). Separate from NMC's `prod-main/`, which is never touched |
| R2 key | The key in `private-data/r2.env`. If that key is rotated, rerun the setup script (section 4) |
| Repo password | Generated on 2026-11-20. Stored in `private-data/mail-vm-offsite-backup.env` (owner PC), in `/etc/nextdp-backup/restic.env` (VM, root 0600), and in the AW Vault (owner) |
| Nightly backup | `nextdp-offsite-backup.timer`, 21:00 UTC = **02:30 IST** (+ up to 10 min random delay, `Persistent=true`) |
| Weekly verify | `nextdp-offsite-verify.timer`, Saturday 22:30 UTC = **Sunday 04:00 IST**: `restic check --read-data-subset=25%`, then restores the latest `nextdp_mail` dump into a temporary DB `nextdp_mail_restoretest`, counts the rows and drops the DB |
| Failure alert | `OnFailure=` → `nextdp-backup-alert@.service` mails the last journal lines to **rajesh@nextdp.com** through the local SMTP listener. Tested 2026-11-20 |
| Retention | 14 daily, 8 weekly, 12 monthly (`restic forget --prune` after each backup) |
| Program | `/usr/local/sbin/nextdp-offsite-backup backup\|verify\|status\|alert` (source: `templates/backup/nextdp-offsite-backup.sh`) |

**Snapshot contents (host tag `mail-vm`, tags `nextdp-mail`, `nightly`):**
- `/var/backups/nextdp/nightly/db/`: `pg_dump -Fc` of **every** app DB on cluster `16/main` (today `nextdp_mail` and `cconsole_hub`; new DBs are picked up automatically), plus `globals.sql` (roles) and `SHA256SUMS`. Not included: `postgres`, templates, and `*_aug_old`, `*_r2*`, `*_restoretest`, `*_failed`.
- `/opt/nextdp/storage` (mail `.eml` files, attachments, BIMI, uploads; `cache/` and `logs/` excluded) and `/opt/nextdp/config` (includes `.env` with `MIGRATION_ENCRYPTION_KEY`).
- `/etc/caddy`, `/etc/coredns`, `/opt/dithim`, `/var/lib/dithim` (dithim.com site and form submissions).

**First run (2026-11-20 04:52 UTC):** snapshot `f38985e4`, 9,187 files, 286.7 MiB in, 143.7 MiB stored. Verify: 18 tables, 6,472 messages restored = live.

## 2. Daily checks

```bash
sudo nextdp-offsite-backup status          # last success/verify, latest 5 snapshots, repo size, next timers
systemctl list-timers 'nextdp-offsite-*'
sudo journalctl -u nextdp-offsite-backup -n 30 --no-pager
```

From this PC: `. .\scripts\mail-vm\common.ps1; Invoke-VmCommand -Vm (Get-VmTarget -Name "Mail VM") -Command "sudo nextdp-offsite-backup status"`.

## 3. Restore

You need: a Linux machine with `restic` ≥ 0.17 and PostgreSQL 16+, the R2 key (`private-data/r2.env`) and the repo password (`private-data/mail-vm-offsite-backup.env` or the AW Vault). Put them into a root-only env file:

```bash
sudo install -m 600 /dev/null /root/restic.env   # then add the lines below with real values
#   RESTIC_REPOSITORY=s3:<account>.r2.cloudflarestorage.com/nxtmngr-test/aws-mail-vm
#   RESTIC_PASSWORD=...
#   AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_DEFAULT_REGION=auto
sudo bash -c 'set -a; . /root/restic.env; set +a; restic snapshots --host mail-vm'
```

**A. One lost file** (e.g. an `.eml`), on the Mail VM:
```bash
sudo bash -c 'set -a; . /etc/nextdp-backup/restic.env; set +a; restic dump --host mail-vm latest /opt/nextdp/storage/uploads/<path>' > /tmp/file
```

**B. Database only** (e.g. a bad change), on the Mail VM:
1. `restic restore latest --host mail-vm --include /var/backups/nextdp/nightly/db --target /var/tmp/r`
2. Restore side by side first: `createdb -O nextdp_mail nextdp_mail_restore` and `pg_restore -d nextdp_mail_restore --no-owner --no-acl --role=nextdp_mail /var/tmp/r/var/backups/nextdp/nightly/db/nextdp_mail.dump`
3. Check the data, then swap by rename with the services stopped (same pattern as `scripts/mail-vm/14-cutover-mail-db.sh` step 9), start them, and delete `/var/tmp/r`.

**C. Whole VM lost:**
1. New Ubuntu 24.04 VM. Run `scripts/mail-vm/02-build-and-deploy.ps1 -RunSetup` (packages, app, Caddy, systemd units; services stay stopped).
2. `restic restore latest --host mail-vm --target /var/tmp/r`.
3. Copy `/var/tmp/r/opt/nextdp/config/.env` over the generated one, which keeps `MIGRATION_ENCRYPTION_KEY` and the DB/Redis passwords. Restore roles from `globals.sql` if needed. Create the DBs and `pg_restore` `nextdp_mail.dump` and `cconsole_hub.dump`.
4. `rsync -a /var/tmp/r/opt/nextdp/storage/ /opt/nextdp/storage/`, then `chown -R ubuntu:ubuntu /opt/nextdp/storage`. Restore `/etc/caddy`, `/etc/coredns`, `/opt/dithim`, `/var/lib/dithim` the same way.
5. `nextdp migrate`, start the services, point DNS/MX at the new IP, then rerun `16-setup-offsite-backup.ps1` so nightly backups continue into the same repo.

## 4. Install / change

```powershell
# from E:\workspace\aws-setup-and-migrations (idempotent; reuses the existing repo password)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\mail-vm\16-setup-offsite-backup.ps1            # install + run backup and verify now
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\mail-vm\16-setup-offsite-backup.ps1 -NoRunNow  # install only
```
To change what is backed up, edit `PATHS` / `EXCLUDES` / `KEEP` in `templates/backup/nextdp-offsite-backup.sh` and rerun. **Never delete `private-data/mail-vm-offsite-backup.env`**: a new password cannot open the existing repo.
