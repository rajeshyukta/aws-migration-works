# Inspect Cloudflare R2 bucket contents (and restic snapshots if RESTIC_PASSWORD is set).
param(
    [string]$R2EnvPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
if (-not $R2EnvPath) {
    $R2EnvPath = Join-Path $repoRoot "private-data\r2.env"
}
if (-not (Test-Path $R2EnvPath)) {
    throw "Missing $R2EnvPath. Copy templates\r2.env.example to private-data\r2.env and fill in R2 keys first."
}

$vm = Get-VmTarget -RepoRoot $repoRoot
$remoteEnv = "/tmp/.r2.env"

Copy-ToVm -Vm $vm -LocalPath $R2EnvPath -RemotePath $remoteEnv
Invoke-VmCommand -Vm $vm -Command "chmod 600 $remoteEnv"
try {
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "03-check-r2-remote.sh") `
        -EnvPrefix "R2_ENV_FILE=$remoteEnv"
} finally {
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes $vm.Target "rm -f $remoteEnv" 2>$null
}
