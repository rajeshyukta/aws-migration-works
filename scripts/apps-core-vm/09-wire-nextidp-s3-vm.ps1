# Wire AWS S3 credentials from private-data\nextidp-s3.env onto Apps-Core-VM (43.204.42.99)
# /etc/nextidp/env, restart nextidp + nextidp-worker, verify boot logs, and refresh pulled credentials.
param(
    [string]$S3EnvPath = "",
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
if (-not $S3EnvPath) {
    $S3EnvPath = Join-Path $repoRoot "private-data\nextidp-s3.env"
}
if (-not (Test-Path -LiteralPath $S3EnvPath)) {
    throw "S3 env file not found: $S3EnvPath (run 08-provision-nextidp-s3-aws.ps1 first)"
}

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$remoteTmp = "/tmp/awsmig-s3env-$PID.env"
Copy-ToVm -Vm $vm -LocalPath $S3EnvPath -RemotePath $remoteTmp
Invoke-VmCommand -Vm $vm -Command "chmod 0600 $remoteTmp"

Invoke-VmScript -Vm $vm `
    -LocalScriptPath (Join-Path $PSScriptRoot "09-wire-nextidp-s3-vm.sh") `
    -ScriptArgs $remoteTmp

if (-not $SkipPull) {
    & (Join-Path $PSScriptRoot "pull-nextidp-credentials.ps1")
}
