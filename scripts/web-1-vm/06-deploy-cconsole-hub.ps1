# Fresh install of CConsole Hub (reseller-mw) on Web-1 (3.6.143.66), moved off the Mail VM.
#   -Phase app   (default): build SPAs (unless -SkipFrontendBuild), package ci4-app + dists, install app,
#                           DB, Redis, FPM pool, cron. No public change.
#   -Phase sites           : after the 5 hub A records point to 3.6.143.66: install the Caddy site + get certs.
# Re-run -Phase app any time to redeploy code (.env and secrets are kept).
param(
    [ValidateSet("app", "sites")][string]$Phase = "app",
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Web-1"
$hubRepo = "E:\workspace\projects\platform\reseller-mw"
if (-not (Test-Path $hubRepo)) { throw "reseller-mw repo not found: $hubRepo" }
Write-Host "Target VM: $($vm.Name) ($($vm.Target)), phase=$Phase"

$remoteStage = "/tmp/cchub-stage-$PID"
$localTar = Join-Path ([IO.Path]::GetTempPath()) ("reseller-mw-" + $PID + ".tar.gz")
try {
    Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage && chmod 700 $remoteStage"
    if ($Phase -eq "app") {
        if (-not $SkipFrontendBuild) {
            Write-Host "==> Building reseller-mw SPAs (admin + tenant)..."
            Push-Location (Join-Path $hubRepo "frontend")
            try {
                & pnpm install --frozen-lockfile; if ($LASTEXITCODE -ne 0) { throw "pnpm install failed" }
                & pnpm --filter admin build;      if ($LASTEXITCODE -ne 0) { throw "admin build failed" }
                & pnpm --filter tenant build;     if ($LASTEXITCODE -ne 0) { throw "tenant build failed" }
            } finally { Pop-Location }
        }
        foreach ($d in "frontend\admin\dist\index.html", "frontend\tenant\dist\index.html") {
            if (-not (Test-Path (Join-Path $hubRepo $d))) { throw "Missing built frontend asset: $d" }
        }
        $tar = (Get-Command tar.exe -ErrorAction SilentlyContinue), (Get-Command tar -ErrorAction SilentlyContinue) | Where-Object { $_ } | Select-Object -First 1
        if (-not $tar) { throw "tar not found on PATH" }
        Write-Host "==> Packaging ci4-app + built SPAs (no vendor, no .env, no tests)..."
        & $tar.Source -czf $localTar `
            --exclude="ci4-app/vendor" --exclude="ci4-app/.env" `
            --exclude="ci4-app/writable/logs/*" --exclude="ci4-app/writable/cache/*" `
            --exclude="ci4-app/writable/session/*" --exclude="ci4-app/writable/debugbar/*" `
            --exclude="ci4-app/writable/uploads/*" --exclude="ci4-app/writable/keys/*" `
            --exclude="ci4-app/tests" `
            -C $hubRepo ci4-app frontend/admin/dist frontend/tenant/dist
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $localTar)) { throw "tar packaging failed" }
        Copy-ToVm -Vm $vm -LocalPath $localTar -RemotePath "$remoteStage/reseller-mw.tar.gz"
    } else {
        Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\caddy\cconsole-hub.web-1.caddy") -RemotePath "$remoteStage/cconsole-hub.caddy"
    }
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "06-deploy-cconsole-hub.sh") -EnvPrefix "PHASE=$Phase STAGE_DIR=$remoteStage"
} finally {
    Remove-Item -LiteralPath $localTar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o BatchMode=yes -o ConnectTimeout=15 $vm.Target "rm -rf $remoteStage" 2>$null
}
