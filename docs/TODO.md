# TODO

Open follow-ups for the AWS setup and migrations. Tick an item and add the date when it is done.
- VM reference (what runs where, risks): [`vms-setup-and-services-and-all-info.md`](vms-setup-and-services-and-all-info.md)
- Last session record: [`session-handover-2026-11-20.md`](session-handover-2026-11-20.md)
- **AW Vault is down** (it ran on Azure). "Vault" below means password manager + offline copy + laptop.

---

## 1. Next session: old DBs, NextDP Core brands, DNS (step by step)

Work one step at a time; confirm with the owner before each import or DNS change.

- [ ] **1.0 Old Azure brands and DNS → AWS (in progress).** Method, rules and scripts: [`azure-r2-restore.md`](azure-r2-restore.md). Inventories: [`azure-r2-brands-and-domains.md`](azure-r2-brands-and-domains.md), [`azure-r2-dns-zones.md`](azure-r2-dns-zones.md).
  - [x] 2026-11-20: old brand `nextdigital` → live brand `nextdp`: 55 external domains + 54 zone rows, all owned by `rajesh@nextdp.com` (`xcztbuqqh`), no users created.
  - [x] 2026-11-20: old DNS account `nextdp` (final Azure PowerDNS data from the `nmc-dns-1` disk, owner-approved) → live tenant `nextdp`: 61 zones created, 234 record sets, `20.207.200.1` → `3.6.143.66`; 12 Cloudflare zones skipped.
  - [x] 2026-11-20: brand `nextdp` DNS connection + webhook (test ping delivered).
  - [x] 2026-11-20: Apps-Core Caddy catch-all: POSTs on brand hosts were 502 → fixed (`scripts/apps-core-vm/17-fix-catchall-routing`).
  - [x] 2026-11-20: **all other old brands → live brand `nextdp` too** (owner decision: one brand for now, new brands later): `presencive` 18, `leadyourbiz` 1, old `nextdp` 2 (`hamarards.com/.org`), `dpm` 1, `proseva` 1 → brand `nextdp` now has **78 external domains + 69 zone rows**, all owned by `xcztbuqqh`. `digpre`, `ogcen`, `localcen` had no customer domains.
  - [x] 2026-11-20: DNS accounts `presencive` (13 zones), `proseva`, `leadyourbiz`, `yourdpm`, `savadhan` → live tenant `nextdp`: 16 zones created, 51 record sets. Tenant `nextdp` now serves **100 zones**. Backup before: `/var/backups/dns-vm/pre-azure-import2-20261120T125538Z/` (+ `D:\nmc-backup\dns-vm\`).
  - [ ] **Owner (DNS, at the registrars): 11 imported domains do not resolve yet.** Their registrar NS are old brand nameserver names that still point to dead Azure IPs or to nothing: `ns1/ns2.presencive.com` → `4.224.62.222`/`172.198.131.111` (`athomepg.in`, `bharatgetonline.com`, `bhuvigeotech.co.in`, `halli.in`, `hargharme.com`, `icfluence.com`, `rapidbot.in`, `srinivasulu.in`), `ns1/ns2.leadyourbiz.com` → `172.198.68.99`/`20.193.232.99` (`leadyourbiz.in`), `ns1/ns2.yourdpm.com` → same (`whydpm.com`), `ns1/ns2.proseva.org` → no address (`haindaviswaraj.org.in`). Our DNS VM already serves all of them (tenant `nextdp`). Fix per domain, either: change its NS at the registrar to `ns1.nextdp.com` / `ns2.nextdp.com` (recommended, one NS pair for everything), or point the brand NS names (A records + registrar glue) to `52.66.165.1` / `52.66.25.51`.
  - [ ] Later: create the needed brands again (`presencive`, `localcen`, ...) and move their domains from `nextdp` to them.
  - [ ] **Owner, manual, later:** records still on IPs we don't run (kept as they were): `justicefor.info/.net` `34.47.229.227`, `rapidgo.dev` `4.213.227.125`, `weddingsite.in` `18.233.215.69`, `dev.panchang.io` `20.244.34.202`, `nextmanager.in` `40.81.236.71`, `ns1.lewiai.com` `20.247.115.95`. Decide per domain.
  - [ ] Owner: sites whose records were dropped have no website now (`afterai.work`, `associate.works`, `rajesh.works`, `presencive.com`, `blogs.cconsole.com`, `onesign.in`): repoint when the apps exist on AWS.
  - [ ] **Keep the staged copies for now (owner, 2026-11-20):** `nextdp_core_r2` (Apps-Core-VM) still holds data not imported yet that may be needed: customer profiles (`users`, `user_profiles`), domain contacts (`domain_contacts`, `domain_contact_book`), orders/carts, sites, email templates, brand settings. `dns_service_r2` and `pdns_azure` (DNS VM) hold the old tenants and records. Delete later, only on the owner's go (`scripts/r2/stage-r2-db.ps1 ... -Drop`); local dumps stay in `D:\nmc-backup\r2\` and `D:\nmc-backup\azure\`.
- [ ] **1.1 Decide which old Azure data to bring back.** The latest R2 dumps (repo `nxtmngr-test/prod-main`, table in [`session-handover-2026-11-19.md`](session-handover-2026-11-19.md) section 3) that matter now: `nextdp_core` `468f8e88` (brands, members, domains, orders), `nextidp` `6cbb9b6a` (realms, users), `nextlocal` `807188cf` (old LocalCen data, 2026-11-08), `dns_service` `a143e215`. The live AWS DBs are **fresh** setups. Pattern: restore a dump side by side as `<db>_r2`, compare, and import only the chosen rows (same method as the mail upgrade, [`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md)). Unsealing the R2 password needs `private-data/nmc-main-env.txt` + the NMC DB on the Mail VM port 5433 (start it with `sudo pg_ctlcluster 16 nmcmain start`, stop it after).
- [ ] **1.2 Owner: switch on Next iDP sign-in for the `nextdp` brand.** The realm `ndp-nextdp` (`accounts.nextdp.com`) is `live` and its TXT verifies, but NextDP Core still has `idp_status = pending`. Open `https://core.nextdp.com/brands/nextdp/signin` → **Re-check** → turn on **Sign-in via Next iDP** ([`realm-ndp-nextdp.md`](realm-ndp-nextdp.md) section 5).
- [ ] **1.3 Owner: `accounts.localcen.com` A → `43.204.42.99`** (Cloudflare, DNS-only). It still points to old Azure `nmc-idp-1` (`20.235.94.100`). Needed for the LocalCen brand's sign-in realm `ndp-localcen`.
- [ ] **1.4 Create the `localcen` brand in NextDP Core** (admin `admin.localcen.com`, console `console.localcen.com`, primary product `local`, feature `local` on). Either in the core.nextdp.com UI (host cache refreshes at once) or with `scripts/apps-core-vm/13-setup-nextdp-brand` (env `BRAND_SLUG=localcen` etc.; it restarts `nextdp`). Owner decides: brand display name, sender email (e.g. `noreply@localcen.com`), brand admin email. DNS for both hosts already points to `43.204.42.99`; certificates come on the first visit (check with `scripts/apps-core-vm/audit-domains.sh`). After creation, add the `_n1-verify.accounts.localcen.com` TXT that Next iDP shows.
- [ ] **1.5 Connect the brand to LocalCen.** In `admin.localcen.cconsole.com` create a tenant for the brand; that tenant creates an API key in `localcen.cconsole.com`; store it in NextDP Core as the brand's service connection (`brand_service_connections`, kind `local`, base URL `https://localcen.cconsole.com`). Test: create a test local from `console.localcen.com`.
- [ ] **1.6 DNS clean-up.** `nmc.nextdp.com` and `s3.nextdp.com` still point to Azure; any other old-fleet records (check the Cloudflare `nextdp.com` zone and PowerDNS zones for `20.*`/`40.*`/`4.224.*`/`172.198.*` targets). Remove or repoint.

