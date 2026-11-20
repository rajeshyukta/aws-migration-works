# Provision Apps-Core-VM (Ubuntu 24.04 EC2 t3.large: swap, PG 16, Redis 7, Caddy 2, UFW, app slots)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "01-server-setup.sh")
