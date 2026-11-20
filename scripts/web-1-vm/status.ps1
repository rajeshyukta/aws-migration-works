# Run full health and routing check on Lightsail Web-1 (3.6.143.66)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "Web-1"
Write-Host "Checking $($vm.Name) ($($vm.Target))..."
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "status-remote.sh")
