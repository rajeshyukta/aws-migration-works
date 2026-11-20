# AGENTS.md — AWS Migration Works

> **Repository**: `github.com/rajeshyukta/aws-migration-works` (private) · **Path**: `E:\workspace\aws-setup-and-migrations`
> **Purpose**: Setup/deploy scripts, Caddy/systemd templates, runbooks and backup tooling for the **4 live AWS VMs** (Mail VM, Web-1, Apps-Core-VM, DNS VM) that replaced the disabled Azure `nmc-*` fleet (no NextManager Core, no central DB/Redis).
> **Source of truth:** [`docs/vms-setup-and-services-and-all-info.md`](docs/vms-setup-and-services-and-all-info.md). Open work: [`docs/TODO.md`](docs/TODO.md).

## 0. Boot

1. `git fetch origin --prune; git status -sb`.
2. Read `docs/vms-setup-and-services-and-all-info.md` and `docs/TODO.md`.
3. Connect only to VMs listed in `private-data/vms-details.txt` (via `Get-VmTarget -Name "<VM>"`). Any other IP, including every Azure fleet IP, is unreachable or retired.

## 1. Architecture & Operating Rules

1. **Standalone per-VM design**:
   - Each VM is self-contained (local PostgreSQL 16, Redis, Caddy 2, systemd) and is deployed from this PC over SSH/SCP. This is the production setup, not a stopgap.
   - Keep `E:\workspace\projects\*` source repositories pointed at their existing code; store AWS-specific deployment scripts, Caddyfiles, and runbooks here.
   - **Keep the reference doc current**: any change to a VM, app, domain, database, port, firewall or backup also updates `docs/vms-setup-and-services-and-all-info.md` (and `docs/TODO.md` if it closes or opens work) in the same commit.
2. **Secret Access Gate (Owner-Approved Exception)**:
   - By default, check only file existence/filenames in `private-data/`, `.env*`, `r2.env`, or `*.pem`.
   - **When explicitly approved by the owner in the active chat**, agents may read and work with secret values from `private-data/`, `.env*`, `r2.env`, or `*.pem` to execute approved recovery/migration tasks.
   - Even when approved, **never** print/echo raw secret values in chat responses, logs, or committed files, and **never** commit secrets to git.
   - `private-data/vms-details.txt` holds only non-secret VM connection metadata (`ip`, `user`, `ssh_key` path).
   - Credentials (R2 access keys, `RESTIC_PASSWORD`, `.env` secrets) should stay in gitignored `private-data/` or directly on the VM.
3. **Script & SSH Discipline**:
   - Follow `E:\workspace\WORKSTATIONS.md` §3: resolve `go`, `node`, `npm`, `git`, `ssh`, `scp` from `PATH` first, falling back to `E:\DEV\SOFTS\...` only if `Test-Path` succeeds.
   - Author multi-step remote logic as `.sh` scripts with LF endings (`gitattributes`), upload via `scp` to `/tmp/`, normalize CRLF (`sed -i 's/\r$//'`), and execute via `bash`.
   - Share common PowerShell VM-loading / SSH / SCP helpers in `scripts/mail-vm/common.ps1`.
4. **Database & Backup Safety**:
   - Never run destructive commands (`DROP DATABASE`, `reset --hard`) without confirming what exists first.
   - Do not modify historical records in `E:\workspace\projects\*`.
   - Off-site backups: one restic repo per VM on R2 (`nxtmngr-test/aws-*`), installed with `scripts/mail-vm/16-setup-offsite-backup.ps1` (+ `scripts/web-1-vm/07-*`). Never delete or regenerate a `private-data/*-offsite-backup.env`: a new password cannot open an existing repo. **Never write to `nxtmngr-test/prod-main/`** (old NMC backups, read-only history).
5. **Network / firewall**:
   - Expose only the ports a VM serves publicly. Lightsail VMs use the Lightsail firewall (Mail VM: `scripts/mail-vm/18-lightsail-firewall.ps1`), EC2/Web-1 use `ufw`. App ports (8080/8090/…) stay behind Caddy.
   - AWS CLI calls need `aws login` (session expires). Save the current rules before replacing them.
