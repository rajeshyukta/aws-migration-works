# Old Azure data: R2 backups and Azure disks → AWS (brands, domains, DNS)

Reusable scripts for bringing old Azure data onto the AWS VMs **next to** the live databases, reading it, and importing only what the owner picks. Every import has a dry run (default) and a `-Commit` mode.

- **Created / updated:** 2026-11-20.
- **Inventories (generated, rebuild with `scripts/r2/make-domain-docs.ps1`):** [`azure-r2-brands-and-domains.md`](azure-r2-brands-and-domains.md), [`azure-r2-dns-zones.md`](azure-r2-dns-zones.md).
- **No secrets in this file.** The R2 unseal uses `private-data/nmc-main-env.txt` (`JWT_SECRET`) and the recovered NMC DB on the Mail VM ([`session-handover-2026-11-19.md`](session-handover-2026-11-19.md) section 3). Tenant API keys are read from `/root/.dns-<tenant>-secrets.env` (DNS VM) and `private-data/dns-nextdp.env` (PC) and are never printed.
- **Rule (owner):** anything on Azure (disk export, read link) is done only after telling the owner and getting a yes.

## 1. Status 2026-11-20

| Step | Result |
|---|---|
| R2 `nextdp_core` `468f8e88` (2026-11-18 08:45 IST) | Staged as `nextdp_core_r2` on Apps-Core-VM |
| R2 `dns_service` `a143e215` (2026-11-16 10:55 IST) | Staged as `dns_service_r2` on the DNS VM. It holds the zone list only, **no records** |
| Azure disk `nmc-dns-1-osdisk` → PowerDNS `pdns` (final state, cluster shut down cleanly 2026-11-18 05:20:32 UTC / 10:50 IST) | Owner approved. Downloaded on Apps-Core-VM (5 min), DB exported (38 KB), disk file + temp DB deleted, read link revoked. Local copy `D:\nmc-backup\azure\nmc-dns-1-osdisk\pdns\`. Staged as `pdns_azure` on the DNS VM (107 zones, 790 records) |
| **Brand domains:** old brand `nextdigital` → live brand `nextdp` (`34831870-c4c1-4d8b-bd45-b77672b541d3`) | **Done.** 55 domains as external domains (44 external + 11 registered, all `verified`, `managed-dns`), 54 managed-DNS zone rows, original ids kept. **All owned by `rajesh@nextdp.com` (public id `xcztbuqqh`).** No users created (3 copied by the first run were deleted again on the owner's request) |
| **DNS zones:** old account `nextdp` → live tenant `nextdp` (`01a1f019-22db-7b69-9787-ba6220281859`) | **Done.** 61 zones created, 234 record sets added, 150 records `20.207.200.1` → `3.6.143.66`, 14 live zones linked to their NextDP Core zone id, Google MX put back on `daiskills.com` and `srikalabhairavam.com`. Backup before import: `/var/backups/dns-vm/pre-azure-import-20261120T114625Z/` + `D:\nmc-backup\dns-vm\pre-azure-import-20261120T114625Z\`. Re-run of the dry run: nothing left to add |
| **Brand DNS connection** (NextDP Core brand `nextdp` ↔ dns-service tenant `nextdp`) | **Done.** Base URL `https://dns.cconsole.com`, NS `ns1/ns2.nextdp.com`, API key sealed (core "Test connection" OK). Webhook `https://console.nextdp.com/webhooks/dns`: secret set by the owner in the consoles, test ping **delivered (HTTP 200)** |
| **All other old brands → live brand `nextdp`** (owner: one brand for now, new brands later) | **Done.** `presencive` 18 (3 already there), `leadyourbiz` 1, old `nextdp` 2, `dpm` 1, `proseva` 1 → brand `nextdp` has **78 external domains + 69 zone rows**, all owned by `xcztbuqqh` |
| **Other DNS accounts → live tenant `nextdp`** (`presencive`, `proseva`, `leadyourbiz`, `yourdpm`, `savadhan`, run with `-KeyAccount nextdp`) | **Done.** 16 zones created, 51 record sets, same drop/rewrite rules, no Cloudflare zones among them. Tenant `nextdp` serves **100 zones**. Backup before: `/var/backups/dns-vm/pre-azure-import2-20261120T125538Z/`. **11 of these zones are delegated to old brand NS names (`ns1/ns2.presencive.com`, `.leadyourbiz.com`, `.yourdpm.com`, `.proseva.org`) that still point to dead Azure IPs**, so they do not resolve until the owner changes their NS (TODO 1.0) |
| **Apps-Core Caddy catch-all fix** | **Done.** Every POST with a body on brand hosts (`admin/console.<brand>`) returned 502 (the Next iDP hop consumed the body before the 421 fallthrough). Now a router decides per host first. Backup `/var/backups/caddy/pre-routing-fix-20261120T120834Z/` |

