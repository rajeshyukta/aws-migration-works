# TODO

Open follow-ups for the AWS setup and migrations. Tick an item and add the date when it is done.
VM reference (what runs where, risks): [`vms-setup-and-services-and-all-info.md`](vms-setup-and-services-and-all-info.md).

**AW Vault is down** (it ran on Azure). Until it is back, "upload to the AW Vault" below means: password manager + offline copy + laptop.

## All VMs

- [ ] **Owner: back up the secrets in `private-data/`** to a password manager (Bitwarden/1Password) + an offline copy (USB/printout), and copy them to the laptop. Not Google Drive, not git.
  - Must-have: `dithim-aws.pem` (SSH to all 4 VMs), `mail-vm-offsite-backup.env`, `web-1-offsite-backup.env` (and the two new ones once item 2 is done), `r2.env`, `nmc-main-env.txt` (unlocks the old NMC R2 backups), `vms-details.txt`.
  - Also useful: the pulled app credentials (`aws-vm-*.env`, `*-admin.env`, `*-realm.env`, `*-accounts.txt`, `dns-*`, `zoho-*`).
  - This also covers the "upload to the AW Vault" items below.
- [ ] **Later: off-site backup for Apps-Core-VM and DNS VM.** Same tool and pattern as Web-1 (`scripts/web-1-vm/07-setup-offsite-backup.ps1` + a `templates/backup/<vm>.backup.conf`):
  - Apps-Core-VM → repo `aws-apps-core/`: DBs `nextidp`, `nextdp_core`, `localcen_db`; files `/opt/nextidp`, `/srv/apps/*/shared`, `/etc/caddy`, `/etc/systemd/system`, `/root/.*-secrets.env`; restore test `nextidp`.
  - DNS VM → repo `aws-dns-vm/`: DBs `pdns` (all 23 zones), `dns_db`; files `/srv/apps/dns-service/shared`, `/etc/powerdns`, `/etc/caddy`, `/root/.dns-*`; restore test `pdns`.
  - Both need restic installed (the setup script does it) and alert mail through the Mail VM's private IP. Check that `172.26.3.188:25` is reachable from these EC2 VMs (different VPC from Lightsail). If not, alert through ZeptoMail.
- [ ] **Later: second DNS server (ns2) on its own VM.** Today ns1 and ns2 are two IPs on the same DNS VM. Add a small VM in another AZ (or a secondary DNS provider via AXFR/NOTIFY) and repoint `ns2.nextdp.com` (glue in the Cloudflare `nextdp.com` zone).
- [ ] **Later: AWS root user.** The CLI is logged in as the account root. Create an IAM user/role for daily Lightsail/EC2 work, enable MFA on root.
- [ ] **Later: SSH hardening.** SSH (22) is open to any IP on all VMs. Consider restricting it to the owner's IPs, or using Lightsail/SSM browser access. Enable `fail2ban` on the Mail VM (it is the only VM without it).

## LocalCen sales launch + new "Sites" VM (decided 2026-11-20)

LocalCen starts selling within ~3 days. LocalCen and later NextBuilder (website builder, Go backend + React) move to their own EC2 VM so it can grow with customer traffic and customer domains. Next iDP + NextDP Core stay on Apps-Core-VM, which then gets smaller.

