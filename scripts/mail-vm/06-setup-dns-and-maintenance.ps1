# Deploy CoreDNS authoritative wildcard DNS + Caddy catch-all maintenance site on Mail VM.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot

$corefile = Join-Path $repoRoot "templates\coredns\Corefile.mail-vm"
$maintHtml = Join-Path $repoRoot "templates\maintenance\index.html"
$askScript = Join-Path $repoRoot "templates\caddy\nextdp-tls-ask.py"
$caddyfile = Join-Path $repoRoot "templates\Caddyfile.mail-vm"

foreach ($p in @($corefile, $maintHtml, $askScript, $caddyfile)) {
    if (-not (Test-Path $p)) {
        throw "Required template missing: $p"
    }
}

$remoteStage = "/tmp/nextdp-dns-stage-$PID"
Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage"
try {
    Copy-ToVm -Vm $vm -LocalPath $corefile -RemotePath "$remoteStage/Corefile"
    Copy-ToVm -Vm $vm -LocalPath $maintHtml -RemotePath "$remoteStage/index.html"
    Copy-ToVm -Vm $vm -LocalPath $askScript -RemotePath "$remoteStage/nextdp-tls-ask.py"
    Copy-ToVm -Vm $vm -LocalPath $caddyfile -RemotePath "$remoteStage/Caddyfile"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "06-setup-dns-and-maintenance.sh") `
        -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -rf $remoteStage" 2>$null
}
