# Restore nextdp_mail PostgreSQL database from Cloudflare R2 (restic snapshot or raw dump).
param(
    [string]$RepoPrefix = "",
    [string]$SnapshotId = "",
    [string]$RawObjectKey = "",
    [string]$R2EnvPath = "",
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $RawObjectKey -and (-not $RepoPrefix -or -not $SnapshotId)) {
    throw "Specify either (-RepoPrefix <prefix> -SnapshotId <id>) or (-RawObjectKey <key>)."
}

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
if (-not $R2EnvPath) {
    $R2EnvPath = Join-Path $repoRoot "private-data\r2.env"
}
if (-not (Test-Path $R2EnvPath)) {
    throw "Missing $R2EnvPath."
}

$vm = Get-VmTarget -RepoRoot $repoRoot
$remoteEnv = "/tmp/.r2.env"
$startFlag = if ($NoStart) { "0" } else { "1" }

Copy-ToVm -Vm $vm -LocalPath $R2EnvPath -RemotePath $remoteEnv
Invoke-VmCommand -Vm $vm -Command "chmod 600 $remoteEnv"
try {
    $envPrefix = "R2_ENV_FILE=$remoteEnv REPO_PREFIX=$RepoPrefix SNAPSHOT_ID=$SnapshotId RAW_OBJECT_KEY=$RawObjectKey START_SERVICES=$startFlag"
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "04-restore-r2-db.sh") `
        -EnvPrefix $envPrefix
} finally {
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes $vm.Target "rm -f $remoteEnv" 2>$null
}