## 2. LocalCen launch (selling in ~3 days)

- [ ] **Off-site backup for LocalCen-1-VM before the first customer** (repo `aws-localcen-1/`, restore test `localcen_db`). Same tool as Web-1 (`scripts/web-1-vm/07-setup-offsite-backup.ps1` + a `templates/backup/localcen-1.backup.conf`).
- [ ] **Decide the customer-domain instruction before the first sale.** Recommended: customers point `www.<theirdomain>` as a **CNAME** to a hostname we control (e.g. `sites.localcen.com` → `3.111.132.3`) and redirect the apex, so a later move only changes our one record. Apex **A records** (`3.111.132.3`) must be changed by every customer on every move. LocalCen checks that the domain resolves to `LOCAL_HOST_SERVER_IPS`.
- [ ] Optional: switch LocalCen-1-VM from **t2.medium** to **t3.medium** (newer, slightly cheaper, same 4 GB; stop → change type → start, the Elastic IP stays).
- [ ] **Later: NextBuilder on LocalCen-1-VM** (own port, own DB, add a tls-ask multiplexer in front of LocalCen's ask, like `templates/caddy/apps-core-tls-ask.py`).
- [ ] **Later: shrink Apps-Core-VM** (`i-0eee8167ad7ff9be0`, AWS name still `LocalCen-Core`: rename it) from t3.large to **t3.small** (2 GB). On 2026-11-20 after LocalCen left it used 851 MB with load 0.00. Elastic IP `43.204.42.99` stays. ~2 min downtime for `core.nextdp.com` and all `accounts.<brand>` sign-ins.

## 3. All VMs

- [ ] **Off-site backup for Apps-Core-VM and DNS VM.** Same pattern as Web-1:
  - Apps-Core-VM → repo `aws-apps-core/`: DBs `nextidp`, `nextdp_core`; files `/opt/nextidp`, `/etc/nextidp`, `/srv/apps/nextdp/shared`, `/etc/caddy`, `/etc/systemd/system`, `/root/.*.env`; restore test `nextidp`.
  - **DNS VM first (now 100 zones, 2026-11-20; owner: later)** → repo `aws-dns-vm/`: DBs `pdns` (all zones), `dns_db`; files `/srv/apps/dns-service/shared`, `/etc/powerdns`, `/etc/caddy`, `/root/.dns-*`; restore test `pdns`.
  - EC2 VMs are in a different network from Lightsail: check that the Mail VM's private `172.26.3.188:25` is reachable for alert mail; if not, alert through ZeptoMail.
- [ ] **Owner: secrets copy.** Done 2026-11-20: `private-data/` uploaded to Google Drive (web). Still recommended: replace the loose files with one **7-Zip AES-256 archive** (passphrase in a password manager), turn on Google 2-step verification, and keep an offline copy + a laptop copy. Must-haves: `dithim-aws.pem`, `mail-vm-offsite-backup.env`, `web-1-offsite-backup.env`, `r2.env`, `nmc-main-env.txt`, `vms-details.txt` (+ new backup password files when sections 2/3 backups are added). Never regenerate a `*-offsite-backup.env`.
- [ ] **Later: second DNS server (ns2) on its own VM.** ns1 and ns2 are two IPs on the same DNS VM. Add a small VM in another AZ (or a secondary DNS provider via AXFR/NOTIFY) and repoint `ns2.nextdp.com` (glue in the Cloudflare `nextdp.com` zone).
- [ ] **Later: AWS root user.** The CLI runs as account root. Create an IAM user/role for daily Lightsail/EC2 work, MFA on root.
- [ ] **Later: SSH hardening.** SSH (22) is open to any IP on all VMs. Consider restricting to the owner's IPs or using SSM. Enable `fail2ban` on the Mail VM (the only VM without it).
- [ ] **Later: Linode migration** (when funds are in). Per VM: build the Linode, copy app + data, test via hosts file, short write freeze, final dump/restore, switch DNS (TTL 300 a day before), keep the AWS VM stopped 2–3 days as fallback, then delete. Do not split DBs (Linode) from apps (AWS). Ask Linode support to open outbound mail ports (our sending uses ZeptoMail's API anyway). Check the real AWS data-transfer cost on the bill first (Lightsail plans include transfer; EC2 transfer is per GB).

## 4. Mail VM (`52.66.111.138`)

- [ ] **Delete `nextdp_mail_aug_old` after 27 Nov 2026** (if no mail problems). Final dump stays in `D:\nmc-backup\mail-vm\cutover-20261120T043819Z\nextdp_mail-final.dump`. On the VM: `sudo -u postgres psql -p 5432 -c "DROP DATABASE nextdp_mail_aug_old;"` ([`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md) sections 4.3, 6).
- [ ] **Delete the old CConsole Hub on the Mail VM after 2026-12-04**: `/srv/phpapps/cconsole-hub` and DB `cconsole_hub` (the R2 dump `r2-677d331a` on this PC stays).
- [ ] **Later: remove PHP from the Mail VM** (`php8.4-*` 16 packages, composer, ondrej PPA; `php8.4-fpm` is already stopped and disabled).
- [ ] **Later: retire CoreDNS on the Mail VM** (no public traffic since port 53 was closed and ns1/ns2 moved). Stop/disable `coredns` after a week with no DNS issues.
- [x] Lightsail firewall: only tcp 22/25/80/443/465/587/143/993/110/995 + udp 443 (2026-11-20, `scripts/mail-vm/18-lightsail-firewall.ps1`).
- [x] `nextdp_mail` on R2 snapshot + AWS delta (2026-11-20), nightly off-site backup ([`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md)).

## 5. CConsole Hub on Web-1 (`3.6.143.66`)

Details: [`cconsole-hub-web-1.md`](cconsole-hub-web-1.md).

- [ ] **Later: API keys for the hub** (owner provides; agent sets them in `/srv/phpapps/cconsole-hub/ci4-app/.env` on Web-1, then `sudo systemctl reload php8.4-fpm`). All 4 are `__SET_ON_SERVER__`: `ZEPTO_MAIL_API_KEY` (no email without it), `RESELLERCLUB_AUTH_USERID`, `RESELLERCLUB_API_KEY`, `RESELLERCLUB_CUSTOMER_ID` (no ResellerClub calls or domain crons without them). `RESELLERCLUB_SANDBOX = true` until the owner says go live. Test one sandbox domain check and one email.
- [ ] **Later: first super admin for the hub.** Owner gives email + name; agent runs `sudo -u webapps php spark auth:create-admin` in `ci4-app` and stores the password in `private-data/`.
- [x] Moved from the Mail VM to Web-1 as a fresh install, DNS switched, Let's Encrypt on all 5 hosts (2026-11-20).

## Done 2026-11-20 (for reference)

- LocalCen moved to its own VM **LocalCen-1-VM** (`3.111.132.3`, `i-007e720a8c578aad7`): base setup, data copy, deploy, live for `localcen.cconsole.com` + `admin.localcen.cconsole.com`; old install removed from Apps-Core-VM (final dump in `D:\nmc-backup\apps-core\localcen-retired-20261120T085819Z\`).
- `console.localcen.com` / `admin.localcen.com` confirmed as **NextDP Core brand hosts**; their wrong LocalCen routing removed from Apps-Core-VM Caddy.
- Apps-Core-VM domain/TLS audit: Next iDP + NextDP Core enable new domains by themselves (on-demand TLS ask + 421 handover); no setup mistakes.
- Web-1 off-site backup (`aws-web-1/`); backup tool made per-VM configurable.
- Unused Elastic IP `65.0.216.106` released.
- Docs: VM reference doc, workspace `AGENTS.md` §4.0, READMEs.
