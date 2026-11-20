# Build/package Next iDP and deploy onto Apps-Core-VM (43.204.42.99, :8080)
param(
    [switch]$Rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$idpRepo = "E:\workspace\projects\platform\nextidp"
if (-not (Test-Path $idpRepo)) { throw "nextidp repo missing: $idpRepo" }

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
$version = (Get-Content (Join-Path $idpRepo "VERSION") | Select-Object -First 1).Trim()
$bin = Join-Path $idpRepo "backend\bin\nextidp"

if ($Rebuild -or -not (Test-Path $bin)) {
    Write-Host "==> Building Next iDP v$version..."
    $fe = Join-Path $idpRepo "frontend"
    if (-not (Test-Path (Join-Path $fe "node_modules"))) {
        Push-Location $fe
        try { & npm.cmd ci --silent; if ($LASTEXITCODE -ne 0) { throw "npm ci failed" } } finally { Pop-Location }
    }
    $env:GOTOOLCHAIN = "auto"
    try {
        & powershell -NoProfile -File (Join-Path $idpRepo "scripts\build.ps1") -Linux
        if ($LASTEXITCODE -ne 0) { throw "nextidp build.ps1 failed" }
    } finally {
        Remove-Item Env:GOTOOLCHAIN -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path $bin)) { throw "Linux binary missing: $bin" }

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("nextidp-stage-$PID")
$tar = Join-Path ([System.IO.Path]::GetTempPath()) ("nextidp-$version-$PID.tar.gz")
$remoteTar = "/tmp/nextidp-$version-$PID.tar.gz"

try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item $bin (Join-Path $stage "nextidp")
    Copy-Item (Join-Path $idpRepo "backend\database\seeders\data") (Join-Path $stage "data") -Recurse
    Copy-Item (Join-Path $idpRepo "LICENSE") (Join-Path $stage "LICENSE")
    Copy-Item (Join-Path $idpRepo "infra\systemd") (Join-Path $stage "systemd") -Recurse
    Get-ChildItem (Join-Path $stage "systemd") -File | ForEach-Object {
        $t = [System.IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n").Replace("`r", "")
        [System.IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
    }
    & tar -czf $tar -C $stage .
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    Write-Host "==> Uploading & deploying Next iDP $version to $($vm.Target)..."
    Copy-ToVm -Vm $vm -LocalPath $tar -RemotePath $remoteTar
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "03-deploy-nextidp.sh") `
        -EnvPrefix "TARBALL=$remoteTar VERSION=$version"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -f $remoteTar" 2>$null
}
