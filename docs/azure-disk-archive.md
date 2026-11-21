# Azure disk archive — every old Azure disk into one private R2 bucket

> **Owner**: Rajesh · **Started**: 2026-11-21 · **Status**: 🟡 in progress (disk 1 of 12) · keep this file current: every run updates §4 (status), §7 (log) and, if something changed, §5 (procedure).
> **▶ Resume here**: Recovery-VM is set up (work volume `/work`, tools, R2 remote tested). Next: disk **`nmc-php-stage-1-osdisk`** → download → inspect → export (LocalCen's `localcen_db` with the place data first, then everything else) → upload → verify → cleanup. Then load LocalCen's places on LocalCen-1-VM (§6).

## 1. Why
The Azure subscription was disabled on 2026-11-18 and the services were rebuilt on AWS (`vms-setup-and-services-and-all-info.md`). The R2 restic repo `nxtmngr-test/prod-main` holds daily dumps of most fleet databases (`azure-r2-restore.md`), but not everything: LocalCen's `localcen_db` (place data), several staging databases, every `.env` / secret, app code and uploads were only on the VM disks. The 12 Azure managed disks still exist (the VMs are deallocated). This work copies **all of them, once, into our own bucket**, so any old database, env or file can be restored later without Azure.

Owner decisions (2026-11-21): archive all disks; a temporary recovery VM on AWS; a new R2 bucket (cheapest with free download, see the price check of 2026-11-21 in the chat: R2 Standard $0.015 / GB-month, no egress); first disk `nmc-php-stage-1` (LocalCen).

## 2. Pieces
| Piece | Where | Notes |
|---|---|---|
| **Recovery-VM** | EC2 `16.4.71.66` (private `172.31.31.33`), `m6i.large` 2 vCPU / 7.6 GB, `ap-south-1c`, Ubuntu 24.04 | made by the owner; key `private-data/dithim-aws.pem`; entry `Recovery-VM` in `private-data/vms-details.txt`. **Temporary**: terminate it (and its volume) when §4 is all ✅. As EC2, uploads to R2 are AWS outbound transfer (~$0.09–0.11 / GB) |
| Work volume | `/work` (250 GB gp3, ext4, label `work`, fstab `nofail`) | `/work/disks/<disk>/` = VHD + read-only mounts (deleted per disk); `/work/out/<disk>/` = the exports before upload |
| **Bucket** | Cloudflare R2 **`raiworks-azure-archive`** (APAC hint, Standard, private, no public access) | API token `recovery-vm-azure-archive`: Object Read & Write on this bucket only. Values: `private-data/r2-azure-archive.env` → VM `/root/.r2-azure-archive.env` (0600) → rclone remote `archive` (`/root/.config/rclone/rclone.conf`, root only) |
| Archive passphrase | `ARCHIVE_PASSPHRASE` in `private-data/r2-azure-archive.env` | encrypts every `env` / secret archive (GnuPG symmetric, AES256). **Owner: keep a copy in the password manager** — without it those archives cannot be opened |
| Scripts | `scripts/recovery-vm/` | `01-setup` (volume, PostgreSQL 16 binaries, AzCopy, rclone, bucket test) · `02-disk` (download / inspect / umount / cleanup) · `03-export` (dumps + archives + manifest + upload, per disk) |
| Azure access | `az` CLI on this PC (subscription `Azure subscription 1`) | read only: `az disk grant-access --access-level Read` (4 h SAS, never printed, PC → VM as a 0600 file) and `revoke-access` in `finally`. Nothing in Azure is changed or deleted |

## 3. Bucket layout
```
raiworks-azure-archive/
  <disk>/                       e.g. nmc-php-stage-1-osdisk/
    inspect.txt                 what the disk held (partitions, PostgreSQL clusters, apps, env file names, sizes)
    db/<cluster>/<database>.dump  pg_dump -Fc per database   (+ globals.sql: roles, no passwords → globals-roles.sql)
    db/<cluster>/meta.txt       version, data dir, size, row counts per database
    env.tar.zst.gpg             /etc + every .env / secret file found (encrypted, ARCHIVE_PASSPHRASE)
    code/<app>.tar.zst          /srv/apps/<app>, /opt/<app>, /var/www/<site> (without node_modules / vendor caches)
    files/<what>.tar.zst        uploads, mail data, MinIO objects, home folders
    MANIFEST.sha256             sha256 of every object above (checked after upload)
  _index.md                     one line per disk: date, objects, size
```
Restore anything: `rclone copy archive:raiworks-azure-archive/<disk>/<path> .` (or the Cloudflare dashboard), `pg_restore -d <db> <file>.dump`, `gpg -d env.tar.zst.gpg | zstd -d | tar -x`.

## 4. Disks and status
| # | Disk (resource group) | GB | Expected content | Status |
|---|---|---|---|---|
| 1 | `nmc-php-stage-1-osdisk` (WebServices) | 64 | **`localcen_db` + place packs**, PHP sites + their local DBs, staging apps (NextDocs, RapidBot, AP 2026, WithRajesh, Rajesh Domains, OGCEN, NextBuilder) | 🟡 next |
| 2 | `nmc-db-1-osdisk` (rg-nextdp-data) | 64 | PostgreSQL primary: every fleet database to the last minute | ⏳ |
| 3 | `nmc-apps-1-osdisk` (WebServices) | 64 | Go apps: `.env`s (old SMS `APP_KEY`, Firebase key), uploads | ⏳ |
| 4 | `WorkStation_DataDisk_0` (WorkStation, unattached, **NTFS**) | 128 | the old Azure workstation's `E:` (workspace, `temp/` incl. LocalCen's geo packs, tools) | ⏳ |
| 5 | `nmc-s3-1-data` (rg-nextdp-data, unattached) | 64 | MinIO objects (Associate Works files) | ⏳ |
| 6 | `nmc-idp-1-osdisk` (WebServices) | 64 | Next iDP + Next Pay env, storage | ⏳ |
| 7 | `nmc-mail-1-osdisk` (Email) | 30 | NextDP Mail env + mail files | ⏳ |
| 8 | `nmc-main-osdisk` (rg-nmc-control) | 30 | NextManager Core (DB already recovered once, `azure-r2-restore.md`) | ⏳ |
| 9 | `nmc-db-2-osdisk` (rg-nextdp-data) | 64 | the standby replica (a second copy of #2) | ⏳ |
| 10 | `nmc-dns-1-osdisk` (DNS) | 30 | PowerDNS (its `pdns` DB was dumped 2026-11-20, `azure-r2-dns-zones.md`) | ⏳ |
| 11 | `nmc-dns-2-osdisk` (DNS) | 30 | PowerDNS ns2 | ⏳ |
| 12 | `esangh-dev-1_OsDisk_1_…` (esangh-dev-rg, unattached) | 64 | eSangh dev server | ⏳ |

Total provisioned 696 GB; only used blocks are downloaded. Not on any disk any more: `nmc-cache-1` (Redis, nothing to keep).

## 5. Procedure per disk (from this PC, `E:\workspace\aws-setup-and-migrations`)
1. `.\scripts\recovery-vm\02-disk.ps1 -Disk <disk> -Mode download` — 4 h read SAS, AzCopy to `/work/disks/<disk>/disk.vhd` (size + VHD footer checked), SAS revoked.
2. `.\scripts\recovery-vm\02-disk.ps1 -Disk <disk> -Mode inspect` — read-only loop device, `ro,noload` mounts, `inspect.txt` (PostgreSQL clusters and versions, apps, env file names, sizes). Decide the export list from it (owner sees it in the chat).
3. `.\scripts\recovery-vm\03-export.ps1 -Disk <disk>` — per PostgreSQL cluster: copy the data dir to `/work/tmp`, start it as a temporary cluster on a private socket (never the disk itself), `pg_dump -Fc` every database + roles; archives of env / code / files; `MANIFEST.sha256`; upload with rclone; re-download the manifest and check every object's size + sha256.
4. `.\scripts\recovery-vm\02-disk.ps1 -Disk <disk> -Mode cleanup` — unmount, detach, delete the VHD (the exports in `/work/out/<disk>` stay until the next disk needs the room).
5. Update §4 and §7; commit + push.

Safety rules: Azure read only; the disk image is never mounted writable; secrets are only in the encrypted `env` archive and in `private-data/` (never printed, never in git); nothing is written to `nxtmngr-test/prod-main`; every step is repeatable.

## 6. After the archive (follow-ups)
- **LocalCen places** (from disk 1): load `geo_areas` / `geo_links` / `geo_sync_runs` (or the packs in `shared/geo-packs`) into `localcen_db` on LocalCen-1-VM — backup first, `localcen geo status` after. Then the owner sets up `lewiai.com`'s place.
- Old SMS service `APP_KEY` + Firebase key (disk 3) → the owner decides whether to bring back old message bodies / push.
- Terminate Recovery-VM + its volume; delete the R2 token (or let its TTL end); a read-only token for restores when needed.
- Lifecycle on the bucket: Standard → Infrequent Access after the restores are done.
- Decide with the owner whether the Azure disks can then be deleted (not before every row in §4 is ✅ and spot-restored).

## 7. Log
- **2026-11-21** — Disks listed (read-only `az`): 12 disks, 696 GB, all VMs deallocated (table §4). Price check (web): R2 Standard $0.015 / GB-month and free egress vs S3 Mumbai Standard $0.025 / Glacier IR $0.005 + egress; GCS similar to S3 with $0.12 / GB egress → R2.
- **2026-11-21** — Owner made Recovery-VM `16.4.71.66` (EC2 m6i.large, 20 GB root + 250 GB gp3) and the bucket `raiworks-azure-archive` + token (in `private-data/r2-azure-archive.env`); agent added `ARCHIVE_PASSPHRASE` (generated on the PC, not shown). `01-setup`: `/dev/nvme1n1` → ext4 `work` on `/work` (246 GB free), PostgreSQL 16.15 binaries (default cluster dropped, nothing listening), AzCopy 10.34.2, rclone 1.76.0, GnuPG 2.4.4; bucket test write / read / sha256 / delete OK (bucket empty). First run stopped on `pg_dropcluster --stop` of a stopped cluster — fixed, rerun clean.
