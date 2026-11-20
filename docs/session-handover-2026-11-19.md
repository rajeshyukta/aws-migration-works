# Session Context & Infrastructure Handover — `2026-11-19` (`15:34 IST`)

> **Purpose:** Complete context transfer from Antigravity/Gemini session to continue in another IDE without losing workspace state, VM topology, verified R2 backup inventory, or safety constraints.
> **Strictly NO secrets** are stored in this document (refer only to gitignored `private-data/` paths or on-box root files).

---

## 1. Repository & Workspace State

- **Workspace Root:** `E:\workspace\` (follow `E:\workspace\AGENTS.md` and `E:\workspace\WORKSTATIONS.md`; multi-root VS Code file: `E:\workspace\workspace.code-workspace`).
- **Active Migration Repo:** `E:\workspace\aws-setup-and-migrations` (`github.com/rajeshyukta/aws-migration-works`, branch `main`, HEAD `a49fbfb`, currently `[ahead 1]` of `origin/main` with uncommitted additions/modifications).
- **Important Git State Warning:** `E:\workspace\aws-setup-and-migrations` has uncommitted scripts & templates from this and prior sessions (listed below) plus gitignored runtime folders (`private-data/`, `temp/`, `build/`). **Never run `git clean` or `reset --hard`.**
  - **Modified tracked files:** `.gitignore`, `scripts/mail-vm/common.ps1`, `templates/Caddyfile.mail-vm`
  - **Untracked / added folders & files:** `scripts/apps-core-vm/`, `scripts/dns-vm/`, `scripts/web-1-vm/`, `scripts/mail-vm/03b-check-nmc-r2-backups.{ps1,sh}`, `scripts/mail-vm/09-deploy-reseller-mw.{ps1,sh}`, `templates/Caddyfile.{apps-core-vm,dns-vm,web-1}`, `templates/caddy/{apps-core-tls-ask.py,cconsole-hub.caddy,domains.rajesh.app.caddy,kalabhairavam.com.caddy,rajeshforbharat.com.caddy,rajeshyukta.in.caddy}`, `templates/nextdp-core-ci4-base.sql`, and this handover doc.
- **Related Source Repos Used:**
  - `E:\workspace\projects\platform\nextmanager-core` (inspected `SecretBox` & restic code)
  - `E:\workspace\projects\platform\nextdp-mail` (`a387a5f` running on Mail VM)
  - `E:\workspace\projects\platform\dns-service` (running on DNS VM)
  - `E:\workspace\projects\sites\ogcen\mrajesh.com` (`mrajesh.com` PHP 8.4 site)
  - `D:\WorkSpace\Dithim\static-website` (`dist/` built `2026-09-05`, live on Mail VM)
  - Local disk/VHD recovery folder on Windows: `D:\nmc-backup\` (`nmc-main-osdisk.vhd`, `nmc-main-files`) & `E:\nmc-backup\`.

---

## 2. Live AWS VM Topology (`private-data/vms-details.txt`)

Use `scripts/mail-vm/common.ps1` (`Get-VmTarget -Name "<Name>"`) to connect via SSH/SCP. Key references live only in gitignored `private-data/vms-details.txt`.

### A. Mail VM — `52.66.111.138` (`Name "Mail VM"`, Ubuntu `24.04.5 LTS`, AWS Lightsail)
- **Dual PostgreSQL 16 Clusters (CRITICAL):**
  - **Cluster `16/main` (Port `5432`):** Live `nextdp_mail` (currently running the **`2026-08-26`** local backup: `3` orgs, `24` domains, `28` users/mailboxes, ~`1,362` messages, `92 MiB` `/opt/nextdp/storage`), plus `cconsole_hub`.
  - **Cluster `16/nmcmain` (Port `5433`):** Loaded today from recovered Azure `nmc-main` OS disk! Holds **`nextmanager_core`** (`11` nodes, `24` DB definitions, `24` `backup_plans`, `backup_targets`). Always pass `-p 5433` when querying it!
- **NextDP Mail & Maintenance & DNS Fallback:**
  - `nextdp`, `nextdp-worker`, `nextdp-scheduler` (`:8080`, SMTP `:25/:465/:587`, IMAP `:143/:993`, POP3 `:110/:995`, ZeptoMail API outbound), `redis-server`.
  - `coredns.service` (`v1.15.0` on `172.26.3.188:53` & `127.0.0.1:53`): wildcard authoritative fallback template (`52.66.111.138` / `0 mx.nextdp.com`).
  - `caddy` (`v2.11.9`) + `nextdp-tls-ask.service` (`127.0.0.1:9055`, cap `500/hr`): serves NextDP Mail web consoles AND `https://` catch-all maintenance page (`HTTP 503`, `Retry-After: 3600`, single-line notice, no email).
