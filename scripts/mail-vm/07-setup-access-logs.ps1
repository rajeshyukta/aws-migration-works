# Deploy trimmed Caddy JSON access logging + nightly IST daily archive & domain summary on Mail VM.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot

$caddyfile = Join-Path $repoRoot "templates\Caddyfile.mail-vm"
$archivePy = Join-Path $repoRoot "templates\caddy\nextdp-traffic-archive.py"

foreach ($p in @($caddyfile, $archivePy)) {
    if (-not (Test-Path $p)) {
        throw "Required template missing: $p"
    }
}

$remoteStage = "/tmp/nextdp-logs-stage-$PID"
Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage"
try {
    Copy-ToVm -Vm $vm -LocalPath $caddyfile -RemotePath "$remoteStage/Caddyfile"
    Copy-ToVm -Vm $vm -LocalPath $archivePy -RemotePath "$remoteStage/nextdp-traffic-archive.py"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "07-setup-access-logs.sh") `
        -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -rf $remoteStage" 2>$null
}
