# Restore nextdp_mail PostgreSQL database + /opt/nextdp/storage from a local backup folder.
param(
    [string]$BackupDir = "D:\WorkSpace\PROJECTS\NextDP_Mail\private-data\backups\aws-final-20260826",
    [switch]$SkipStorage,
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $BackupDir)) {
    throw "Backup directory not found: $BackupDir"
}

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot

$dumpFile = Get-ChildItem -LiteralPath $BackupDir -File | Where-Object { $_.Name -match '\.(dump|sql)$' } | Sort-Object { $_.Extension -ne '.dump' } | Select-Object -First 1
if (-not $dumpFile) {
    throw "No .dump or .sql file found in $BackupDir"
}

$storageArchive = Join-Path $BackupDir "opt-nextdp.tar.gz"
$dotEnvConfig = Join-Path $BackupDir "dot-env-config"
$remoteStage = "/tmp/mail-local-restore-$PID"

$startFlag = if ($NoStart) { "0" } else { "1" }
$storageFlag = if ($SkipStorage -or -not (Test-Path $storageArchive)) { "0" } else { "1" }

Write-Host "=== Staging local backup to $($vm.Target):$remoteStage ==="
Invoke-VmCommand -Vm $vm -Command "mkdir -p $remoteStage && chmod 700 $remoteStage"

$tmpMigFile = $null
try {
    Copy-ToVm -Vm $vm -LocalPath $dumpFile.FullName -RemotePath "$remoteStage/$($dumpFile.Name)"
    if ($storageFlag -eq "1") {
        Write-Host "  Uploading storage archive: $storageArchive"
        Copy-ToVm -Vm $vm -LocalPath $storageArchive -RemotePath "$remoteStage/opt-nextdp.tar.gz"
    }
    if (Test-Path $dotEnvConfig) {
        $migLine = Get-Content -LiteralPath $dotEnvConfig | Where-Object { $_ -match '^MIGRATION_ENCRYPTION_KEY=(.+)$' } | Select-Object -First 1
        if ($migLine -and $migLine -match '^MIGRATION_ENCRYPTION_KEY=(.+)$') {
            $tmpMigFile = Join-Path $env:TEMP "nextdp-migkey-$PID.txt"
            $enc = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($tmpMigFile, $Matches[1].Trim(), $enc)
            Copy-ToVm -Vm $vm -LocalPath $tmpMigFile -RemotePath "$remoteStage/.migkey"
            Invoke-VmCommand -Vm $vm -Command "chmod 600 $remoteStage/.migkey"
        }
    }

    $envPrefix = "LOCAL_STAGE_DIR=$remoteStage RESTORE_STORAGE=$storageFlag START_SERVICES=$startFlag"
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "04-restore-r2-db.sh") `
        -EnvPrefix $envPrefix
} finally {
    if ($tmpMigFile -and (Test-Path $tmpMigFile)) {
        Remove-Item -LiteralPath $tmpMigFile -Force -ErrorAction SilentlyContinue
    }
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes $vm.Target "rm -rf $remoteStage" 2>$null
}
