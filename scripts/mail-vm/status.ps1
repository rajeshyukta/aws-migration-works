# Check health, listeners, HTTPS endpoints, TLS certs, and DB counts on the Mail VM.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$vm = Get-VmTarget
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "status-remote.sh")
