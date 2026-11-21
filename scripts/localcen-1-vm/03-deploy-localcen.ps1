# Build LocalCen (3 SPAs + linux/amd64 Go binary) from E:\workspace\projects\platform\localcen and deploy it to
# LocalCen-1-VM (3.111.132.3, :8092). Repeatable. -SkipFrontendBuild reuses the existing frontend/*/dist.
param([switch]$SkipFrontendBuild)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "LocalCen-1-VM"
$lcRepo = "E:\workspace\projects\platform\localcen"
if (-not (Test-Path $lcRepo)) { throw "localcen repo missing: $lcRepo" }
$stage = Join-Path ([IO.Path]::GetTempPath()) "localcen-stage-$PID"
$tar = Join-Path ([IO.Path]::GetTempPath()) "localcen-release-$PID.tar.gz"
$remoteStage = "/tmp/localcen-stage-$PID"

try {
    if (-not $SkipFrontendBuild) {
        Write-Host "==> Building SPAs (admin, tenant, app)"
        Push-Location (Join-Path $lcRepo "frontend")
        try {
            $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = "0"
            # pnpm writes warnings to stderr; PowerShell 5.1 would stop on them, so judge by exit code only.
            $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try {
                foreach ($c in @("install --frozen-lockfile", "build:admin", "build:tenant", "build:app")) {
                    $pnpmArgs = $c -split ' '  # splat: pnpm can be a .ps1 wrapper, which takes @(...) as one argument
                    & pnpm @pnpmArgs 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 3 | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "pnpm $c failed" }
                }
            } finally { $ErrorActionPreference = $eap }
        } finally { Pop-Location }
    }
    foreach ($p in "frontend\admin\dist\index.html", "frontend\tenant\dist\index.html", "frontend\app\dist\index.html") {
        if (-not (Test-Path (Join-Path $lcRepo $p))) { throw "Missing dist: $p" }
    }

    Write-Host "==> Embedding app dist + building Go binary (linux/amd64)"
    $embedDir = Join-Path $lcRepo "backend\resources\app"
    Remove-Item (Join-Path $embedDir "*") -Recurse -Force
    Copy-Item -Recurse (Join-Path $lcRepo "frontend\app\dist\*") $embedDir
    New-Item -ItemType Directory -Force -Path (Join-Path $stage "consoles") | Out-Null
    $stamp = (git -C $lcRepo rev-parse --short HEAD).Trim() + "-" + (Get-Date -Format "yyyyMMddHHmm")
    $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
    try {
        & go -C (Join-Path $lcRepo "backend") build -trimpath -ldflags "-s -w -X github.com/raiworks/localcen/app/idp.BuildVersion=$stamp" -o (Join-Path $stage "localcen") ./cmd
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
        # 2026-11-21: the 20261120T160221 release embedded the placeholder ("Editor build not bundled.") at /app.
        # Refuse a binary that does not carry the built app.
        $binText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $stage "localcen")))
        if (-not $binText.Contains("LocalCen app</title>") -or $binText.Contains("Editor build not bundled")) {
            throw "the binary does not embed frontend/app/dist (placeholder found)"
        }
        Write-Host "    binary embeds the built app (checked)"
    } finally {
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        & git -C $lcRepo checkout -- backend/resources/app/index.html 2>$null
    }
    Copy-Item -Recurse (Join-Path $lcRepo "frontend\admin\dist") (Join-Path $stage "consoles\admin")
    Copy-Item -Recurse (Join-Path $lcRepo "frontend\tenant\dist") (Join-Path $stage "consoles\tenant")
    & tar -czf $tar -C $stage localcen consoles
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }
    Write-Host ("  release {0} ({1:N1} MB)" -f $stamp, ((Get-Item $tar).Length / 1MB))

    Write-Host "==> Deploying to $($vm.Target)"
    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage && chmod 700 $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath $tar -RemotePath "$remoteStage/localcen-release.tar.gz"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $lcRepo "deploy\cleanup-setup.sh") -RemotePath "$remoteStage/cleanup-setup.sh"
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "03-deploy-localcen.sh") -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o BatchMode=yes -o ConnectTimeout=15 $vm.Target "rm -rf $remoteStage" 2>$null
}