- **Daily Caddy Access Logs (`07-setup-access-logs.ps1`):**
  - Trimmed ISO8601 JSON live logs in `/var/log/caddy/live/{domains,dithim,webmail,admin,superadmin,autoconfig}-access.log`.
  - Nightly `00:05 Asia/Kolkata` `nextdp-traffic-archive.timer` writes `/var/log/caddy/daily/<YYYY-MM-DD>/`; CLI report via `sudo nextdp-traffic`.
  - Downloaded `2026-11-18` snapshot locally to gitignored `temp/web-logs/2026-11-18/` + report in `temp/web-logs/2026-11-18/access-report-2026-11-18.md` (`282,621` total requests across `598` domains).
- **`dithim.com` Website (`08-deploy-dithim.ps1`):**
  - No PHP or Node.js installed on Mail VM; runs **`Python 3.12.3`** (`/usr/bin/python3`) + Caddy.
  - Static Vite `dist/` (excluding `api/*.php`) at `/opt/dithim/public`; `www.dithim.com` -> `301 https://dithim.com{uri}`; Caddy serves clean URLs (`try_files`) + custom `/404.html`.
  - `dithim-web.service` (`templates/dithim/dithim-form-backend.py`, `127.0.0.1:8090`, `www-data:ubuntu` `0640`) handles `POST /api/submit` & `POST /api/register` and saves `.txt` submissions into `/var/lib/dithim/submissions/{contact-submissions.txt,registrations.txt,daily/<YYYY-MM-DD>.txt}` (`0` real submissions as of last check; test data cleared).
- **Health check:** `scripts/mail-vm/status.ps1` (`12` systemd services).

### B. DNS VM — `52.66.165.1` (`ns1.nextdp.com`) & `52.66.25.51` (`ns2.nextdp.com`) (`Name "DNS VM"`)
- Runs `dns-service` (`:8080`, `dns_db`) + PowerDNS (`pdns`, private `172.31.14.174` / `172.31.11.141`) + Caddy (`dns.cconsole.com`, `admin.dns.cconsole.com`).
- **`nextdp` tenant** active (`23` zones in `pdns`), including 20 OGCEN zones (`mrajesh.com`, etc.), `cconsole.com`, `nextidp.com`, and **`rajeshyukta.in`** (added via `scripts/dns-vm/07-setup-rajeshyukta-in-dns.ps1`: `@ A` & `www A -> 3.6.143.66`, `@ MX -> 0 mx.nextdp.com`).
- Registrar DNSSEC for `rajeshyukta.in` was disabled (`delegationSigned: false` confirmed via `.in` RDAP), and `1.1.1.1` / `8.8.8.8` resolve cleanly.
- Health check: `scripts/dns-vm/status.ps1`.

### C. Web-1 — `3.6.143.66` (`Name "Web-1"`, AWS Lightsail `ap-south-1`)
- Runs PostgreSQL 16 (`domains_rajesh`, `postgres`, `web1_apps`), PHP 8.4-FPM (11 pools), Caddy (`23` site files in `/etc/caddy/sites-enabled/`), and static/PHP OGCEN sites + `domains-rajesh-app`.
- **`rajeshyukta.in` & `www.rajeshyukta.in`:** Configured via `templates/caddy/rajeshyukta.in.caddy` and `scripts/web-1-vm/05-setup-rajeshyukta-caddy.ps1` with Let's Encrypt SSL certificates (valid through `2027-02-17`). Serves `/srv/phpapps/mrajesh.com/current/public` directly over `unix//run/php/app-mrajesh.com.sock` (**no redirect** to `mrajesh.com`; `www.rajeshyukta.in` `301` → `https://rajeshyukta.in`).
- Health check: `scripts/web-1-vm/status.ps1`.

### D. Apps-Core-VM — `43.204.42.99` (`Name "Apps-Core-VM"`)
- PostgreSQL databases observed: `localcen_db`, `nextdp_core`, `nextidp`, `postgres`.
- DNS observed: `core.nextdp.com` and `accounts.nextdp.com` -> `43.204.42.99`.
- Deployment/realm scripts live in `scripts/apps-core-vm/` (`01`–`13`, `pull-*`, `status.ps1`).

---

## 3. R2 Backup Decryption & Verified Database Inventory (`nxtmngr-test/prod-main`)

