# Decrypt nextmanager_core backup_targets using JWT_SECRET from private-data\nmc-main-env.txt
# and test live Cloudflare R2 restic repository accessibility, integrity, snapshots, and pg_restore usability.
# Never echoes secrets.
param(
    [string]$EnvPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
if (-not $EnvPath) {
    $EnvPath = Join-Path $repoRoot "private-data\nmc-main-env.txt"
}
if (-not (Test-Path -LiteralPath $EnvPath)) {
    throw "Missing env file: $EnvPath"
}

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Mail VM"
$remoteEnv = "/tmp/.nmc-main-env-$PID"

Copy-ToVm -Vm $vm -LocalPath $EnvPath -RemotePath $remoteEnv
Invoke-VmCommand -Vm $vm -Command "chmod 600 $remoteEnv"
try {
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "03b-check-nmc-r2-backups.sh") `
        -EnvPrefix "NMC_ENV_FILE=$remoteEnv"
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -f -- $remoteEnv"
}
