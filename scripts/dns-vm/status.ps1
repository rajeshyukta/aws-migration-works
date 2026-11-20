# Check services, dual-IP DNS listeners, PowerDNS API, and dns-service health on DNS VM (52.66.165.1)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget -Name "DNS VM"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "status-remote.sh")