- [x] **Owner: create the EC2 VM** (done 2026-11-20): named **`LocalCen-1-VM`**, `i-007e720a8c578aad7`, Elastic IP **`3.111.132.3`**, **t2.medium**, 50 GB gp3. Agent added udp 443 to its security group and the `LocalCen-1-VM` block to `vms-details.txt`. Optional: switch to **t3.medium** (newer, slightly cheaper, same 4 GB; stop → change type → start, the EIP stays).
- [x] **Agent: base setup on LocalCen-1-VM** (done 2026-11-20, `scripts/localcen-1-vm/01`) like `scripts/apps-core-vm/01-02` (PostgreSQL 16, Redis, Caddy, ufw, fail2ban, swap, disk check), with Caddy **on-demand TLS** guarded by an ask endpoint. No per-domain Caddy config is needed for 100s of customer domains: LocalCen already answers `/internal/tls-allow?domain=`. Rate limit: Let's Encrypt allows 300 new orders per 3 h per account, and Caddy falls back to ZeroSSL.
- [x] **Agent: copy LocalCen data + deploy on LocalCen-1-VM** (done 2026-11-20, `02` + `03`): DB, `.env`, `shared/`, release `3a3f41b`, healthy on `:8092`.
- [x] **`localcen.cconsole.com` + `admin.localcen.cconsole.com` live on LocalCen-1-VM** (done 2026-11-20: owner DNS, agent `04-setup-caddy.ps1 -Apply -Hosts ...`).
- [x] **`console.localcen.com` + `admin.localcen.com` are NextDP Core brand hosts**, not LocalCen consoles. They stay on Apps-Core-VM (`43.204.42.99`). Their wrong LocalCen routing was removed from the Apps-Core Caddyfile on 2026-11-20 (template too).
- [ ] **Create the `localcen` brand in NextDP Core** (admin `admin.localcen.com`, console `console.localcen.com`, primary product `local`, feature `local` on). NextDP Core then serves those hosts. Connect the brand to LocalCen: a LocalCen tenant + API key from `localcen.cconsole.com`, stored as the brand's service connection (`https://localcen.cconsole.com`).
- [ ] **Remove the old LocalCen copy from Apps-Core-VM** (units, timers, the `localcen.cconsole.com` Caddy blocks, tls-ask entry, `localcen_db` after a final dump). Original host list: `localcen.cconsole.com`, `console.localcen.com`, `admin.localcen.cconsole.com`, `admin.localcen.com` (Cloudflare zone for `localcen.com`, PowerDNS for `cconsole.com`). Lower the TTL to 300 a day before. Then remove LocalCen units, timers, Caddy routes and the tls-ask entry from Apps-Core-VM.
- [ ] **Decide the customer-domain instruction before the first sale.** Tell customers to point `www.<theirdomain>` as a **CNAME** to a hostname we control (e.g. `sites.localcen.com` → Sites-1 IP) and redirect the apex. Then a later move (Linode) only changes our one record. Customers who use an apex **A record** must change it themselves on every move.
- [ ] **Off-site backup for LocalCen-1-VM** before the first customer (repo `aws-localcen-1/`, restore test `localcen_db`). LocalCen holds paying customers' data.
- [ ] **Later: NextBuilder on LocalCen-1-VM** (own port, own DB, its own tls-ask entry).
- [ ] **Later: shrink Apps-Core-VM** (`i-0eee8167ad7ff9be0`, AWS name `LocalCen-Core`) from t3.large to **t3.small** (2 GB) once LocalCen is gone. On 2026-11-20 it used 868 MB in total with load 0.00. It has an Elastic IP (`43.204.42.99`), so the stop/resize/start keeps the IP. Expect ~2 min downtime for `core.nextdp.com` and all `accounts.<brand>` sign-ins.
- [x] **Released unused Elastic IP `65.0.216.106`** (owner, 2026-11-20; checked: 4 EIPs left, all attached).
- [ ] **Later: Linode migration** (when funds are in). Per VM: build the Linode, copy app + data, test via the hosts file, short write freeze, final dump/restore, switch DNS (TTL 300 a day before), keep the AWS VM stopped 2–3 days as fallback, then delete it. Do not run the databases on Linode with the web apps still on AWS: that means slow cross-cloud DB traffic, a public PostgreSQL, and a split-brain risk. Ask Linode support to open outbound mail ports (closed on new accounts); our sending goes through ZeptoMail's API, so it is not blocked. Before deciding, check the real AWS data-transfer cost on the bill: Lightsail plans include a monthly transfer allowance, and EC2 transfer is billed per GB.

## Mail VM (`52.66.111.138`)

