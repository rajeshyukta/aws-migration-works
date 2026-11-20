# AWS VMs: setup, services and all info (reference)

One place to look up what runs where on the AWS servers that replaced the Azure/NMC fleet after the Azure suspension (18 Nov 2026).

- **Last verified:** 2026-11-20 ~12:30 IST, from read-only checks on all 4 VMs plus DNS and port checks from the owner PC (Mail VM firewall re-checked 12:32 IST after the change). Re-check before relying on a number.
- **No secrets in this file.** It names *where* secrets are, never their values.
- **Keep it current:** update this file whenever a VM, app, domain, database, port or backup changes, in the same commit as the change. To refresh the facts, run `scripts/vm-inventory.sh` (read-only) on each VM (section 11).

---

## 1. At a glance

| VM (name in `private-data/vms-details.txt`) | Public IP | AWS | Size | Region / AZ | Role |
|---|---|---|---|---|---|
| **Mail VM** | `52.66.111.138` | Lightsail `NextDP-Mail-VM` (private `172.26.3.188`) | t3.small: 2 vCPU, 1.9 GB RAM + 2 GB swap, 58 GB disk (13% used) | ap-south-1a | NextDP Mail (SMTP/IMAP/POP3 + 3 web consoles), dithim.com, catch-all maintenance page |
| **Web-1** | `3.6.143.66` | Lightsail (private `172.26.9.186`) | t3.small: 2 vCPU, 1.9 GB + 2 GB swap, 58 GB (11%) | ap-south-1a | PHP 8.4 + static sites (OGCEN, domains app, CConsole Hub, ~35 domains) |
| **Apps-Core-VM** | `43.204.42.99` | EC2 `i-0eee8167ad7ff9be0` (private `172.31.2.129`) | t3.large: 2 vCPU, 7.8 GB + 2 GB swap, 48 GB (11%) | ap-south-1b | Next iDP (`accounts.<brand>`), NextDP Core (incl. brand hosts like `admin/console.localcen.com`). LocalCen moved to LocalCen-1-VM 2026-11-20 |
| **LocalCen-1-VM** | `3.111.132.3` (Elastic IP) | EC2 `i-007e720a8c578aad7` (private `172.31.8.71`) | t2.medium: 2 vCPU, 3.9 GB + 2 GB swap, 48 GB gp3 | ap-south-1b | LocalCen (dedicated, customer domains via on-demand TLS); NextBuilder later. **Live since 2026-11-20** for the cconsole.com hosts (section 5b) |
| **DNS VM** | `52.66.165.1` (**ns1**) + `52.66.25.51` (**ns2**) | EC2 `i-0fe9b807d4d2fad7d` (2 private IPs `172.31.14.174`, `172.31.11.141`) | t3.small: 2 vCPU, 1.9 GB + 2 GB swap, 29 GB (17%) | ap-south-1b | PowerDNS authoritative `ns1/ns2.nextdp.com` + dns-service UI/API |

All four: Ubuntu 24.04.5 LTS, timezone UTC, PostgreSQL 16.15 (localhost only), Caddy v2.11.9 (automatic HTTPS), Amazon SSM agent.

**Not on AWS (still Azure, disabled, unreachable):** `nmc.nextdp.com` (`40.80.95.1`), `s3.nextdp.com` (`20.198.69.133`), Associate Works / AW Vault (`associate.works` does not resolve), and every other old fleet VM. Their DNS records still point at Azure.

---

## 2. Access

| Item | Value |
|---|---|
| SSH user | `ubuntu` on all 4 |
| SSH key | Path per VM in `private-data/vms-details.txt` (gitignored). Currently `private-data/dithim-aws.pem` for all 4 |
| PowerShell helper | `. .\scripts\mail-vm\common.ps1; $vm = Get-VmTarget -Name "Web-1"` then `Invoke-VmScript -Vm $vm -LocalScriptPath <file.sh>` or `Invoke-VmCommand` |
| Quoting rule | Windows `ssh` strips `"`. For anything non-trivial, write a `.sh` and use `Invoke-VmScript`, or `base64` the script |
| Remote stderr | PowerShell 5.1 treats remote stderr as an error. Scripts start with `exec 2>&1` |
| Status scripts | `scripts/<vm>/status.ps1` (mail-vm, web-1-vm, apps-core-vm, dns-vm) |
| Off-site backup status | `sudo nextdp-offsite-backup status` on the Mail VM and Web-1 |
| AWS CLI | Installed on the owner PC (v2). Session expires: run `aws login` first. Account `147248321109`, region `ap-south-1`. Currently the **root** user (see section 10) |

