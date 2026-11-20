# Check services, ports, local health, and Caddy routing on Apps-Core-VM (43.204.42.99)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -Name "Apps-Core-VM"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "status-remote.sh")
