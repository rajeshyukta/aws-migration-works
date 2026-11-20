# Build NextDP Core (linux/amd64) and deploy onto Apps-Core-VM (43.204.42.99, :8090)
param(
    [switch]$RebuildCss
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$coreRepo = "E:\workspace\projects\platform\nextdp-core"
if (-not (Test-Path $coreRepo)) { throw "nextdp-core repo missing: $coreRepo" }

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
$baseSql = Join-Path $repoRoot "templates\nextdp-core-ci4-base.sql"
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("nextdp-core-stage-$PID")
$tar = Join-Path ([System.IO.Path]::GetTempPath()) ("nextdp-core-$PID.tar.gz")
$remoteTar = "/tmp/nextdp-core-$PID.tar.gz"
$remoteBaseSql = "/tmp/nextdp-core-base-$PID.sql"

try {
    if ($RebuildCss) {
        $cssDir = Join-Path $coreRepo "design\ui-theming-v2"
        if (-not (Test-Path (Join-Path $cssDir "node_modules"))) {
            Push-Location $cssDir
            try { & npm.cmd ci --ignore-scripts; if ($LASTEXITCODE -ne 0) { throw "npm ci failed" } } finally { Pop-Location }
        }
        & npm.cmd --prefix $cssDir run build:ssr
        if ($LASTEXITCODE -ne 0) { throw "build:ssr failed" }
    }

    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Write-Host "==> Building NextDP Core (linux/amd64)..."
    $stamp = (git -C $coreRepo rev-parse --short HEAD).Trim() + "-" + (Get-Date -Format "yyyyMMddHHmm")
    $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
    try {
        & go -C (Join-Path $coreRepo "backend") build -trimpath -ldflags "-s -w -X github.com/rajeshyukta/nextdp/app/idp.BuildVersion=$stamp" -o (Join-Path $stage "nextdp") ./cmd
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
    } finally {
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }

    Copy-Item -Recurse (Join-Path $coreRepo "backend\resources") (Join-Path $stage "resources")
    & tar -czf $tar -C $stage nextdp resources
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    Write-Host "==> Uploading & deploying NextDP Core to $($vm.Target)..."
    Copy-ToVm -Vm $vm -LocalPath $tar -RemotePath $remoteTar
    Copy-ToVm -Vm $vm -LocalPath $baseSql -RemotePath $remoteBaseSql
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "04-deploy-nextdp-core.sh") `
        -EnvPrefix "TARBALL=$remoteTar BASE_SQL=$remoteBaseSql"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -f $remoteTar $remoteBaseSql" 2>$null
}
