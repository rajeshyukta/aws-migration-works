# AGENTS.md — AWS Migration Works

> **Repository**: `github.com/rajeshyukta/aws-migration-works` (private) · **Path**: `E:\workspace\aws-setup-and-migrations`
> **Purpose**: Migration runbooks, provisioning scripts, Caddy/systemd templates, and R2 recovery helpers to bring critical services from the stopped Azure `nmc-*` fleet onto standalone AWS Lightsail VMs (without NextManager Core or central DB/Redis).

## 1. Architecture & Operating Rules

1. **Standalone per-VM design (temporary / pragmatic)**:
   - While the Azure subscription ticket is pending, each migrated service runs self-contained on its own AWS Lightsail VM (local PostgreSQL 16, local Redis 7, Caddy 2, systemd).
   - Keep `E:\workspace\projects\*` source repositories pointed at their existing code; store AWS-specific deployment scripts, Caddyfiles, and migration docs here in `aws-setup-and-migrations` until permanent fleet infrastructure is decided.
2. **Hard Secret Gate**:
   - **Never** read, print, copy, or commit secret values from `private-data/`, `.env*`, `r2.env`, or `*.pem`.
   - `private-data/vms-details.txt` holds only non-secret VM connection metadata (`ip`, `user`, `ssh_key` path).
   - Credentials (R2 access keys, `RESTIC_PASSWORD`, `.env` secrets) must be generated on the VM or supplied by the operator into gitignored `private-data/` files that scripts source silently without echoing.
3. **Script & SSH Discipline**:
   - Follow `E:\workspace\WORKSTATIONS.md` §3: resolve `go`, `node`, `npm`, `git`, `ssh`, `scp` from `PATH` first, falling back to `E:\DEV\SOFTS\...` only if `Test-Path` succeeds.
   - Author multi-step remote logic as `.sh` scripts with LF endings (`gitattributes`), upload via `scp` to `/tmp/`, normalize CRLF (`sed -i 's/\r$//'`), and execute via `bash`.
   - Share common PowerShell VM-loading / SSH / SCP helpers in `scripts/mail-vm/common.ps1`.
4. **Database & Backup Safety**:
   - Never run destructive commands (`DROP DATABASE`, `reset --hard`) without confirming what exists first.
   - Do not modify historical records in `E:\workspace\projects\*`.
