# Azure disk archive — every old Azure disk into one private R2 bucket

> **Owner**: Rajesh · **Started**: 2026-11-21 · **Status**: 🟡 in progress — 1 of 12 disks done · keep this file current: every run updates §4 (status), §7 (log) and, if something changed, §5 (procedure).
> **Working on it from another chat / IDE?** Read [`azure-disk-archive-agent-guide.md`](azure-disk-archive-agent-guide.md) first.
> **▶ Resume here**: disk 1 **`nmc-php-stage-1-osdisk` ✅** (2026-11-21: 18 databases, envs, code, files in the bucket, verified; LocalCen's places loaded on LocalCen-1-VM). Next: disk 2 **`nmc-db-1-osdisk`** with the same three commands (§5). Owner task open: copy `ARCHIVE_PASSPHRASE` into the password manager (TODO).

## 1. Why
The Azure subscription was disabled on 2026-11-18 and the services were rebuilt on AWS (`vms-setup-and-services-and-all-info.md`). The R2 restic repo `nxtmngr-test/prod-main` holds daily dumps of most fleet databases (`azure-r2-restore.md`), but not everything: LocalCen's `localcen_db` (place data), several staging databases, every `.env` / secret, app code and uploads were only on the VM disks. The 12 Azure managed disks still exist (the VMs are deallocated). This work copies **all of them, once, into our own bucket**, so any old database, env or file can be restored later without Azure.

Owner decisions (2026-11-21): only the `env` archive is encrypted — database dumps, code and files stay plain `.dump` / `.tar.zst` (private bucket, bucket-only token, R2 encryption at rest); one `.tar.zst` per app / site folder; archive all disks; a temporary recovery VM on AWS; a new R2 bucket (cheapest with free download, see the price check of 2026-11-21 in the chat: R2 Standard $0.015 / GB-month, no egress); first disk `nmc-php-stage-1` (LocalCen).

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
| 1 | `nmc-php-stage-1-osdisk` (WebServices) | 64 | **`localcen_db` + place packs**, PHP sites + their local DBs, staging apps (NextDocs, RapidBot, AP 2026, WithRajesh, Rajesh Domains, OGCEN, NextBuilder) | ✅ 2026-11-21 — 132 objects, 2.0 GB (§7) |
| 2 | `nmc-db-1-osdisk` (rg-nextdp-data) | 64 | PostgreSQL primary: every fleet database to the last minute | 🟡 next |
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
- ✅ **LocalCen places** (from disk 1, 2026-11-21): the packs `36-2026-11-08` + `28-2026-11-08` loaded with `scripts/localcen-1-vm/07-import-geo-packs` (§7). Owner: set up `lewiai.com`'s place.
- Old SMS service `APP_KEY` + Firebase key (disk 3) → the owner decides whether to bring back old message bodies / push.
- Terminate Recovery-VM + its volume; delete the R2 token (or let its TTL end); a read-only token for restores when needed.
- Lifecycle on the bucket: Standard → Infrequent Access after the restores are done.
- Decide with the owner whether the Azure disks can then be deleted (not before every row in §4 is ✅ and spot-restored).

## 7. Log
- **2026-11-21** — Disks listed (read-only `az`): 12 disks, 696 GB, all VMs deallocated (table §4). Price check (web): R2 Standard $0.015 / GB-month and free egress vs S3 Mumbai Standard $0.025 / Glacier IR $0.005 + egress; GCS similar to S3 with $0.12 / GB egress → R2.
- **2026-11-21** — Owner made Recovery-VM `16.4.71.66` (EC2 m6i.large, 20 GB root + 250 GB gp3) and the bucket `raiworks-azure-archive` + token (in `private-data/r2-azure-archive.env`); agent added `ARCHIVE_PASSPHRASE` (generated on the PC, not shown). `01-setup`: `/dev/nvme1n1` → ext4 `work` on `/work` (246 GB free), PostgreSQL 16.15 binaries (default cluster dropped, nothing listening), AzCopy 10.34.2, rclone 1.76.0, GnuPG 2.4.4; bucket test write / read / sha256 / delete OK (bucket empty). First run stopped on `pg_dropcluster --stop` of a stopped cluster — fixed, rerun clean.
- **2026-11-21 — disk 1 `nmc-php-stage-1-osdisk` ✅.** `02-disk -Mode download`: 4 h read SAS, AzCopy 64 GiB in 21.6 min, VHD footer OK, SAS revoked. (First try: `az disk list` needs `-g` on this CLI → the script searches each group; `-ResourceGroup WebServices` passed.) `-Mode inspect` (run as root after a first run could not read `/work/disks`, 0700): Ubuntu 24.04.5, 16 GB used; PostgreSQL 16 `/var/lib/postgresql/16/main` 865 MB; MySQL `/var/lib/mysql` 201 MB; Redis 8 KB; SQLite files in 10 PHP / static sites; apps `/srv/apps/{aple26,localcen,masterymd.com,nextdocs}`, `/srv/goapps/{nextbuilder,withplatform}`, `/srv/phpapps/*` (64 sites), `/srv/static/*` (37), `/srv/rapidbot`, `/srv/old-bot`, `/opt/nextmanager-core`; ~90 env / key files (names in `inspect.txt`). `03-export`:
  - **pg** — 18 databases (temporary cluster on a copy, private socket): `aple26` 20 MB · `cconsole_hub` 11 MB · `domains_rajesh` 138 MB · **`localcen_db` 210 MB (46 tables, ~560,000 rows: `geo_areas`, `geo_links`, `geo_sync_runs`, `local_wards`, …)** · `nareng` · `nextbuilder` · `nextdocs_db` · `nextdp_qaportal` · `nextdp_rajeshyukta` · `postgres` · `promoji` · `promoji_test` · `promptation_db` · `raiworks` · `supportfor` · `whfya` · `withplatform` · `withrajesh`; plus `globals-roles.sql` (roles, no passwords) and `meta.txt` (sizes, rows).
  - **env** — `/etc`, `/root` + 249 env / key / certificate files → `env.tar.zst.gpg` 33 MB (first run stopped: `find` on a folder the disk does not have → fixed). **code** — 116 archives (largest `srv/apps/localcen` 782 MB incl. its geo packs and releases, `nextdocs` 390 MB, `withplatform` 214 MB); env / key files left out of them. **files** — `var-lib` (MySQL raw files, Redis, Caddy data; without PostgreSQL) 36 MB, `var-backups`, `home`, `usr-local`.
  - **upload** — 131 files + manifest, 2.0 GB → `raiworks-azure-archive/nmc-php-stage-1-osdisk/`; `rclone check --download`: 0 differences, 132 matching. Restore test **from the bucket**: `env.tar.zst.gpg` decrypts with `ARCHIVE_PASSPHRASE` (3,062 entries); `localcen_db.dump` lists 46 tables with data incl. the geo tables. `-Mode cleanup`: VHD deleted, `/work` back to 2 GB used (exports kept).
  - MySQL is archived as raw data files only (inside `files/var-lib.tar.zst`). **Owner 2026-11-21: MySQL is mostly not needed** — no `mysqldump`; if a MySQL app is ever restored, start the same MySQL version on a copy of those files.
- **2026-11-21 — LocalCen places loaded** (owner: "Places for your state are not loaded yet"). The archive's `code/srv/apps/localcen.tar.zst` holds the packs LocalCen imported on Azure (`shared/geo-packs/{36,28}-2026-11-0{7,8}`); the newest per state (`36-2026-11-08` Telangana, `28-2026-11-08` Andhra Pradesh) copied to `D:\nmc-backup\localcen-geo-packs\` and loaded on LocalCen-1-VM with `scripts/localcen-1-vm/07-import-geo-packs -Apply` (`localcen_db` dump first: `/var/backups/localcen/pre-geo-import-20261121T090901Z/`): Andhra Pradesh 278,696 areas / 81,705 links (28 districts, 688 mandals, 17,957 villages, 13,327 GPs, 241,107 panchayat wards, 124 towns, 3,923 town wards, 175 + 25 constituencies), Telangana 142,366 / 56,913 (33 districts, 621 mandals, 11,450 villages, 12,760 GPs, 112,534 panchayat wards, 161 towns, 3,453 town wards, 119 + 17). `localcen geo status` shows both, data 2026-11-08.