---

## 3. Mail VM (`52.66.111.138`)

**Services (systemd):** `nextdp` (`serve --mode=all`: HTTP API `:8080`, SMTP `:25/:465/:587`, IMAP `:143/:993`, POP3 `:110/:995`), `nextdp-worker`, `nextdp-scheduler`, `nextdp-tls-ask` (`127.0.0.1:9055`), `caddy`, `redis-server` (127.0.0.1), `coredns` (`172.26.3.188:53`, `127.0.0.1:53`), `dithim-web` (`127.0.0.1:8090`), `postgresql@16-main` (`:5432`), `postgresql@16-nmcmain` (`:5433`, recovered NMC DB). Timers: `nextdp-diskcheck`, `nextdp-traffic-archive` (00:05 IST), `nextdp-offsite-backup`, `nextdp-offsite-verify`. PHP-FPM is **stopped and disabled** since the hub moved to Web-1.

**Domains (Caddy):** `mail.nextdp.com`, `admin.mail.nextdp.com`, `super-admin.mail.nextdp.com`, `mail.rajesh1.com`, `admin.mail.rajesh1.com`, `super-admin.mail.rajesh1.com`, `autoconfig.nextdp.com`, `dithim.com`, `www.dithim.com` (→ 301), plus an **on-demand TLS catch-all** maintenance page (`503`) for any domain pointed at this IP (guarded by `nextdp-tls-ask`, max 500 certs/hour).

**Databases (`16/main`, :5432):** `nextdp_mail` (131 MB; R2 snapshot + AWS delta since 2026-11-20), `nextdp_mail_aug_old` (38 MB; rollback copy, drop after 27 Nov), `cconsole_hub` (9 MB; old hub install, delete after 4 Dec). **`16/nmcmain`** (:5433): `nextmanager_core` (497 MB; recovered from Azure, holds the sealed NMC R2 credentials; autostart manual).

**Files:** app `/opt/nextdp/{bin,config,storage,web}`, mail files `/opt/nextdp/storage/uploads/{emails,attachments}`, dithim site `/opt/dithim/public`, form submissions `/var/lib/dithim/submissions/`, Caddy access logs `/var/log/caddy/live/` + daily archive `/var/log/caddy/daily/`.

**Mail facts:** 3 orgs, 39 domains, 43 mailboxes. Outbound mail goes through the **ZeptoMail API** (`api.zeptomail.in`). AWS blocks outbound port 25 from this VM, so direct SMTP delivery is impossible. Super admin: `admin@rajesh1.com`.

**Firewall:** Lightsail firewall (set 2026-11-20 by `scripts/mail-vm/18-lightsail-firewall.ps1`): **tcp 22, 25, 80, 443, 465, 587, 143, 993, 110, 995 + udp 443 only**, any source, IPv4 + IPv6. Checked from outside: 53, 8080, 8090, 5432, 6379, 9055 closed. Old "all ports" rule saved in `temp/lightsail-ports-NextDP-Mail-VM-20261120T070141Z.json`. `ufw` and `fail2ban` are **inactive** on the VM itself (see section 10). CoreDNS still listens on `172.26.3.188:53` but is unreachable from outside.

**Secrets (paths):** `/opt/nextdp/config/.env` (app; `MIGRATION_ENCRYPTION_KEY` must never change), `/etc/nextdp-backup/restic.env`, `/root/.cconsole-hub-db-pass` (old hub), `/srv/phpapps/cconsole-hub/ci4-app/.env` (old hub).

**Scripts / docs:** `scripts/mail-vm/01`–`18` (18 = Lightsail firewall), [`mail-vm-runbook.md`](mail-vm-runbook.md), [`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md), [`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md). Source repo: `projects/platform/nextdp-mail` (`raiworks/nextdp-mail`, deployed `a387a5f`).

