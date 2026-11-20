# Base setup of LocalCen-1-VM (3.111.132.3). Idempotent; safe to re-run.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "LocalCen-1-VM"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "01-server-setup.sh")
