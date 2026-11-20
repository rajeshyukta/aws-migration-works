# Task 0.1 (docs/mail-vm-db-upgrade-r2.md): back up the live Mail VM state and download it.
# Downloads the DB dumps + storage tar (never the .env copy) and verifies SHA-256 locally.
param(
    [string]$LocalRoot = "D:\nmc-backup\mail-vm",
    [string]$Timestamp = ((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"

Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "10-backup-live-mail.sh") -EnvPrefix "BACKUP_TS=$Timestamp"

$remoteDir = "/var/backups/nextdp/$Timestamp"
$localDir = Join-Path $LocalRoot $Timestamp
New-Item -ItemType Directory -Force -Path $localDir | Out-Null

Write-Host "=== Downloading to $localDir ==="
& scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$($vm.Target):$remoteDir/*.dump" "$($vm.Target):$remoteDir/storage.tar.gz" "$($vm.Target):$remoteDir/SHA256SUMS" $localDir
if ($LASTEXITCODE -ne 0) { throw "scp download failed" }

Write-Host "=== Verifying SHA-256 ==="
$bad = 0
foreach ($line in (Get-Content (Join-Path $localDir "SHA256SUMS"))) {
    if ($line -notmatch '^([0-9a-f]{64})\s+\*?(.+)$') { continue }
    $expected = $Matches[1]; $name = $Matches[2].Trim()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $localDir $name)).Hash.ToLowerInvariant()
    $ok = $actual -eq $expected
    if (-not $ok) { $bad++ }
    "{0,-22} {1}" -f $name, ($(if ($ok) { "OK" } else { "MISMATCH" }))
}
if ($bad -gt 0) { throw "$bad file(s) failed SHA-256 verification" }

$pgRestore = Get-Command pg_restore -ErrorAction SilentlyContinue
if (-not $pgRestore -and (Test-Path "C:\Program Files\PostgreSQL\18\bin\pg_restore.exe")) {
    $pgRestore = Get-Command "C:\Program Files\PostgreSQL\18\bin\pg_restore.exe"
}
if ($pgRestore) {
    foreach ($d in (Get-ChildItem $localDir -Filter *.dump)) {
        $toc = (& $pgRestore.Source --list $d.FullName | Where-Object { $_ -and -not $_.StartsWith(';') }).Count
        "{0,-22} local pg_restore --list: {1} entries" -f $d.Name, $toc
    }
}
Write-Host "Local backup: $localDir"
