# Run consolidated base setup on DNS-VM (52.66.165.1)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -Name "DNS VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "01-server-setup.sh")