- [x] **Lightsail firewall: only required ports** (done 2026-11-20, `scripts/mail-vm/18-lightsail-firewall.ps1`): tcp 22/25/80/443/465/587/143/993/110/995 + udp 443. 53 and 8080 are closed. Web-1 alerts and all web consoles verified.
- [ ] **Later: remove PHP from the Mail VM.** Since the hub moved, `php8.4-*` (16 packages), composer and the ondrej PPA are still installed but `php8.4-fpm` is stopped and disabled. Remove them, plus the old `/srv/phpapps/cconsole-hub` after 2026-12-04, so there are fewer packages to patch.
- [ ] **Later: retire CoreDNS on the Mail VM** (no public traffic since port 53 closed and ns1/ns2 moved). Stop/disable `coredns` after a week with no DNS issues.

- [ ] **Upload `private-data/mail-vm-offsite-backup.env` to the AW Vault** (project `dev-workspace`).
  - It holds the only copy of the off-site backup password outside the Mail VM. Without it, the R2 backup (`nxtmngr-test/aws-mail-vm`) cannot be restored if both this PC and the VM are lost.
  - Do not delete or regenerate the file: a new password cannot open the existing backup.
  - Details: [`mail-vm-offsite-backup.md`](mail-vm-offsite-backup.md).

- [ ] **Delete `nextdp_mail_aug_old` after 27 Nov 2026** (if no mail problems by then).
  - This is the old August database, kept after the 2026-11-20 cutover. Once it is dropped, the quick rollback (rename back) is gone. The final dump stays on this PC in `D:\nmc-backup\mail-vm\cutover-20261120T043819Z\nextdp_mail-final.dump`.
  - On the Mail VM:
    ```bash
    sudo -u postgres psql -p 5432 -XAtc "SELECT datname FROM pg_database WHERE datname LIKE 'nextdp_mail%' ORDER BY 1;"   # expect nextdp_mail + nextdp_mail_aug_old
    sudo -u postgres psql -p 5432 -c "DROP DATABASE nextdp_mail_aug_old;"
    ```
  - Details: [`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md) (sections 4.3 and 6).

## CConsole Hub move to Web-1 (`3.6.143.66`)

Details: [`cconsole-hub-web-1.md`](cconsole-hub-web-1.md).

- [x] **Owner: change 5 DNS A records to `3.6.143.66`** (done 2026-11-20): `hub`, `api.hub`, `admin.hub`, `docs.hub`, `sandbox.hub` (`.cconsole.com`).
- [x] **Agent: run `06-deploy-cconsole-hub.ps1 -Phase sites`** (done 2026-11-20; Let's Encrypt on all 5 hosts).
- [x] **Agent: retire on the Mail VM** with `scripts/mail-vm/17-remove-cconsole-hub.sh` (done 2026-11-20).
- [ ] **Later: API keys for the hub** (owner provides, agent sets them on Web-1 in `/srv/phpapps/cconsole-hub/ci4-app/.env`, then `sudo systemctl reload php8.4-fpm`). All 4 are still `__SET_ON_SERVER__`:
  - `ZEPTO_MAIL_API_KEY` (sender `noreply@cconsole.com`). Without it the hub cannot send email (2FA codes, notifications).
  - `RESELLERCLUB_AUTH_USERID`, `RESELLERCLUB_API_KEY`, `RESELLERCLUB_CUSTOMER_ID`. Without them domain search/registration and the `domains:sync` / `domains:renewals` crons cannot reach ResellerClub. `RESELLERCLUB_SANDBOX = true` stays until the owner says to go live.
  - Keys travel through chat or the AW Vault, never git. After setting them, test one sandbox domain check and one email.
- [ ] **Later: first super admin for the hub**. Owner gives email + name. Agent runs `sudo -u webapps php spark auth:create-admin` in `ci4-app` and stores the generated password in `private-data/` (not in chat).
- [ ] **Delete the old hub on the Mail VM after 2026-12-04**: `/srv/phpapps/cconsole-hub` and DB `cconsole_hub` (the R2 dump on this PC stays).

## Web-1

- [x] **Off-site backup for Web-1** (done 2026-11-20): nightly to R2 `nxtmngr-test/aws-web-1`, weekly verify + restore test, alert mail via the Mail VM. See [`web-1-offsite-backup.md`](web-1-offsite-backup.md).
- [ ] **Upload `private-data/web-1-offsite-backup.env` to the AW Vault** (project `dev-workspace`). Same reason as the Mail VM file: without it the Web-1 backup cannot be restored.
