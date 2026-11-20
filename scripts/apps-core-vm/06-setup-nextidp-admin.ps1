# Bootstrap Next iDP master admin (rajesh@nextidp.com) on Apps-Core-VM (43.204.42.99),
# verify DB + API login, and pull credentials to local gitignored private-data/.
param(
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "06-setup-nextidp-admin.sh")

if (-not $SkipPull) {
    & (Join-Path $PSScriptRoot "pull-nextidp-credentials.ps1")
}
