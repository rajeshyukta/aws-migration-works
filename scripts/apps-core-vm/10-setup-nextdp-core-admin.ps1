# Create platform master_admin account (rajesh@nextdp.com) for core.nextdp.com
# on Apps-Core-VM (43.204.42.99), verify live login, and pull credentials to private-data/.
param(
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "10-setup-nextdp-core-admin.sh")

if (-not $SkipPull) {
    & (Join-Path $PSScriptRoot "pull-nextdp-core-credentials.ps1")
}