### Import rules used (owner decisions 2026-11-20)

- **Brands:** every domain of the old brand becomes an external domain (nothing is registered through a registrar API yet). Every domain goes to **one** live account given by public id. No user accounts are created or copied.
- **DNS, dropped (not imported):** records on old Next iDP `20.235.94.100`, old Go apps `20.219.8.247`, old NS glue `4.224.62.222` / `172.198.131.111`; brand admin/console/accounts hosts; iDP records (`_n1-verify.*` TXT, CNAMEs to `edge.n1id.ac2.in`); SOA and apex NS (dns-service sets them).
- **DNS, rewritten:** `20.207.200.1` (old PHP VM `nmc-php-stage-1`) → `3.6.143.66` (Web-1).
- **DNS, kept as they were:** records on IPs we don't own (`justicefor.*` `34.47.229.227`, `rapidgo.dev` `4.213.227.125`, `weddingsite.in` `18.233.215.69`, `dev.panchang.io` `20.244.34.202`, `nextmanager.in` `40.81.236.71`/`65.0.126.80`, `ns1/ns2.lewiai.com`, `ns1/ns2.mananiya.com`, `ns1/ns2.ddns.nextdp.com`); Google MX records.
- **DNS, zones already live:** live record sets win; only missing old ones are added (DKIM keys, `z.<domain>` ZeptoMail CNAMEs, site verifications). Exception: an old Google MX replaced on AWS is put back.
- **DNS, skipped zones (on Cloudflare, not on our NS):** `rajesh1.com`, `nextdp.com`, `localcen.com`, `dithim.com`, `presencive.com`, `rajesh.one`, `rajeshone.com`, `kalabhairavam.com`, `bsupport.in`, `masterymd.com`, `qasandbox.com`, `whfya.com`.

Public delegation of the 89 old zones at import time (registrar NS, checked from the DNS VM): 57 on `ns1/ns2.nextdp.com`, 12 Cloudflare, 7 unregistered or no NS (`padmashali.org`, `securedbot.in`, `rajesh.app`, `yuktas.com`, `apimw.com`, `getcybersafety.com`, `nevergiveup.in`), 13 at other providers (Gandi, Spaceship, GoDaddy, Route 53, Azure DNS, name-services, dnshorizon, atom, `ns1.mananiya.com`). dns-service marks non-delegated zones itself (`awaiting_ns` → `expired`).

## 2. Scripts

