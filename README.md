# AWS Migration Works (`aws-migration-works`)

Standalone AWS Lightsail provisioning, Cloudflare R2 backup recovery, and deployment runbooks for migrating critical services off the suspended Azure `nmc-*` fleet without requiring NextManager Core (`nmc-main`) or central DB/Redis nodes.

## Current Migration Priority

| Order | Service | Source Repo | Target Host | Status |
|---|---|---|---|---|
| 1 | **NextDP Mail** | `E:\workspace\projects\platform\nextdp-mail` | AWS Lightsail (`52.66.111.138`) | In Progress |

## Directory Layout

- `docs/` — Architecture notes, VM runbooks, and DNS cutover checklists
- `templates/` — Reference Caddyfile, `.env.mail-vm.example`, and `r2.env.example` (no secrets)
- `scripts/mail-vm/` — Idempotent setup, build/deploy, R2 inspection/restore, and status check scripts
- `private-data/` — Gitignored SSH keys (`.pem`), `vms-details.txt`, and `r2.env`

## Quick Start (Mail VM)

1. Read [docs/mail-vm-runbook.md](docs/mail-vm-runbook.md) and [docs/dns-checklist.md](docs/dns-checklist.md).
2. Provision base stack on Lightsail VM (`01-server-setup.sh` via `02-build-and-deploy.ps1`).
3. Create `private-data/r2.env` from `templates/r2.env.example` and inspect `nxtmngr-test` via `scripts/mail-vm/03-check-r2.ps1`.
4. Restore `nextdp_mail` database via `scripts/mail-vm/04-restore-r2-db.ps1` and verify via `scripts/mail-vm/status.ps1`.
