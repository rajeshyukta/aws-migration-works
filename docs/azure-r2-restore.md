# Old Azure databases from R2: fetch, stage side by side, export

Reusable scripts in `scripts/r2/` for bringing any old Azure database (backed up by NextManager Core to R2 `nxtmngr-test/prod-main`) onto an AWS VM **next to** the live database, then reading it. Nothing here writes to a live database, restarts a service, or writes to R2.

- **Created:** 2026-11-20. First use: NextDP Core brands and dns-service zones (TODO 1.1).
- **Results:** [`azure-r2-brands-and-domains.md`](azure-r2-brands-and-domains.md), [`azure-r2-dns-zones.md`](azure-r2-dns-zones.md) (both generated).
- **No secrets in this file.** The unseal uses `private-data/nmc-main-env.txt` (`JWT_SECRET`) and the recovered NMC DB on the Mail VM; the method is in [`session-handover-2026-11-19.md`](session-handover-2026-11-19.md) section 3.

## 1. Scripts

| Script | Runs | What it does |
|---|---|---|
| `fetch-r2-dump.ps1 -List` | Mail VM | Lists the latest snapshot per backup plan and its database |
| `fetch-r2-dump.ps1 -Database <db> [-SnapshotId <id>]` | Mail VM → this PC | Unseals the restic repo in memory, `restic dump` of the newest (or given) snapshot of that DB, downloads it to `D:\nmc-backup\r2\<db>-<snapshot>\` (`<db>.dump`, `SHA256SUMS`, `meta.txt`), checks SHA-256, deletes the VM copy. A verified local copy is reused without touching any VM (`-Force` fetches again) |
| `stage-r2-db.ps1 -Vm "<VM>" -Database <db>` | target VM | Gets the dump (via `fetch-r2-dump.ps1`), uploads it as a `0600` temp file, recreates `<db>_r2` (owner `postgres`) and `pg_restore --no-owner --no-acl`. Stores the snapshot id/time as `COMMENT ON DATABASE`. Refuses any name not ending in `_r2` |
| `stage-r2-db.ps1 -Vm "<VM>" -Database <db> -Drop` | target VM | Drops `<db>_r2` |
| `make-domain-docs.ps1 [-SkipExport]` | Apps-Core-VM, DNS VM → this PC | Read-only JSON export (`export-nextdp-core-brands.sh`, `export-dns-zones.sh`) into `temp/r2-exports/` (gitignored, has customer emails), then `build-domain-docs.py` writes the two docs |

Mail VM rule: the cluster `16/nmcmain` (port 5433) is started only for the unseal and stopped right after (`-KeepNmcRunning` skips the stop). The env file goes to the VM as `/tmp/.nmc-main-env-<pid>` (created `0600` before the copy) and is deleted on exit.

## 2. Commands

```powershell
cd E:\workspace\aws-setup-and-migrations
.\scripts\r2\fetch-r2-dump.ps1 -List
.\scripts\r2\stage-r2-db.ps1 -Vm "Apps-Core-VM" -Database nextdp_core
.\scripts\r2\stage-r2-db.ps1 -Vm "DNS VM" -Database dns_service
.\scripts\r2\make-domain-docs.ps1
# other DBs, same pattern, e.g.
.\scripts\r2\stage-r2-db.ps1 -Vm "Apps-Core-VM" -Database nextidp
```

## 3. Staged copies (2026-11-20)

| VM | Staged DB | From | Snapshot | Taken (IST) | Local dump |
|---|---|---|---|---|---|
| Apps-Core-VM | `nextdp_core_r2` (owner `postgres`) | `nextdp_core` on `nmc-db-1` | `468f8e88` | 2026-11-18 08:45 | `D:\nmc-backup\r2\nextdp_core-468f8e88\` |
| DNS VM | `dns_service_r2` (owner `postgres`) | `dns_service` on `nmc-db-1` | `a143e215` | 2026-11-16 10:55 | `D:\nmc-backup\r2\dns_service-a143e215\` |

The apps don't use these copies. Drop them with `-Drop` once the brand and DNS imports are done.

## 4. What the backups hold and what they miss

- **`nextdp_core`**: 9 brands, 24 users, 24 registered domains, 57 external domains, 70 DNS zone records, 17 sites, orders, carts, email templates, brand service connections (their API keys are sealed in `api_key_enc`).
- **`dns_service`**: 9 tenants, 108 zones (lifecycle only), users, API key hashes, webhook history.
- **DNS records are missing.** The record data lived in the PowerDNS `pdns` database on the Azure DNS VMs `nmc-dns-1/2`, which NMC did not back up to R2 (there is no `pdns` backup plan). The only remaining copy would be those VMs' Azure OS disks, if Azure still allows a disk export (`az disk grant-access`, same method as `nmc-mail-1-osdisk` in [`mail-vm-db-upgrade-r2.md`](mail-vm-db-upgrade-r2.md) task 0.2).
- The newest `dns_service` snapshot is from 2026-11-16, two days before the shutdown. Zones claimed on 16–18 Nov are missing from it.

## 5. Next steps (after the owner's choice)

1. Owner picks which domains go to the live `nextdp` brand and which new brands to create, from [`azure-r2-brands-and-domains.md`](azure-r2-brands-and-domains.md).
2. Write the import (planned `scripts/apps-core-vm/15-import-r2-brand-domains`): copy the chosen rows from `nextdp_core_r2` into `nextdp_core` with brand id remapping, inside one transaction with a dry-run mode, same method as the mail merge.
3. DNS: add the chosen zones to the live tenant through the dns-service API (like `scripts/dns-vm/03-setup-nextdp-tenant-and-zones`), with records from the owner, since the old records are not in R2.
