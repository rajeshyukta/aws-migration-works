# Build LocalCen (3 SPAs + linux/amd64 Go binary) and deploy onto Apps-Core-VM (43.204.42.99, :8092)
param(
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$lcRepo = "E:\workspace\projects\platform\localcen"
if (-not (Test-Path $lcRepo)) { throw "localcen repo missing: $lcRepo" }

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("localcen-stage-$PID")
$tar = Join-Path ([System.IO.Path]::GetTempPath()) ("localcen-release-$PID.tar.gz")
$remoteStage = "/tmp/localcen-stage-$PID"

try {
    if (-not $SkipFrontendBuild) {
        Write-Host "==> Building LocalCen SPAs (admin + tenant + app)..."
        Push-Location (Join-Path $lcRepo "frontend")
        try {
            $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = "0"
            & pnpm install --frozen-lockfile
            if ($LASTEXITCODE -ne 0) { throw "pnpm install failed" }
            & pnpm build:admin
            if ($LASTEXITCODE -ne 0) { throw "admin build failed" }
            & pnpm build:tenant
            if ($LASTEXITCODE -ne 0) { throw "tenant build failed" }
            & pnpm build:app
            if ($LASTEXITCODE -ne 0) { throw "app build failed" }
        } finally {
            Pop-Location
        }
    }

    foreach ($p in @("frontend\admin\dist\index.html", "frontend\tenant\dist\index.html", "frontend\app\dist\index.html")) {
        if (-not (Test-Path (Join-Path $lcRepo $p))) { throw "Missing dist: $p" }
    }

    Write-Host "==> Embedding app dist into backend/resources/app..."
    $embedDir = Join-Path $lcRepo "backend\resources\app"
    Remove-Item (Join-Path $embedDir "*") -Recurse -Force
    Copy-Item -Recurse (Join-Path $lcRepo "frontend\app\dist\*") $embedDir

    New-Item -ItemType Directory -Force -Path (Join-Path $stage "consoles") | Out-Null
    Write-Host "==> Building LocalCen Go binary (linux/amd64)..."
    $stamp = (git -C $lcRepo rev-parse --short HEAD).Trim() + "-" + (Get-Date -Format "yyyyMMddHHmm")
    $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
    try {
        & go -C (Join-Path $lcRepo "backend") build -trimpath -ldflags "-s -w -X github.com/raiworks/localcen/app/idp.BuildVersion=$stamp" -o (Join-Path $stage "localcen") ./cmd
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
    } finally {
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        & git -C $lcRepo checkout -- backend/resources/app/index.html 2>$null
    }

    Copy-Item -Recurse (Join-Path $lcRepo "frontend\admin\dist") (Join-Path $stage "consoles\admin")
    Copy-Item -Recurse (Join-Path $lcRepo "frontend\tenant\dist") (Join-Path $stage "consoles\tenant")
    & tar -czf $tar -C $stage localcen consoles
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    Write-Host "==> Uploading & deploying LocalCen to $($vm.Target)..."
    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath $tar -RemotePath "$remoteStage/localcen-release.tar.gz"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $lcRepo "deploy\caddy-hosts-sync.sh") -RemotePath "$remoteStage/caddy-hosts-sync.sh"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $lcRepo "deploy\caddy-hosts-setup.sh") -RemotePath "$remoteStage/caddy-hosts-setup.sh"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $lcRepo "deploy\cleanup-setup.sh") -RemotePath "$remoteStage/cleanup-setup.sh"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "05-deploy-localcen.sh") `
        -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -rf $remoteStage" 2>$null
}