### How `nextmanager-core` Encrypts R2 Credentials & `RESTIC_PASSWORD`
Verified directly in `E:\workspace\projects\platform\nextmanager-core`:
- **No `RESTIC_PASSWORD` in `.env` or on agent VMs (`nmc-db-1`):** `backend/pkg/restic/restic.go` injects it only in memory during jobs.
- **Storage:** PostgreSQL table `nextmanager_core.backup_targets` (`credentials_enc`, `repo_password_enc`).
- **Cipher (`backend/internal/services/apps/secretbox.go`):**
  - Master key: `JWT_SECRET` from `nmc-main`'s `/opt/nextmanager-core/.env` (saved locally in gitignored `private-data/nmc-main-env.txt`).
  - KDF: `HKDF-SHA256(ikm=JWT_SECRET, salt=None, info=b"nextmanager-core/app-env/v1", len=32)`
  - AEAD: `AES-256-GCM` on `bytea` `version(0x01) || nonce[1:13] || ciphertext+tag[13:]` with **AAD = `\x01` (`[]byte{1}`)**.

### Verification Script & Observed Results (`2026-11-19 14:05 IST`)
Run `scripts/mail-vm/03b-check-nmc-r2-backups.ps1` (never prints secrets; transfers `private-data/nmc-main-env.txt` temporarily with `0600` cleanup on `EXIT`).
- **Restic Repo:** `s3:https://b45ac3966d79a174f8d3f8590c52b59b.r2.cloudflarestorage.com/nxtmngr-test/prod-main`
- **`restic check`:** **`698 / 698` snapshots (`100.00%`) — `no errors were found`**.
- **Usability (`pg_restore --list`):** Every latest dump across all **24** databases + **`nextmanager_core`** passed `pg_restore --list` (`rc=0`, valid custom-format TOC). *(Note: in `03b`, `restic dump` logged `rc=-13` `SIGPIPE` solely because `pg_restore --list` closed stdin early after reading the TOC header.)*

#### Complete Latest-Snapshot Reference Table
**Up to `2026-11-18` (Morning IST):**
- `nextmanager_core` (`nmc.nextdp.com` platform + `/opt/nextmanager-core/.env` `3,768` B): **`5b6d4c86`** | `2026-11-18 08:00:40 IST` | `82,579,015` B | `320` TOC
- `nextdp_mail` (`nmc-db-1`): **`689c5e6a`** | `2026-11-18 08:30:40 IST` | `38,654,160` B | `204` TOC *(Mail VM currently has older `2026-08-26` DB; note R2 DB snapshot has no post-Aug `.eml`/attachment files unless on extracted Azure disk)*
- `nextdp_core` (`nmc-db-1`): **`468f8e88`** | `2026-11-18 08:45:41 IST` | `1,888,899` B | `409` TOC
- `associate_works` (`nmc-db-1`): **`5f7d81a9`** | `2026-11-18 09:00:30 IST` | `822,213` B | `746` TOC
- `afterai_work` (`nmc-db-1`): **`70b371d2`** | `2026-11-18 09:15:35 IST` | `353,562` B | `697` TOC
- `cconsole_hub` (`nmc-php-stage-1`): **`677d331a`** | `2026-11-18 09:30:34 IST` | `202,383` B | `229` TOC
- `supportfor` (`nmc-php-stage-1`): **`cdefd671`** | `2026-11-18 10:05:31 IST` | `94,659` B | `205` TOC
- `whfya` (`nmc-php-stage-1`): **`ac877370`** | `2026-11-18 10:10:32 IST` | `302,038` B | `216` TOC
- `nextbuilder` (`nmc-php-stage-1`): **`c3adcbb3`** | `2026-11-18 10:25:37 IST` | `158,131` B | `29` TOC
- `nextidp` (`nmc-db-1`): **`6cbb9b6a`** | `2026-11-18 10:25:41 IST` | `866,393` B | `447` TOC
- `withplatform` (`nmc-php-stage-1`): **`c9beb221`** | `2026-11-18 10:30:39 IST` | `140,392` B | `319` TOC
- `nextpay` (`nmc-db-1`): **`261cefc6`** | `2026-11-18 10:30:42 IST` | `124,158` B | `233` TOC
- `r1sms` (`nmc-db-1`): **`fb986270`** | `2026-11-18 10:45:32 IST` | `1,003,916` B | `295` TOC