| Script | Runs | What it does |
|---|---|---|
| `scripts/r2/fetch-r2-dump.ps1 -List` | Mail VM | Latest snapshot per backup plan and its database |
| `scripts/r2/fetch-r2-dump.ps1 -Database <db> [-SnapshotId <id>]` | Mail VM → PC | Unseals the restic repo in memory, `restic dump`, downloads to `D:\nmc-backup\r2\<db>-<snapshot>\` (`<db>.dump`, `SHA256SUMS`, `meta.txt`), checks SHA-256, deletes the VM copy. Reuses a verified local copy (`-Force` to fetch again). Starts/stops cluster `16/nmcmain` |
| `scripts/r2/azure-disk-pgdump.{ps1,sh}` | Azure + helper VM → PC | For data NMC never backed up (e.g. PowerDNS on `nmc-dns-1`). Read SAS (2 h, revoked at the end), AzCopy to the helper VM, read-only loop mount, copy the PostgreSQL data dir, temporary cluster on a private socket (no TCP), `pg_dump`, delete everything. `-KeepOnFailure` / `-SkipDownload` for reruns. **Ask the owner first** |
| `scripts/r2/stage-r2-db.ps1 -Vm "<VM>" -Database <db> [-DumpDir <dir>]` | target VM | Restores side by side as `<db>_r2` (R2) or `<db>_azure` (`-DumpDir`), owner `postgres`, snapshot info in `COMMENT ON DATABASE`. Refuses other names. `-Drop` removes the copy |
| `scripts/r2/make-domain-docs.ps1 [-SkipExport]` | Apps-Core-VM, DNS VM → PC | Read-only JSON export into `temp/r2-exports/` (gitignored, has customer emails), then writes the two inventory docs |
| `scripts/apps-core-vm/15-import-r2-brand-domains.ps1 -SourceBrand <slug> -DestBrandId <id> -OwnerPublicId <pid> [-Skip a,b] [-Commit]` | Apps-Core-VM | Old brand's domains → live brand as external domains + zone rows, one owner, ids kept, one transaction; skips domains the live brand already has. Report `temp/r2-import-<slug>.tsv` |
| `scripts/apps-core-vm/16-setup-brand-dns-connection.ps1 -BrandId <id> [-NoWebhook]` | Apps-Core-VM | Checks the tenant API key (`/whoami`), seals it with the NextDP Core keyring and saves the brand's `dns` connection. Its webhook step needs a console session on dns-service (iDP login), so set the webhook in the consoles (section 4) |
| `scripts/dns-vm/08-azure-zones-report.sh` | DNS VM | Read-only report: old zones, where A records point, CNAME/MX targets, old vs live differences |
| `scripts/dns-vm/09-import-azure-zones.ps1 [-SkipZones ...] [-DropIps ...] [-DropHosts ...] [-IpMap old=new] [-KeepLiveGoogleMx] [-Commit]` | Apps-Core-VM (refs) + DNS VM | Old PowerDNS account → live dns-service tenant through the API. Prints each zone's public delegation. Plan `temp/dns-import-<account>.tsv` |
| `scripts/apps-core-vm/13-setup-nextdp-brand.ps1 -Slug <slug> -Name <name> -PrimaryDomain <d> -SenderEmail <e> -PrimaryProduct <p> -Features a,b -AdminEmail <e> -Nameservers ns.a,ns.b` | Apps-Core-VM | New brand in NextDP Core + its Next iDP child realm, brand superadmin + realm admin, brand NS; credentials `/root/.<slug>-brand-idp.env` → `private-data/<slug>-brand-idp.env`. Restarts `nextdp` (a few seconds). Defaults = the `nextdp` brand |
| `scripts/dns-vm/10-create-tenant.ps1 -Slug <s> -Name <n> -Nameservers a,b -SoaContact <e> [-WebhookUrl https://console.<host>/webhooks/dns] [-Commit]` | DNS VM | New dns-service tenant + API key + webhook secret, written to `dns_db` (backup first), key checked via `/whoami`; secrets `/root/.dns-<slug>-secrets.env` → `private-data/dns-<slug>.env` |
| `16-setup-brand-dns-connection.ps1 ... -KeyFile dns-<slug>.env -KeyName API_KEY -WebhookSecretName WEBHOOK_SECRET` | Apps-Core-VM | With a tenant from `10-create-tenant`: also stores the webhook secret and sends a signed `webhook.test` to the brand console (must be 2xx) |
| `scripts/apps-core-vm/17-fix-catchall-routing.ps1` | Apps-Core-VM | Deploys `templates/Caddyfile.apps-core-vm` + `templates/caddy/apps-core-tls-ask.py` (router), validates, reloads, tests, rolls back by itself on failure |

## 3. Commands used 2026-11-20

```powershell
cd E:\workspace\aws-setup-and-migrations
.\scripts\r2\stage-r2-db.ps1 -Vm "Apps-Core-VM" -Database nextdp_core
.\scripts\r2\stage-r2-db.ps1 -Vm "DNS VM" -Database dns_service
.\scripts\r2\azure-disk-pgdump.ps1 -Disk nmc-dns-1-osdisk -ResourceGroup DNS -Databases pdns   # owner-approved
.\scripts\r2\stage-r2-db.ps1 -Vm "DNS VM" -Database pdns -DumpDir D:\nmc-backup\azure\nmc-dns-1-osdisk\pdns
.\scripts\apps-core-vm\15-import-r2-brand-domains.ps1 -SourceBrand nextdigital -DestBrandId 34831870-c4c1-4d8b-bd45-b77672b541d3 -OwnerPublicId xcztbuqqh -Commit
.\scripts\dns-vm\09-import-azure-zones.ps1 -Commit -SkipZones rajesh1.com,nextdp.com,localcen.com,dithim.com,presencive.com,rajesh.one,rajeshone.com,kalabhairavam.com,bsupport.in,masterymd.com,qasandbox.com,whfya.com
.\scripts\apps-core-vm\16-setup-brand-dns-connection.ps1 -BrandId 34831870-c4c1-4d8b-bd45-b77672b541d3
.\scripts\apps-core-vm\17-fix-catchall-routing.ps1
.\scripts\r2\make-domain-docs.ps1
```

## 4. Moving domains to a new brand later (same pattern)

All old brands are in the live brand `nextdp` now. When a new brand is created, its domains move from `nextdp` to it (a small script: update `users`/`brand_id` of the zone rows and the owner of the external domains; not written yet). For a fresh import from the staged copies instead:

1. Owner picks the old brand, the live brand (create it first if needed) and the **one** owner account (public id).
2. `15-import-r2-brand-domains.ps1` dry run → owner checks → `-Commit`.
3. DNS: old account in `pdns_azure` → live tenant. Create the live tenant first if needed. Dry run `09-import-azure-zones.ps1 -Account <acct> -KeyAccount <target tenant> -TenantId <id> -CoreBrandId <id>`, owner checks drops/rewrites, `-Commit`. The script reads the tenant key from `/root/.dns-<account>-secrets.env` on the DNS VM.
4. Brand DNS connection: `16-setup-brand-dns-connection.ps1 -BrandId <id> -KeyFile <file> -NoWebhook`, then the webhook in the consoles: dns.cconsole.com → Webhook: URL `https://console.<brand host>/webhooks/dns`, rotate the secret → core.nextdp.com → Brands → `<brand>` → DNS → paste the secret → Test ping.
5. Rebuild the inventories (`make-domain-docs.ps1`), update this file, the VM reference doc and TODO.

## 5. Staged copies (keep for now: owner, 2026-11-20)

They still hold data not imported yet that may be needed (NextDP Core customer profiles, domain contacts, orders, sites, templates; old DNS tenants). Delete only on the owner's go.

| VM | DB | From |
|---|---|---|
| Apps-Core-VM | `nextdp_core_r2` | R2 `468f8e88` |
| DNS VM | `dns_service_r2` | R2 `a143e215` |
| DNS VM | `pdns_azure` | Azure disk `nmc-dns-1-osdisk`, 2026-11-18 10:50 IST |

`.\scripts\r2\stage-r2-db.ps1 -Vm "<VM>" -Database <db> -TargetDb <name> -Drop`. The apps don't use these copies.
