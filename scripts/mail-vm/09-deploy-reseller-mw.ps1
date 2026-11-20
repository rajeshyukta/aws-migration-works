# Build and deploy CConsole Hub (reseller-mw) onto the Mail VM (52.66.111.138)
param(
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$hubRepo = "E:\workspace\projects\platform\reseller-mw"
if (-not (Test-Path $hubRepo)) {
    throw "reseller-mw repo not found: $hubRepo"
}

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Mail VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

if (-not $SkipFrontendBuild) {
    Write-Host "==> Building reseller-mw SPAs (admin + tenant)..."
    Push-Location (Join-Path $hubRepo "frontend")
    try {
        & pnpm install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) { throw "pnpm install failed" }
        & pnpm --filter admin build
        if ($LASTEXITCODE -ne 0) { throw "admin build failed" }
        & pnpm --filter tenant build
        if ($LASTEXITCODE -ne 0) { throw "tenant build failed" }
    } finally {
        Pop-Location
    }
}

foreach ($d in @("frontend\admin\dist\index.html", "frontend\tenant\dist\index.html")) {
    if (-not (Test-Path (Join-Path $hubRepo $d))) {
        throw "Missing built frontend asset: $d"
    }
}

$tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tarCmd) { $tarCmd = Get-Command tar -ErrorAction SilentlyContinue }
if (-not $tarCmd) { throw "tar not found on PATH" }

$localTar = Join-Path ([System.IO.Path]::GetTempPath()) ("reseller-mw-" + $PID + ".tar.gz")
$remoteStage = "/tmp/cchub-stage-$PID"

try {
    Write-Host "==> Packaging ci4-app + built SPAs..."
    & $tarCmd.Source -czf $localTar `
        --exclude="ci4-app/vendor" `
        --exclude="ci4-app/.env" `
        --exclude="ci4-app/writable/logs/*" `
        --exclude="ci4-app/writable/cache/*" `
        --exclude="ci4-app/writable/session/*" `
        --exclude="ci4-app/writable/debugbar/*" `
        --exclude="ci4-app/tests" `
        -C $hubRepo `
        ci4-app frontend/admin/dist frontend/tenant/dist

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $localTar)) {
        throw "tar packaging failed"
    }

    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath $localTar -RemotePath "$remoteStage/reseller-mw.tar.gz"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\caddy\cconsole-hub.caddy") -RemotePath "$remoteStage/cconsole-hub.caddy"
    Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\Caddyfile.mail-vm") -RemotePath "$remoteStage/Caddyfile.mail-vm"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "09-deploy-reseller-mw.sh") `
        -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    Remove-Item -LiteralPath $localTar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -rf $remoteStage" 2>$null
}
