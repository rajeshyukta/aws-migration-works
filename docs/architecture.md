# Architecture: Azure NMC Fleet → Standalone AWS Lightsail

> **History (written 2026-11-18 for the first VM).** The current state of all 4 VMs is in [`vms-setup-and-services-and-all-info.md`](vms-setup-and-services-and-all-info.md). Changes since this was written: `nextdp_mail` was moved to the R2 snapshot + AWS delta on 2026-11-20 ([`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md)). `ns1/ns2.nextdp.com` now point to the DNS VM, so the CoreDNS section below is a fallback with no public traffic, and port 53 is closed. The Mail VM firewall allows only the mail/web ports. CConsole Hub moved to Web-1. Each VM has its own off-site backup.

## Context

The Azure NextManager Core (`nmc-*`) fleet (`nmc-main`, `nmc-db-1`, `nmc-db-2`, `nmc-cache-1`, `nmc-dns-1/2`, `nmc-idp-1`, `nmc-apps-1`, `nmc-mail-1`, `nmc-php-stage-1`) was stopped when the Azure subscription was disabled pending a support ticket.

To keep essential services operational without waiting on Azure or standing up a full NextManager Core control plane (`nmc-main`) immediately, services are migrated as **standalone single-VM deployments** on AWS Lightsail:
- **No `nmc-main` agent**: Services are deployed directly from workstation build scripts over SSH/SCP.
- **No shared `nmc-db-1` / `nmc-cache-1`**: Each VM runs its own local PostgreSQL 16 (`127.0.0.1:5432`) and Redis 7 (`127.0.0.1:6379`) with random generated credentials in the VM's `.env`.
- **Reverse Proxy & TLS**: Caddy 2 runs on the VM with automatic Let's Encrypt HTTPS certificates.

If Azure recovers or once core services are stabilized, either we can re-adopt these VMs into a fresh `nmc-main` later or migrate data cleanly via `pg_dump` / `pg_restore`.

---

## 1. NextDP Mail (`52.66.111.138`)

### Stack on VM (`Ubuntu 24.04.5 LTS`, `1.9 GiB RAM`, `58 GiB disk`)
- **Swap**: `2 GiB` `/swapfile` (`vm.swappiness=10`)
- **PostgreSQL 16**: local database `nextdp_mail`, role `nextdp_mail`, `127.0.0.1:5432`
- **Redis 7**: local `127.0.0.1:6379` with `requirepass` (`CACHE_PREFIX=raimail_`)
- **Caddy 2**:
  - `mail.nextdp.com`, `mail.rajesh1.com` → Webmail SPA + `/api/{sse,auth,v1/totp,v1/auth,webmail,health}/*`
  - `admin.mail.nextdp.com`, `admin.mail.rajesh1.com` → Admin SPA + `/api/{sse,auth,v1/totp,v1/auth,admin,domains,users}/*`
  - `super-admin.mail.nextdp.com`, `super-admin.mail.rajesh1.com` → Super Admin SPA + `/api/{auth,v1/totp,v1/auth,super-admin,organizations,health}/*`
  - `autoconfig.nextdp.com` → Mail client autoconfig XML
  - `www.dithim.com` → `301` redirect to `https://dithim.com{uri}`
  - `dithim.com` → `/opt/dithim/public` clean-URL static server (`try_files {path} {path}.html {path}/index.html =404`, `*.html` → extensionless `301`, custom `/404.html`), `/api/*` → `127.0.0.1:8090`
  - `https://` catch-all + `nextdp-tls-ask.service` (`127.0.0.1:9055`) → On-demand Let's Encrypt TLS + `/opt/nextdp/maintenance/index.html` (`HTTP 503`, `Retry-After: 3600`) for all parked/migrating domains (`*`)
- **Dithim Form Backend (`dithim-web.service`)**:
  - Uses the VM's built-in Python `3.12.3` stdlib (`ThreadingHTTPServer` on `127.0.0.1:8090`, no PHP/Node needed).
  - Handles `POST /api/submit` (and `/api/submit.php`) and `POST /api/register` (and `/api/register.php`) with per-IP rate limiting + honeypot filtering, persisting entries cleanly into `/var/lib/dithim/submissions/{contact-submissions,registrations}.txt` and `/var/lib/dithim/submissions/daily/<YYYY-MM-DD>.txt`.
- **Traffic Access Logging (`nextdp-traffic-archive.timer`)**:
  - Caddy writes trimmed ISO8601 JSON logs into `/var/log/caddy/live/{domains,dithim,webmail,admin,superadmin,autoconfig}-access.log` (`50 MiB` roll, `72h` window, drops `resp_headers`, `request>tls`, `Sec-Ch-Ua*`).
  - Nightly `00:05 Asia/Kolkata` systemd timer splits & compresses dated logs into `/var/log/caddy/daily/<YYYY-MM-DD>/` (`all-domains-<DATE>.jsonl.gz`, `mail-services-<DATE>.jsonl.gz`, `by-domain/<domain>-<DATE>.jsonl.gz`, `summary-<DATE>.{csv,json}`) with `30`-day retention. Live CLI: `nextdp-traffic`.
- **Authoritative DNS (`coredns.service`, CoreDNS v1.15.0)**:
  - Binds `172.26.3.188:53` + `127.0.0.1:53` (`systemd-resolved` stays untouched on `127.0.0.53:53`)
  - Stateless `template` responder for domains pointed to `ns1.nextdp.com` / `ns2.nextdp.com`: `@`/`www`/`*` `A -> 52.66.111.138`, `MX -> 0 mx.nextdp.com`, `NS -> ns1/ns2.nextdp.com`, `SOA -> ns1.nextdp.com. dns-admin.nextdp.com.`, `NOERROR` NODATA on `AAAA`/`CAA`/`TXT`
- **NextDP Mail Binary (`/opt/nextdp/bin/nextdp`)**:
  - `nextdp.service`: HTTP API (`127.0.0.1:8080`) + SMTP (`:25`, `:465`, `:587`) + IMAP (`:143`, `:993`) + POP3 (`:110`, `:995`)
  - `nextdp-worker.service`: Queue worker (`--queues=default,emails,notifications --workers=4`)
  - `nextdp-scheduler.service`: Cron scheduler
  - `nextdp-certwatch.path` + `nextdp-certreload.service` (`/usr/local/bin/nextdp-certsync`): syncs Caddy's Let's Encrypt cert for `mail.nextdp.com` to `/opt/nextdp/config/tls/` so SMTP/IMAP/POP3 listeners renew TLS automatically
  - `nextdp-diskcheck.timer` + `harden-logging`: journald capped at `500M`, rsyslog deduplication dropped for `nextdp*`, hourly disk space alert at `85%`
- **Outbound Email Transport**:
  - **ZeptoMail** (configured per-org/system in PostgreSQL `nextdp_mail`, or fallback SMTP relay on `:587`). Note: AWS Lightsail blocks outbound TCP `:25` by default; ZeptoMail uses HTTPS API (`api.zeptomail.*`) or port `587` (`smtp.zeptomail.*`), so outbound sending is unaffected.
- **Recovery & Live State**:
  - `restic 0.19.1` (`/usr/local/bin/restic`, SHA256-verified) + `python3-boto3` for inspecting and restoring the `nextdp_mail` PostgreSQL backup from Cloudflare R2 (`nxtmngr-test`).
  - `nxtmngr-test/prod-main` (`2026-11-18` snapshots) is preserved intact on R2 pending recovery of `RESTIC_PASSWORD` from stopped Azure `nmc-main` (`40.80.95.1`, local `nextmanager_core` PostgreSQL `backup_targets.repo_password_enc`). Meanwhile, the VM is live on the restored `2026-08-26` backup (`3` orgs, `24` domains, `28` users/mailboxes, `1,360` messages, `3,598` raw emails, `136` attachments, `92 MiB` `/opt/nextdp/storage`, `SMTP_DOMAIN=mx.nextdp.com`).
