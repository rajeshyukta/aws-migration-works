# Deploy Dithim static site, lightweight Python 3.12 .txt form backend, and Caddy clean-URL routing on the Mail VM.
param(
    [string]$DistDir = "D:\WorkSpace\Dithim\static-website\dist"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot

$caddyfile = Join-Path $repoRoot "templates\Caddyfile.mail-vm"
$backendPy = Join-Path $repoRoot "templates\dithim\dithim-form-backend.py"
$archivePy = Join-Path $repoRoot "templates\caddy\nextdp-traffic-archive.py"

foreach ($p in @($DistDir, $caddyfile, $backendPy, $archivePy)) {
    if (-not (Test-Path $p)) {
        throw "Required path missing: $p"
    }
}
if (-not (Test-Path (Join-Path $DistDir "index.html"))) {
    throw "DistDir does not contain index.html: $DistDir"
}

$tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tarCmd) {
    $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
}
if (-not $tarCmd) {
    throw "tar.exe not found on PATH."
}

$localTar = Join-Path ([System.IO.Path]::GetTempPath()) ("dithim-dist-" + $PID + ".tar.gz")
$remoteStage = "/tmp/dithim-stage-$PID"

try {
    & $tarCmd.Source -czf $localTar --exclude=api --exclude=*.php --exclude=.git --exclude=.env* -C $DistDir .
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $localTar) -or ((Get-Item $localTar).Length -eq 0)) {
        throw "Failed to create dist archive from $DistDir"
    }

    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath $localTar -RemotePath "$remoteStage/dithim-dist.tar.gz"
    Copy-ToVm -Vm $vm -LocalPath $backendPy -RemotePath "$remoteStage/dithim-form-backend.py"
    Copy-ToVm -Vm $vm -LocalPath $caddyfile -RemotePath "$remoteStage/Caddyfile"
    Copy-ToVm -Vm $vm -LocalPath $archivePy -RemotePath "$remoteStage/nextdp-traffic-archive.py"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "08-deploy-dithim.sh") `
        -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    Remove-Item -LiteralPath $localTar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -rf $remoteStage" 2>$null
}
