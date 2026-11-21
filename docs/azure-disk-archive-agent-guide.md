# Agent guide — continue the Azure disk archive (any IDE / AI agent)

> For an agent that picks up the Azure → R2 archive in its own chat while other work (LocalCen, NextDP Core, Next iDP) goes on elsewhere. Written 2026-11-21 after disk 1 was done. **The plan, status table and log live in [`azure-disk-archive.md`](azure-disk-archive.md); this file tells you how to work on it.** Keep both current.

## 1. Read first (in this order)
1. `E:\workspace\AGENTS.md` — workspace map, secret rules (§5), git safety (§6). The live infra is AWS (§4.0); the Azure fleet (§4) is suspended.
2. `E:\workspace\.kiro\steering\aws-infra-memory.md` (if your tool shows it) — the owner's working rules for this repo.
3. [`azure-disk-archive.md`](azure-disk-archive.md) — **▶ Resume here** line, §2 pieces, §3 bucket layout, §4 disk table (pick the first ⏳ row), §5 procedure, §7 log (disk 1 is the worked example, with the problems met and fixed).
4. The scripts you run: `scripts/recovery-vm/01-setup.*`, `02-disk.*`, `03-export.*` (read the `.sh` headers).
5. Background only when needed: [`vms-setup-and-services-and-all-info.md`](vms-setup-and-services-and-all-info.md) (the Recovery-VM row), [`azure-r2-restore.md`](azure-r2-restore.md) (the older R2 restic dumps in `nxtmngr-test/prod-main` — read-only, never write there).

## 2. What you need on the PC
| Need | Check |
|---|---|
| Azure CLI logged in | `az account show` → `Azure subscription 1`, state Enabled |
| `private-data/vms-details.txt` has **Recovery-VM** (`16.4.71.66`, key `private-data/dithim-aws.pem`) | `. .\scripts\mail-vm\common.ps1; Get-VmTarget -Name "Recovery-VM"` |
| `private-data/r2-azure-archive.env` (bucket, endpoint, token, `ARCHIVE_PASSPHRASE`) | key names only — **never print the values** |
| Recovery-VM set up (`/work`, PostgreSQL 16 binaries, AzCopy, rclone, remote `archive`) | `.\scripts\recovery-vm\01-setup.ps1` is repeatable and ends with a bucket write / read test |

Run everything from `E:\workspace\aws-setup-and-migrations` in Windows PowerShell 5.1 (`powershell -NoProfile -ExecutionPolicy Bypass -File …`). PS 5.1 treats native stderr as an error: scripts set `$ErrorActionPreference='Continue'` where `az` / `ssh` write to stderr.

## 3. One disk = three commands
```
.\scripts\recovery-vm\02-disk.ps1   -Disk <disk> -Mode download -ResourceGroup <rg>   # ~20-25 min for 64 GB
.\scripts\recovery-vm\02-disk.ps1   -Disk <disk> -Mode inspect                         # read-only report
.\scripts\recovery-vm\03-export.ps1 -Disk <disk>                                       # pg env code files upload (or -Step one)
.\scripts\recovery-vm\02-disk.ps1   -Disk <disk> -Mode cleanup                         # delete the VHD copy
```
Disk names and resource groups: §4 of the archive doc. After each disk: show the owner the `inspect` summary and the export result (databases with sizes, object count, `rclone check` = 0 differences), then update §4 + §7 and commit.

## 4. Rules (owner's, non-negotiable)
- **Azure is read only.** Only `az disk show / grant-access --access-level Read / revoke-access`. Never start, delete, resize or change a VM or disk. The SAS is never printed and is revoked in `finally` (the script does it — if a run is killed, run `az disk revoke-access -g <rg> -n <disk>` yourself).
- **Ask the owner before any Azure step that is not in this guide.**
- One disk at a time on Recovery-VM (246 GB work volume). **Only one agent uses Recovery-VM at a time.**
- Secrets: never print or commit them. Env / key files go only into the encrypted `env.tar.zst.gpg`. Owner decision 2026-11-21: database dumps, code and files stay unencrypted `.dump` / `.tar.zst`.
- Never write to R2 `nxtmngr-test/prod-main/`. Everything goes to `raiworks-azure-archive/<disk>/`.
- Don't create extra users, VMs or buckets; don't change the live AWS VMs. Stop when the owner says stop.
- Plain, short reports to the owner: what was done, the numbers, what is next.

## 5. Git (two agents, one repo)
- This work touches **only** `docs/azure-disk-archive.md`, `docs/azure-disk-archive-agent-guide.md`, `scripts/recovery-vm/*` and the TODO line `1.0b`. The other chat (LocalCen / NextDP Core / Next iDP) touches the rest — don't edit its files.
- Before every commit: `git pull --rebase origin main`; commit only the files you changed (`git add <files>`, never `git add -A`); push `main` right after. Never force push, never `reset --hard`, never `git clean`.
- Scratch files go in `temp/` (gitignored).

## 6. Disks still to do and what to watch for
| Disk | Watch for |
|---|---|
| ~~`nmc-db-1-osdisk`~~ ✅ 2026-11-21 | done: 11 databases. Loose manual `*.dump` files in `/var/lib/postgresql/` are now packed by `step_files` (`files/var-lib-postgresql-dumps.tar.zst`) |
| ~~`nmc-apps-1-osdisk`~~ ✅ 2026-11-21 | done: secret JSONs (Firebase, GCP) sit in `/etc/<app>/` → in the env archive; check other disks for `*.json` keys outside `/etc` the same way (§7 of the archive doc) |
| `WorkStation_DataDisk_0` | **NTFS data disk, no Linux root** (`/etc/os-release` missing) → `03-export.sh` stops with "no mounted root filesystem". Needs a small new step: archive the mounted NTFS volume per top-level folder (e.g. `workspace/<repo>.tar.zst`), env / key files into the env archive. Add it to `03-export.sh` (e.g. `STEP=data`), test, log it |
| `nmc-s3-1-data` | **data disk, no OS** (MinIO objects) → same as above: archive per bucket folder |
| `esangh-dev-1_OsDisk_…` | unattached OS disk; normal path |
| `nmc-db-2-osdisk` | the standby replica: its data dir has `standby.signal`; the temporary cluster starts in recovery (read-only), `pg_dump` still works. If it does not start, compare with db-1 and log it |
| `nmc-idp-1`, `nmc-mail-1`, `nmc-main`, `nmc-dns-1/-2` | normal path; a PostgreSQL other than 16 is skipped with a message — install `postgresql-<ver>` (PGDG apt) on Recovery-VM and rerun `-Step pg` |

## 7. When everything is ✅
Tell the owner, then (only with the owner's word): terminate Recovery-VM **and its 250 GB volume**, let the R2 token expire (or delete it), set the bucket lifecycle (Standard → Infrequent Access), and decide about deleting the Azure disks (not before every row in §4 is ✅ and spot-restored).
