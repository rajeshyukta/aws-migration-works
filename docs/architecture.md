# Architecture: Azure NMC Fleet → Standalone AWS Lightsail

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
- **NextDP Mail Binary (`/opt/nextdp/bin/nextdp`)**:
  - `nextdp.service`: HTTP API (`127.0.0.1:8080`) + SMTP (`:25`, `:465`, `:587`) + IMAP (`:143`, `:993`) + POP3 (`:110`, `:995`)
  - `nextdp-worker.service`: Queue worker (`--queues=default,emails,notifications --workers=4`)
  - `nextdp-scheduler.service`: Cron scheduler
  - `nextdp-certwatch.path` + `nextdp-certreload.service` (`/usr/local/bin/nextdp-certsync`): syncs Caddy's Let's Encrypt cert for `mail.nextdp.com` to `/opt/nextdp/config/tls/` so SMTP/IMAP/POP3 listeners renew TLS automatically
  - `nextdp-diskcheck.timer` + `harden-logging`: journald capped at `500M`, rsyslog deduplication dropped for `nextdp*`, hourly disk space alert at `85%`
- **Outbound Email Transport**:
  - **ZeptoMail** (configured per-org/system in PostgreSQL `nextdp_mail`, or fallback SMTP relay on `:587`). Note: AWS Lightsail blocks outbound TCP `:25` by default; ZeptoMail uses HTTPS API (`api.zeptomail.*`) or port `587` (`smtp.zeptomail.*`), so outbound sending is unaffected.
- **Recovery Tools**:
  - `restic 0.19.1` (`/usr/local/bin/restic`, SHA256-verified) + `python3-boto3` for inspecting and restoring the `nextdp_mail` PostgreSQL backup from Cloudflare R2 (`nxtmngr-test`).
