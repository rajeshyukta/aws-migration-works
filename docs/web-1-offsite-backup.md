# Web-1 off-site backup (restic → Cloudflare R2)

Nightly backup of **Web-1** (`3.6.143.66`) to its own encrypted restic repository on Cloudflare R2. It uses the same tool as the Mail VM ([`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md)), with Web-1 settings in `templates/backup/web-1.backup.conf`. Set up on 2026-11-20.

- **No secrets in this file.**
- **Owner action (required):** upload `private-data/web-1-offsite-backup.env` to the AW Vault (project `dev-workspace`). Without that password the backup cannot be restored.

## 1. What runs

| Item | Value |
|---|---|
| Repository | `s3:<account>.r2.cloudflarestorage.com/nxtmngr-test/aws-web-1` (restic repo id `f7fa98a985`), host tag `web-1`, tags `web-1`, `nightly` |
| Repo password | `private-data/web-1-offsite-backup.env` (owner PC), `/etc/nextdp-backup/restic.env` on Web-1 (root 0600), AW Vault (owner) |
| Nightly backup | 21:15 UTC = **02:45 IST** (+ up to 10 min random delay) |
| Weekly verify | Saturday 23:00 UTC = **Sunday 04:30 IST**: `restic check --read-data-subset=25%`, then restores the latest `domains_rajesh` dump into `domains_rajesh_restoretest`, compares `whois_history` row counts and drops the DB |
| Failure alert | Mail to **rajesh@nextdp.com** through the Mail VM's SMTP on its **private IP `172.26.3.188:25`**. AWS blocks outbound port 25 to public IPs. Tested 2026-11-20. If the Mail VM's private IP changes, update `ALERT_SMTP_HOST` (rerun the setup with a new `-AlertSmtpHost`) |
| Retention | 14 daily, 8 weekly, 12 monthly |
| Program | `/usr/local/sbin/nextdp-offsite-backup` (same as the Mail VM) + `/etc/nextdp-backup/backup.conf` |

**Snapshot contents:**
- `/var/backups/web1/nightly/db/`: `pg_dump -Fc` of every DB on cluster `16/main` (`cconsole_hub`, `domains_rajesh`, `web1_apps`; new DBs are picked up automatically) + `globals.sql`, and consistent `sqlite3 .backup` copies of the 4 SQLite files (daiskills enquiries, organicgrowth.center, nextdigital.in, proseva.org) in `sqlite/`.
- `/srv` (all PHP apps with their releases and `shared/` + `.env` files, all static sites). Cache, session, debugbar and `node_modules` are excluded.
- `/etc/caddy` (incl. the local CA certs for `domains.rajesh.in`), `/etc/php/8.4`, `/etc/cron.d`, `/etc/systemd/system`, `/etc/redis/web1-override.conf`, and the root-only secret files `/root/.cconsole-hub-db-pass`, `/root/.web1-redis-pass`, `/root/.web1-secrets.env`, `/root/.web1-domains-secrets.env`.

**First run (2026-11-20 06:27 UTC):** snapshot `e9661799`, 9,708 files, 359.6 MiB in, 67.8 MiB stored. Verify: `domains_rajesh` 17 tables, `whois_history` 49,978 rows restored = live.

## 2. Checks

```bash
sudo nextdp-offsite-backup status
sudo journalctl -u nextdp-offsite-backup -n 30 --no-pager
```

## 3. Restore

Same procedure as [`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md) section 3, with `--host web-1` and the Web-1 password file. Paths:
- DB dumps: `/var/backups/web1/nightly/db/<db>.dump`, SQLite copies: `/var/backups/web1/nightly/db/sqlite/<path_with_underscores>`.
- One site: `restic restore latest --host web-1 --include /srv/phpapps/<site> --target /var/tmp/r`.
- Whole VM: new Ubuntu 24.04 → `scripts/web-1-vm/01-server-setup.ps1`, restore `/srv`, `/etc/caddy`, `/etc/php/8.4`, `/etc/cron.d`, the custom units in `/etc/systemd/system`, `/root/.*` secret files, then create roles/DBs and `pg_restore` each dump, copy SQLite files back, reload PHP-FPM and Caddy, and rerun `07-setup-offsite-backup.ps1`.

## 4. Install / change

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\web-1-vm\07-setup-offsite-backup.ps1            # install + backup + verify now
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\web-1-vm\07-setup-offsite-backup.ps1 -NoRunNow  # install only
```
Change what is backed up in `templates/backup/web-1.backup.conf` (add new SQLite files to `SQLITE_FILES`) and rerun. Never delete `private-data/web-1-offsite-backup.env`.