---

## 4. Web-1 (`3.6.143.66`)

**Services:** `caddy`, `php8.4-fpm` (12 pools, one per app, user `webapps` unless noted), `postgresql@16-main`, `redis-server` (127.0.0.1, password, 64 MB LRU; added 2026-11-20 for the hub), `fail2ban`. Timers: `daiskills-mail`, `domains-rajesh-check`, `domains-rajesh-digest`, `web1-diskcheck`, `nextdp-offsite-backup` (02:45 IST), `nextdp-offsite-verify` (Sun 04:30 IST). Cron: `/etc/cron.d/cconsole-hub`.

**PHP apps (`/srv/phpapps/<site>`, pool `app-<site>`):** afteraiwork.com, cconsole-hub (see below), daiskills.com, dev.srikalabhairavam.com, domains.rajesh.app (`domains.rajesh.in` with a local-CA cert + `domains.rajesh1.com`), localcen.com, mrajesh.com (also serves `rajeshyukta.in`), navduta.com, nextdigital.in, nextskillclub.com, organicgrowth.center, proseva.org, softskills.training. Release-based apps use `releases/<ts>` + `current` + `shared/`.

**Static sites (`/srv/static/<site>`):** dev.haindaviswaraj.org.in, dev2/dev8/dev9/dev10.srikalabhairavam.com, forbharat.in, haindaviswaraj.org.in, jyothularajesh.com, kalabhairavam.com, rajeshforbharat.com, srikalabhairavam.com.

**All Caddy hostnames (24 site files):** admin.hub.cconsole.com, afteraiwork.com, api.hub.cconsole.com, daiskills.com, dev.haindaviswaraj.org.in, dev.srikalabhairavam.com, dev2/8/9/10.srikalabhairavam.com, docs.hub.cconsole.com, domains.rajesh.in, domains.rajesh1.com, forbharat.com/.in/.org, haindaviswaraj.org.in, hub.cconsole.com, jyothularajesh.com, kalabhairavam.com, localcen.com, mrajesh.com, navduta.com, nextdigital.in, nextskillclub.com, ogcen.com, organicgrowth.center, proseva.org, rajeshforbharat.com, rajeshyukta.in, sandbox.hub.cconsole.com, softskills.training, srikalabhairavam.com/.in, plus their `www.` variants.

**CConsole Hub** (moved from the Mail VM 2026-11-20, fresh install): `/srv/phpapps/cconsole-hub/{ci4-app,frontend/admin/dist,frontend/tenant/dist}`, hosts `hub.`, `admin.hub.`, `api.hub.`, `sandbox.hub.`, `docs.hub.cconsole.com`, API base path `/v1/...`. **Not usable yet**: ZeptoMail + ResellerClub keys are placeholders and there is no super admin (see [`TODO.md`](TODO.md)). Details: [`cconsole-hub-web-1.md`](cconsole-hub-web-1.md).

**Databases:** `domains_rajesh` (115 MB, `whois_history` ~50k rows), `cconsole_hub` (9 MB, fresh), `web1_apps` (7.5 MB, **empty**: spare shared DB for role `webapps` from `01-server-setup.sh`, kept on purpose). SQLite: `daiskills.com/shared/enquiries.sqlite`, `organicgrowth.center/data/ogcen.sqlite`, `nextdigital.in/data/nextdigital.sqlite`, `proseva.org/data/proseva.sqlite`.

**Firewall:** `ufw` active (22/80/443 only), `fail2ban` active. Reachable from the internet: 22, 80, 443.

**Secrets (paths):** `/root/.web1-secrets.env`, `/root/.web1-domains-secrets.env`, `/root/.web1-redis-pass`, `/root/.cconsole-hub-db-pass`, `/etc/nextdp-backup/restic.env`, app `.env` files: `cconsole-hub/ci4-app/.env`, `domains.rajesh.app/.env`, `localcen.com/shared/.env`, `mrajesh.com/shared/.env`, `nextdigital.in/app/.env`, `organicgrowth.center/app/.env`, `proseva.org/app/.env`. Local CA for `domains.rajesh.in`: `/etc/caddy/certs/` (CA cert copy in `private-data/domains-rajesh-in-local-ca.crt`).