**Latest Available for Older/Failed-on-18th Plans (`2026-11-17` / `16` / `08` IST):**
- `domains_rajesh` (`nmc-php-stage-1`): **`2e63e888`** | `2026-11-17 09:35:38 IST` | `19,317,704` B | `153` TOC
- `nareng` (`nmc-php-stage-1`): **`be62fa6e`** | `2026-11-17 09:40:36 IST` | `162,691` B | `365` TOC
- `nextdp_qaportal` (`nmc-php-stage-1`): **`bba62a9f`** | `2026-11-17 09:45:38 IST` | `141,864` B | `246` TOC
- `nextdp_rajeshyukta` (`nmc-php-stage-1`): **`31f293b4`** | `2026-11-17 09:50:39 IST` | `51,489` B | `111` TOC
- `promptation_db` (`nmc-php-stage-1`): **`63ea18e3`** | `2026-11-17 09:55:41 IST` | `66,469` B | `156` TOC
- `raiworks` (`nmc-php-stage-1`): **`2def092f`** | `2026-11-17 10:00:43 IST` | `10,745` B | `28` TOC
- `withrajesh` (`nmc-php-stage-1`): **`a0b69974`** | `2026-11-17 10:15:33 IST` | `219,676` B | `370` TOC
- `bridge` (`nmc-db-1`): **`d0f54923`** | `2026-11-17 10:20:43 IST` | `178,452` B | `222` TOC
- `blog_service` (`nmc-db-1`): **`82b28645`** | `2026-11-17 10:50:38 IST` | `205,836` B | `324` TOC
- `dns_service` (`nmc-db-1`): **`a143e215`** | `2026-11-16 10:55:44 IST` | `100,789` B | `134` TOC
- `nextlocal` (`nmc-php-stage-1`): **`807188cf`** | `2026-11-08 10:20:38 IST` | `138,564` B | `276` TOC *(plus older `nmc-db-1` `ad88ac26` `2026-10-23`)*

---

## 4. Operational Traps & Rules Remembered From This Session

1. **Caddy root-owned log trap:** Running `sudo caddy validate` on a Caddyfile with a brand-new log path creates the file as `root:root` (`0600`), causing `caddy.service` (`User=caddy`) to fail with `permission denied`. Always pre-touch + `chown caddy:caddy` logs OR validate via `sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null`.
2. **Windows `ssh` quoting in `common.ps1`:** `Invoke-VmCommand` passes the command string directly through Windows `ssh`, which strips unescaped `"`. For non-trivial bash/SQL commands, use `Invoke-VmScript` or `[Convert]::ToBase64String(...)` + `echo <b64> | base64 -d | bash`.
3. **Never touch `private-data/` or `.env*` secrets lightly:** Only access secret files when explicitly approved by Rajesh in active chat, pass via `0600` temp files deleted on `EXIT`, and never echo secret values into terminal output, logs, docs, or git.
4. **`nextmanager_core` `.env` & SecretBox coupling:** Remember `nextmanager_core` ALSO backed up `/opt/nextmanager-core/.env` inside snapshot `5b6d4c86` if needed, and any `*_enc` secret column (`databases.password_enc`, `app_env_vars.value_enc`, `mail_nodes.redis_password_enc`, `fleet_ca.key_enc`, `cache_nodes.password_enc`) in cluster `5433` unseals with that exact same `JWT_SECRET` in `private-data/nmc-main-env.txt` (via `secretbox.go`).

---

## 5. Pending Planning & Next Actions for the Next IDE

1. **Decide & execute DB restore/upgrade plan from verified R2 snapshots:**
   - **Mail VM (`52.66.111.138`):** Compare/upgrade `nextdp_mail` (`2026-08-26` → R2 `689c5e6a` `2026-11-18 08:30 IST`, checking `D:\nmc-backup` / Azure disk extract for post-Aug `/opt/nextdp/storage` files if available) and check `cconsole_hub` (`677d331a`).
   - **Apps-Core-VM (`43.204.42.99`):** Confirm/restore `nextidp` (`6cbb9b6a`), `nextdp_core` (`468f8e88`), `nextlocal` (`807188cf`) vs current state (`scripts/apps-core-vm/status.ps1`).
   - **Stand up / migrate remaining apps:** `associate_works` (`5f7d81a9`), `afterai_work` (`70b371d2`), `nextpay` (`261cefc6`), `r1sms` (`fb986270`), `blog_service` (`82b28645`), `bridge` (`d0f54923`), `dns_service` (`a143e215`), `withplatform` (`c9beb221`), `nextbuilder` (`c3adcbb3`), `withrajesh` (`a0b69974`), `promptation_db` (`63ea18e3`), `domains_rajesh` (`2e63e888`), etc.
2. **Audit & clean-commit `E:\workspace\aws-setup-and-migrations`:** Review the uncommitted VM provisioning scripts/templates (`apps-core-vm`, `dns-vm`, `web-1-vm`, `mail-vm`, `templates/`), verify zero secrets staged, commit cleanly, and push `main` (Note: `dithim-deploy` `37d3655` and `apps-core-vm` `a49fbfb` are already pushed/committed).
3. **Optional `03b` polish:** Treat `restic_rc == -13` (`SIGPIPE`) in `scripts/mail-vm/03b-check-nmc-r2-backups.sh` as expected when `pg_restore --list` closes stdin early, and optionally add `tlm-audit-scanner` / `ct-fingerprint` to `templates/caddy/nextdp-traffic-archive.py` `SCANNER_UAS`.
