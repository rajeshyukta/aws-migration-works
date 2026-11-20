# AWS Migration Works (`aws-migration-works`)

Setup scripts, Caddy/systemd templates, runbooks and backup tooling for the **4 AWS VMs** that run all live services since the Azure subscription was disabled (2026-11-18). Each VM is standalone: local PostgreSQL 16, Redis, Caddy, systemd, its own off-site backup. There is no NextManager Core.

**Start here: [`docs/vms-setup-and-services-and-all-info.md`](docs/vms-setup-and-services-and-all-info.md)** (what runs where, ports, domains, databases, backups, secret locations, risks). Open work: [`docs/TODO.md`](docs/TODO.md).

## VMs

| VM | Public IP | Runs | Scripts |
|---|---|---|---|
| Mail VM (Lightsail) | `52.66.111.138` | NextDP Mail, dithim.com, catch-all maintenance page | `scripts/mail-vm/` |
| Web-1 (Lightsail) | `3.6.143.66` | PHP 8.4 + static sites, domains.rajesh.app, CConsole Hub | `scripts/web-1-vm/` |
| Apps-Core-VM (EC2) | `43.204.42.99` | Next iDP, NextDP Core, LocalCen | `scripts/apps-core-vm/` |
| DNS VM (EC2) | `52.66.165.1` / `52.66.25.51` | PowerDNS `ns1/ns2.nextdp.com`, dns-service | `scripts/dns-vm/` |

## Layout

- `docs/`: VM reference, runbooks, TODO, migration records (mail DB upgrade, CConsole Hub move, backups, realms).
- `scripts/<vm>/`: idempotent setup/deploy/status scripts. Each `.ps1` runs from this PC and calls a `.sh` on the VM through `scripts/mail-vm/common.ps1` (`Get-VmTarget -Name "<VM>"`). `scripts/vm-inventory.sh` collects read-only facts for the reference doc.
- `templates/`: Caddyfiles, site files, backup tool (`templates/backup/`), CoreDNS, maintenance page (no secrets).
- `private-data/` (gitignored): SSH key, `vms-details.txt`, `r2.env`, backup passwords, pulled app credentials. Never commit; keep a copy in a password manager + offline.
- `temp/` (gitignored): scratch scripts and command outputs.

## Common commands

```powershell
powershell -NoProfile -File .\scripts\mail-vm\status.ps1          # also web-1-vm, apps-core-vm, dns-vm
. .\scripts\mail-vm\common.ps1; Invoke-VmCommand -Vm (Get-VmTarget -Name "Web-1") -Command "sudo nextdp-offsite-backup status"
powershell -NoProfile -File .\scripts\mail-vm\18-lightsail-firewall.ps1 -WhatIf   # Mail VM firewall (needs aws login)
```
