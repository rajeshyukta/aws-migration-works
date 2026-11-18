# Build NextDP Mail (linux/amd64 Go binary + 3 React SPAs) and deploy to AWS Lightsail VM.
param(
    [switch]$RunSetup,
    [switch]$SkipBackend,
    [switch]$SkipFrontend,
    [switch]$StartServices
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$mailRepo = "E:\workspace\projects\platform\nextdp-mail"
if (-not (Test-Path $mailRepo)) {
    throw "NextDP Mail source repo not found: $mailRepo"
}

$vm = Get-VmTarget -RepoRoot $repoRoot
Write-Host "Target VM: $($vm.Target)"

if ($RunSetup) {
    Write-Host "==> Running 01-server-setup.sh on $($vm.IP)..."
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "01-server-setup.sh")
}

$buildDir = Join-Path $repoRoot "build\mail-vm"
if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

if (-not $SkipBackend) {
    Write-Host "==> Building nextdp Go binary (linux/amd64)..."
    $gitVer = (git -C $mailRepo describe --tags --always --dirty 2>$null); if (-not $gitVer) { $gitVer = "dev" }
    $gitCommit = (git -C $mailRepo rev-parse --short HEAD 2>$null); if (-not $gitCommit) { $gitCommit = "unknown" }
    $buildTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $ldflags = "-s -w -X github.com/raiworks/nextdp-mail/app.Version=$gitVer -X github.com/raiworks/nextdp-mail/app.BuildTime=$buildTime -X github.com/raiworks/nextdp-mail/app.GitCommit=$gitCommit"

    $env:GOOS = "linux"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"
    try {
        & go -C (Join-Path $mailRepo "backend") build -ldflags="$ldflags" -o (Join-Path $buildDir "nextdp") ./cmd/...
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
    } finally {
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }
}

if (-not $SkipFrontend) {
    $sharedDir = Join-Path $mailRepo "frontend\shared"
    if (-not (Test-Path (Join-Path $sharedDir "node_modules"))) {
        Write-Host "==> Installing shared frontend dependencies..."
        Push-Location $sharedDir
        try {
            & npm.cmd ci --silent
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed for shared" }
        } finally {
            Pop-Location
        }
    }
    $webStage = Join-Path $buildDir "web"
    New-Item -ItemType Directory -Force -Path $webStage | Out-Null
    foreach ($spa in @("webmail", "admin", "super-admin")) {
        $spaDir = Join-Path $mailRepo "frontend\$spa"
        Write-Host "==> Building SPA: $spa"
        Push-Location $spaDir
        try {
            & npm.cmd ci --silent
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed for $spa" }
            & npm.cmd run build
            if ($LASTEXITCODE -ne 0) { throw "npm run build failed for $spa" }
        } finally {
            Pop-Location
        }
        $dst = Join-Path $webStage $spa
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item -Recurse -Force (Join-Path $spaDir "dist\*") $dst
    }
    Write-Host "==> Packaging web.tar.gz..."
    & tar -czf (Join-Path $buildDir "web.tar.gz") -C $webStage webmail admin super-admin
    if ($LASTEXITCODE -ne 0) { throw "tar web.tar.gz failed" }
}

$remoteStage = "/tmp/nextdp-stage"
Invoke-VmCommand -Vm $vm -Command "rm -rf $remoteStage && mkdir -p $remoteStage"

if (-not $SkipBackend) {
    Write-Host "==> Uploading Go binary..."
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $buildDir "nextdp") -RemotePath "$remoteStage/nextdp"
}
if (-not $SkipFrontend) {
    Write-Host "==> Uploading web.tar.gz..."
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $buildDir "web.tar.gz") -RemotePath "$remoteStage/web.tar.gz"
}

Write-Host "==> Uploading Caddyfile and systemd units..."
Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\Caddyfile.mail-vm") -RemotePath "$remoteStage/Caddyfile"
foreach ($unit in @("nextdp.service", "nextdp-worker.service", "nextdp-scheduler.service")) {
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $mailRepo "deploy\$unit") -RemotePath "$remoteStage/$unit"
}

$startFlag = if ($StartServices) { "1" } else { "0" }
Write-Host "==> Running 02-remote-install.sh (START_SERVICES=$startFlag)..."
Invoke-VmScript -Vm $vm `
    -LocalScriptPath (Join-Path $PSScriptRoot "02-remote-install.sh") `
    -EnvPrefix "STAGE_DIR=$remoteStage START_SERVICES=$startFlag"

Write-Host "==> Deploy finished."
