# Session handover — 2026-11-20

Context transfer for the next chat. **No secrets in this file.** Read it together with:
1. [`vms-setup-and-services-and-all-info.md`](vms-setup-and-services-and-all-info.md) — what runs where (source of truth)
2. [`TODO.md`](TODO.md) — open work; **section 1 is the next session's plan** (old DBs, NextDP Core brands, DNS)
3. [`session-handover-2026-11-19.md`](session-handover-2026-11-19.md) section 3 — the R2 snapshot table of all old Azure DBs

Repo: `E:\workspace\aws-setup-and-migrations` (`rajeshyukta/aws-migration-works`, branch `main`, everything pushed). Workspace root `E:\workspace` (`raiworks/workspace`): `AGENTS.md` §4.0 lists the AWS VMs.

---

## 1. Live VMs (all `ap-south-1`, Ubuntu 24.04, SSH `ubuntu@` with `private-data/dithim-aws.pem`)

| Name in `private-data/vms-details.txt` | IP | Runs |
|---|---|---|
| Mail VM (Lightsail `NextDP-Mail-VM`) | 52.66.111.138 | NextDP Mail, dithim.com, catch-all maintenance page |
| Web-1 (Lightsail) | 3.6.143.66 | PHP/static sites, domains.rajesh.app, CConsole Hub |
| Apps-Core-VM (EC2, AWS name `LocalCen-Core`) | 43.204.42.99 | Next iDP (:8080), NextDP Core (:8090) |
| LocalCen-1-VM (EC2, new) | 3.111.132.3 | LocalCen (:8092), NextBuilder later |
| DNS VM (EC2) | 52.66.165.1 / 52.66.25.51 | PowerDNS ns1/ns2 + dns-service |

Connect from PowerShell: `. .\scripts\mail-vm\common.ps1; $vm = Get-VmTarget -Name "<name>"`, then `Invoke-VmScript -Vm $vm -LocalScriptPath <file.sh>`. Write remote logic as a `.sh` file (Windows `ssh` breaks inline quotes). PowerShell 5.1 treats remote stderr as an error: scripts start with `exec 2>&1`. Run DNS lookups from the VM you are working on (never use the Mail VM as a helper box). AWS CLI: `aws login` first (session expires), account root (to be replaced by an IAM user).

## 2. What was done on 2026-11-20

**Mail VM**
- `nextdp_mail` switched to R2 snapshot `689c5e6a` + the AWS-period delta (33 s downtime); Aug→Nov mail files recovered from the Azure disk `nmc-mail-1-osdisk`. Old DB kept as `nextdp_mail_aug_old` (drop after 27 Nov). Record: `mail-vm-db-upgrade-r2.md`.
- Nightly off-site backup to R2 `nxtmngr-test/aws-mail-vm/` (02:30 IST), weekly restore test, failure mail to rajesh@nextdp.com. Runbook: `mail-vm-offsite-backup.md`.
- Lightsail firewall: only tcp 22/25/80/443/465/587/143/993/110/995 + udp 443 (was all ports). `scripts/mail-vm/18-lightsail-firewall.ps1`.
- CConsole Hub retired here (PHP-FPM off; PHP packages still installed).

**Web-1**
- CConsole Hub (`reseller-mw`) fresh install, 5 `*.hub.cconsole.com` hosts live with Let's Encrypt. API keys + first super admin still to do. Record: `cconsole-hub-web-1.md`.
- Nightly off-site backup to `aws-web-1/` (02:45 IST), restore test of `domains_rajesh`, alerts through the Mail VM's private SMTP. `web-1-offsite-backup.md`. DB `web1_apps` is an empty spare, kept on purpose.

**LocalCen**
- New EC2 VM **LocalCen-1-VM** (`3.111.132.3`, t2.medium, 50 GB): `scripts/localcen-1-vm/01` base setup (PostgreSQL 16, Caddy, ufw, fail2ban, swap), `02` copied DB/.env/shared from Apps-Core-VM, `03` build + deploy (repeatable), `04` dedicated Caddy with on-demand TLS for customer domains (ask → LocalCen `/internal/tls-allow`).
- Live: `localcen.cconsole.com` (tenant console: tenants make API keys) and `admin.localcen.cconsole.com` (platform admin). DB has 0 tenants.
- Old LocalCen install **removed** from Apps-Core-VM (`scripts/apps-core-vm/14-remove-localcen`); final dump in `D:\nmc-backup\apps-core\localcen-retired-20261120T085819Z\`.

**Business model (owner, confirmed):** LocalCen's own consoles are for the platform admin and tenants (API keys). End clients buy LocalCen through **NextDP Core brands**. A `localcen` brand in NextDP Core will serve `console.localcen.com` and `admin.localcen.com` (DNS → `43.204.42.99`). These two hosts were wrongly routed to LocalCen in the Apps-Core Caddyfile; fixed.

**Apps-Core-VM audit** (`scripts/apps-core-vm/audit-domains.sh`): no setup mistakes. Caddy on-demand TLS asks `:8099`, which asks Next iDP `/_edge/ask` (realm hosts) and NextDP Core `/internal/tls/ask` (active brands' admin/console hosts). The catch-all goes to Next iDP, which answers 421 for hosts it does not own, so Caddy hands them to NextDP Core. New brand/realm hosts switch on by themselves.

**Other:** unused Elastic IP `65.0.216.106` released; owner uploaded `private-data/` to Google Drive (web); docs updated (VM reference doc, workspace `AGENTS.md` §4.0, `README.md`, `WORKSTATIONS.md`, this repo's `README.md`/`AGENTS.md`).

## 3. State that the next session needs

| Item | State |
|---|---|
| Next iDP realms | `nextdp-core` (`id.nextdp.com`), `ndp-nextdp` (`accounts.nextdp.com`), `cconsole` (`accounts.cconsole.com`): all `live` |
| NextDP Core brands | only `nextdp` (`admin/console.nextdp.com`, product `domains`, `idp_status = pending` → needs Re-check). Feature `local` exists but is off. `brand_service_connections` is empty |
| DNS waiting on owner | `accounts.localcen.com` still → `20.235.94.100` (old Azure); `nmc.nextdp.com`, `s3.nextdp.com` still → Azure |
| Live DBs | all **fresh** (except `nextdp_mail`): Apps-Core `nextidp`, `nextdp_core`; LocalCen-1 `localcen_db`; DNS VM `pdns`, `dns_db`; Web-1 `domains_rajesh`, `cconsole_hub`, `web1_apps` |
| Old data | R2 `nxtmngr-test/prod-main` (read-only; never write). Unseal with `private-data/nmc-main-env.txt` + NMC DB on the Mail VM port 5433 (`sudo pg_ctlcluster 16 nmcmain start`, stop afterwards). Snapshot ids: `session-handover-2026-11-19.md` §3. Method: `scripts/mail-vm/11-stage-r2-mail-db` (stage side by side) |
| Backups | Mail VM ✅, Web-1 ✅, Apps-Core ❌, DNS VM ❌, LocalCen-1 ❌ (needed before first customer) |

## 4. Rules learned this session

- Ask before changing anything public (DNS, firewalls, live Caddy); the owner changes DNS himself (Cloudflare + dns-service).
- Never print secrets; pass them as 0600 temp files that are deleted on exit. Never regenerate a `*-offsite-backup.env`.
- Keep `docs/vms-setup-and-services-and-all-info.md` and `docs/TODO.md` current in the same commit as any change.
- Before removing config with a script, make the "is it gone" check precise (comments also contain host names).