**Scripts / docs:** `scripts/web-1-vm/01`–`07`, [`web-1-offsite-backup.md`](web-1-offsite-backup.md). Source repos: `projects/sites/ogcen` (`raiworks/ogcen-works`), `projects/products/domains-rajesh-app` (`rajeshyukta/rajesh-domains`), `projects/platform/reseller-mw` (`raiworks/cconsole-hub`), `projects/products/afterai-work`.

---

## 5. Apps-Core-VM (`43.204.42.99`)

**Services (Go apps, reverse-proxied by Caddy):**

| App | Units | Port | Hostnames | Dir |
|---|---|---|---|---|
| **Next iDP** | `nextidp`, `nextidp-worker`; timers `nextidp-mail-prune`, `nextidp-contact-prune`, `nextidp-audit-prune` | `:8080` | `nextidp.com`, `www.nextidp.com`, `admin.nextidp.com`, and **any `accounts.<brand>`** (e.g. `accounts.nextdp.com`) via the on-demand TLS catch-all | `/opt/nextidp` |
| **NextDP Core** | `nextdp`, `nextdp-worker`, `nextdp-scheduler` | `:8090` | `core.nextdp.com` (+ catch-all routes) | `/srv/apps/nextdp` (`current` → `20261119T040820`) |
| TLS ask | `apps-core-tls-ask` | `127.0.0.1:8099` | guards on-demand certificates | `templates/caddy/apps-core-tls-ask.py` |

Also: `redis-server` (127.0.0.1), `postgresql@16-main`, timer `apps-core-diskcheck`, `fail2ban`.

**Databases:** `nextidp` (13 MB, owner `nextidp`), `nextdp_core` (10 MB, `nextdp_core`). (`localcen_db` dropped 2026-11-20 after the move; final dump in `D:\nmc-backup\apps-core\localcen-retired-20261120T085819Z\`.) **Fresh setups**: the old Azure data is in R2 (`nextidp` `6cbb9b6a`, `nextdp_core` `468f8e88`, `nextlocal` `807188cf`) if it is ever needed.

**Firewall:** `ufw` active (22/80/443), `fail2ban` active. Ports 8080/8090/8092 listen on all interfaces but are **not** reachable from outside (checked).

**Secrets (paths):** `/root/.apps-core-secrets.env`, `/root/.nextidp-admin-secrets.env`, `/root/.nextidp-cconsole-dns.env`, `/root/.nextdp-core-admin-secrets.env`, `/root/.nextdp-core-idp.env`, `/root/.nextdp-brand-idp.env`, `/srv/apps/nextdp/shared/.env`, `/srv/apps/localcen/shared/.env`, Next iDP env under `/opt/nextidp`. PC copies (pulled by `scripts/apps-core-vm/pull-*.ps1`): `private-data/aws-vm-nextidp.env`, `aws-vm-nextdp-core.env`, `nextidp-admin.env`, `nextdp-core-admin.env`, `*-realm.env`, `nextidp-accounts.txt`, `nextdp-core-accounts.txt`, `nextidp-s3.env`.

**Backups:** ❌ **none yet** (see section 8).

**Scripts / docs:** `scripts/apps-core-vm/01`–`11`, `pull-*`, [`realm-nextdp-core.md`](realm-nextdp-core.md), [`realm-ndp-nextdp.md`](realm-ndp-nextdp.md). Repos: `projects/platform/nextidp` (`raiworks/nextidp`), `projects/platform/nextdp-core` (`rajeshyukta/nextdp`), `projects/platform/localcen` (`raiworks/localcen`).

---

## 5b. LocalCen-1-VM (`3.111.132.3`)

Dedicated VM for LocalCen, so it can be resized with sales without touching Next iDP / NextDP Core. NextBuilder (website builder) will join later. Security group `sg-00637efb7a2d3b0d2`: tcp 22/80/443 + udp 443. Inside: `ufw` (same ports) + `fail2ban`.

**Status 2026-11-20:** **live** for `localcen.cconsole.com` and `admin.localcen.cconsole.com` (DNS switched by owner, Let's Encrypt certs, 200 from the internet, API 401 without login as expected). `console.localcen.com` and `admin.localcen.com` are explicit **LocalCen console aliases** (not NextDP Core brands: no row in `nextdp_core` or `nextidp` mentions `localcen.com`). They still point to Apps-Core-VM, which runs the **old LocalCen copy** until they move.

| Item | Value |
|---|---|
| App | `/srv/apps/localcen/{releases,current,shared}`, user `webapps`, units `localcen`, `localcen-worker`, timer `localcen-cleanup` (03:45 UTC). Port `8092` (kept from Apps-Core) |
| Hostnames | `localcen.cconsole.com`, `console.localcen.com` (tenant console), `admin.localcen.cconsole.com`, `admin.localcen.com` (admin console), plus **every customer domain** through the `https://` catch-all with **on-demand TLS**. The ask goes to LocalCen `/internal/tls-allow`, so no per-domain config is needed. Customer DNS is checked by LocalCen against `LOCAL_HOST_SERVER_IPS=3.111.132.3` |
| Caddy | `templates/Caddyfile.localcen-1-vm` (dedicated mode from `localcen/deploy/caddy/Caddyfile`). There is no shared-Caddy member sync, so `CADDY_SYNC_SPOOL` was removed from `.env` |
| Database | PostgreSQL 16.15 local: `localcen_db` (owner `localcen_u`), copied from Apps-Core-VM 2026-11-20 (46 tables, 54 migrations, 3 disabled shared domains `gramam.in`, `pattanam.in`, `constituency.in`, 0 tenants). No Redis (LocalCen uses the DB for sessions/queue and in-memory cache) |
| Secrets (paths) | `/root/.localcen-1-secrets.env` (DB password), `/srv/apps/localcen/shared/.env` (copied from Apps-Core; DB password and server IP changed) |
| Backups | ❌ none yet. **Needed before the first customer** (TODO) |
| Scripts | `scripts/localcen-1-vm/01-server-setup`, `02-copy-localcen-data` (one-time), `03-deploy-localcen` (build + deploy, repeatable), `04-setup-caddy` (`-Apply` after DNS) |
| Repo | `projects/platform/localcen` (`raiworks/localcen`, deployed `3a3f41b`) |

## 6. DNS VM (`52.66.165.1` ns1 + `52.66.25.51` ns2)

**Services:** `pdns` (PowerDNS authoritative, `:53` on both private IPs), `dns-service` (`:8080`, behind Caddy) + `dns-service-scheduler`, `caddy` (`dns.cconsole.com`, `admin.dns.cconsole.com`), `postgresql@16-main`, timer `dns-vm-diskcheck`, `fail2ban`.

**Databases:** `pdns` (8 MB, owner `pdns`; the zone data PowerDNS serves), `dns_db` (9 MB, owner `dns_u`; dns-service tenants/users).

**Zones served (23, tenant `nextdp`):** afteraiwork.com, cconsole.com, daiskills.com, forbharat.com, forbharat.in, forbharat.org, haindaviswaraj.org.in, jyothularajesh.com, kalabhairavam.com, localcen.com\*, mrajesh.com, navduta.com, nextdigital.in, nextidp.com, nextskillclub.com, ogcen.com, organicgrowth.center, proseva.org, rajeshforbharat.com, rajeshyukta.in, softskills.training, srikalabhairavam.com, srikalabhairavam.in.
\* `localcen.com` is delegated to **Cloudflare** at the registrar, so its PowerDNS zone is not used publicly.

**Firewall:** `ufw` active (22, 53 tcp/udp, 80, 443), `fail2ban` active.

**Secrets (paths):** `/root/.dns-vm-secrets.env`, `/root/.dns-nextdp-secrets.env`, `/srv/apps/dns-service/shared/.env`. PC copies: `private-data/dns-nextdp.env`, `dns-vm-accounts.txt`, `dns-idp.txt`.

**Backups:** ❌ **none yet**. Losing `pdns` means losing every zone above.

**Scripts:** `scripts/dns-vm/`. Repo: `projects/platform/dns-service` (`RajeshYukta/dns-service`).

---

## 7. DNS: where each domain is managed

| Managed at | Domains | Notes |
|---|---|---|
| **Cloudflare** (`kai`/`rachel.ns.cloudflare.com`) | `nextdp.com`, `localcen.com`, `dithim.com`, `rajesh1.com` (and others not on ns1/ns2) | `ns1.nextdp.com` / `ns2.nextdp.com` A records (glue) live in the Cloudflare `nextdp.com` zone. MX `nextdp.com` → `0 mx.nextdp.com` |
| **PowerDNS on the DNS VM** (`ns1/ns2.nextdp.com`) | The 23 zones in section 6, e.g. `cconsole.com`, `nextidp.com`, `mrajesh.com`, `rajeshyukta.in` | Edit through dns-service (`dns.cconsole.com`, `admin.dns.cconsole.com`) |

**Key records (checked via 1.1.1.1):**

| Name | → | VM |
|---|---|---|
| `mx.nextdp.com`, `mail.nextdp.com`, `dithim.com` | 52.66.111.138 | Mail VM |
| `core.nextdp.com`, `accounts.nextdp.com`, `nextidp.com`, `console.localcen.com` | 43.204.42.99 | Apps-Core-VM |
| `localcen.com`, `hub.cconsole.com` (+ `api/admin/docs/sandbox.hub`) | 3.6.143.66 | Web-1 |
| `ns1.nextdp.com`, `dns.cconsole.com` | 52.66.165.1 | DNS VM |
| `ns2.nextdp.com` | 52.66.25.51 | DNS VM |
| `nmc.nextdp.com`, `s3.nextdp.com` | Azure IPs | dead (Azure disabled) |

Mail VM's CoreDNS (wildcard fallback answering `A`→Mail VM, `MX`→`mx.nextdp.com`) dates from before the DNS VM existed. Since `ns1/ns2` now point to the DNS VM, it probably gets no public queries. Verify before removing it.

---

## 8. Backups

| VM | Off-site backup | Repo (bucket `nxtmngr-test` on Cloudflare R2) | Schedule | Restore test | Password file (PC) |
|---|---|---|---|---|---|
| Mail VM | ✅ | `aws-mail-vm/` (id `dc5ab80661`) | 02:30 IST nightly | Sun 04:00 IST, `nextdp_mail` | `private-data/mail-vm-offsite-backup.env` |
| Web-1 | ✅ | `aws-web-1/` (id `f7fa98a985`) | 02:45 IST nightly | Sun 04:30 IST, `domains_rajesh` | `private-data/web-1-offsite-backup.env` |
| Apps-Core-VM | ❌ | — | — | — | — |
| DNS VM | ❌ | — | — | — | — |
| LocalCen-1-VM | ❌ (before first customer) | planned `aws-sites-1/` → `aws-localcen-1/` | — | — | — |

- Same tool on both (`/usr/local/sbin/nextdp-offsite-backup`, source `templates/backup/nextdp-offsite-backup.sh`, per-VM `backup.conf`). It dumps **every** DB on the VM, makes safe SQLite copies, backs up files and configs, keeps 14 daily / 8 weekly / 12 monthly, and mails `rajesh@nextdp.com` on failure. Web-1 mails through the Mail VM's private IP `172.26.3.188:25`.
- **Old NMC/Azure backups** (read-only reference): R2 `nxtmngr-test/prod-main/`, 698 snapshots, latest per DB on 16–18 Nov (full table in [`session-handover-2026-11-19.md`](session-handover-2026-11-19.md) section 3). Unlocking needs `JWT_SECRET` (`private-data/nmc-main-env.txt`) plus the NMC DB on the Mail VM `:5433`. Do not write to `prod-main/`.
- **Local copies on the owner PC:** `D:\nmc-backup\mail-vm\` (mail cutover backups, Azure mail storage, R2 dumps `r2-689c5e6a`, `r2-677d331a`), `E:\nmc-backup\data\nextmanager_core-20261119-1332.dump`.

---

## 9. Secrets: where they live (no values)

| What | Where | Copies outside AWS |
|---|---|---|
| SSH key for all 4 VMs | `private-data/dithim-aws.pem` | ⚠️ only this PC |
| Off-site backup passwords (Mail VM, Web-1) | `private-data/*-offsite-backup.env` + `/etc/nextdp-backup/restic.env` on each VM | ⚠️ only this PC. **Not recoverable if lost** |
| R2 access key | `private-data/r2.env` (+ `projects/platform/rapidgo/private-data/r2-live.env`) + each VM's `restic.env` | Can be re-created in the Cloudflare dashboard. It can also delete backups, so treat it as sensitive |
| NMC master key (`JWT_SECRET`) | `private-data/nmc-main-env.txt`, `D:\nmc-backup\nmc-main-files\...\.env` | ⚠️ this PC |
| App `.env` files and `/root/.*` secret files | On each VM (paths in sections 3–6). Some copied to `private-data/` by the `pull-*` scripts | In each VM's off-site backup (Mail VM, Web-1 only) |
| ZeptoMail / Zoho keys | `private-data/zoho-cpass-mail-api-*.txt`, VM `.env` files | — |

**AW Vault is down** (it ran on Azure). Until it is back, keep a copy of the `private-data/` secrets in a **password manager** (Bitwarden/1Password) plus an **offline copy** (USB/printout), and copy them to the laptop. Do not use the Google Drive sync folder.

---

## 10. Known risks and suggested fixes (priority order)

1. **No backup for Apps-Core-VM and DNS VM.** They hold the new IdP, NextDP Core, LocalCen and all PowerDNS zones. Fix: same backup tool, repos `aws-apps-core/` and `aws-dns-vm/` (about 10 min each).
2. **Secrets only on one PC** (SSH key, backup passwords). Fix: password manager + offline copy + laptop (section 9).
3. ~~Mail VM exposed `:8080`~~ **Fixed 2026-11-20**: the Lightsail firewall now allows only the mail/web ports. Still open: `fail2ban` is off on the Mail VM (SSH and SMTP AUTH brute force), and SSH (22) is open to any IP on all VMs.
4. **ns1 and ns2 are the same VM.** If the DNS VM is down, every zone on it stops resolving. Fix: a second small VM in another AZ (or a secondary DNS provider via AXFR) for ns2.
5. **Single AWS account for everything.** The Azure lesson. Backups are already on Cloudflare R2, a different provider. Keep it that way, and keep billing/contact details current.
6. **`nmcmain` cluster on the Mail VM** (497 MB, port 5433) uses RAM on a 1.9 GB VM. Stop it when not needed: `sudo pg_ctlcluster 16 nmcmain stop`. It is only needed to unseal the old R2 `prod-main` repo.
7. ~~Workspace `AGENTS.md` §4 lists the Azure fleet as live~~ **Fixed 2026-11-20**: new §4.0 lists these VMs and points here. `README.md` and `WORKSTATIONS.md` have status notes.
8. **Stale DNS**: `nmc.nextdp.com` and `s3.nextdp.com` still point to Azure. Remove or repoint them when their replacements exist.
9. **AWS CLI runs as the account root user** (`aws sts get-caller-identity` → `:root`). Fix: create an IAM user/role with only Lightsail/EC2 rights for daily work, enable MFA on root, and keep root for billing only.

---

## 11. How to refresh this file

```powershell
# from E:\workspace\aws-setup-and-migrations (read-only on the VMs)
. .\scripts\mail-vm\common.ps1
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Resolve-Path .\scripts\vm-inventory.sh)).Replace("`r`n","`n")))
foreach ($n in 'Mail VM','Web-1','Apps-Core-VM','DNS VM') { $vm = Get-VmTarget -Name $n; cmd /c "ssh -i `"$($vm.SshKey)`" -o BatchMode=yes $($vm.Target) `"echo $b64 | base64 -d | bash`" > temp\inv-$($n -replace '\s','-').txt 2>&1" }
```
Then compare `temp/inv-*.txt` (scratch, gitignored) with sections 1–8 and update this file.
