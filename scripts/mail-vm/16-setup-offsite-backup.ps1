# Phase 5 (docs/mail-vm-db-upgrade-r2.md): install the Mail VM's own off-site backup.
# - Creates private-data/mail-vm-offsite-backup.env with a new random RESTIC_PASSWORD (once; reused later).
# - Builds the VM config from that file + private-data/r2.env, stages it as a 0600 temp file, installs it
#   to /etc/nextdp-backup/restic.env (root 0600) and sets up the systemd timers.
# Upload private-data/mail-vm-offsite-backup.env to the AW Vault: without that password the backup is useless.
param(
    [string]$RepoPrefix = "aws-mail-vm",
    [string]$AlertTo = "rajesh@nextdp.com",
    [switch]$NoRunNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($RepoPrefix -notmatch '^[a-z0-9][a-z0-9-]{2,40}$' -or $RepoPrefix -eq "prod-main" -or $RepoPrefix -eq "admin") { throw "Invalid or reserved RepoPrefix" }
if ($AlertTo -notmatch '^[^@\s]+@[^@\s]+\.[a-z]{2,}$') { throw "Invalid AlertTo" }

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"
$repoRoot = Resolve-RepoRoot
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-EnvFile([string]$Path) {
    $h = @{}
    foreach ($l in (Get-Content -LiteralPath $Path)) {
        if ($l -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim().Trim('"') }
    }
    return $h
}

$r2 = Read-EnvFile (Join-Path $repoRoot "private-data\r2.env")
foreach ($k in "R2_ENDPOINT", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY") { if (-not $r2[$k]) { throw "r2.env: $k missing" } }
$endpointHost = ([Uri]$r2["R2_ENDPOINT"]).Host

$pwFile = Join-Path $repoRoot "private-data\mail-vm-offsite-backup.env"
if (-not (Test-Path $pwFile)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    $content = @(
        "# Mail VM off-site backup (restic). Created $(Get-Date -Format 'yyyy-MM-dd HH:mm') by 16-setup-offsite-backup.ps1."
        "# Repo: s3:$endpointHost/$($r2['R2_BUCKET'])/$RepoPrefix   Upload this file to the AW Vault. Never commit."
        "RESTIC_REPOSITORY=s3:$endpointHost/$($r2['R2_BUCKET'])/$RepoPrefix"
        "RESTIC_PASSWORD=$pw"
    ) -join "`n"
    [IO.File]::WriteAllText($pwFile, $content + "`n", $utf8)
    Remove-Variable pw, bytes
    Write-Host "Created $pwFile (new restic password, not shown)"
} else {
    Write-Host "Reusing existing $pwFile"
}
$pwEnv = Read-EnvFile $pwFile
if (-not $pwEnv["RESTIC_PASSWORD"] -or $pwEnv["RESTIC_REPOSITORY"] -ne "s3:$endpointHost/$($r2['R2_BUCKET'])/$RepoPrefix") { throw "mail-vm-offsite-backup.env does not match the target repo" }

$tmpEnv = Join-Path $env:TEMP "offsite-restic-$PID.env"
try {
    $vmEnv = @(
        "RESTIC_REPOSITORY=$($pwEnv['RESTIC_REPOSITORY'])"
        "RESTIC_PASSWORD=$($pwEnv['RESTIC_PASSWORD'])"
        "AWS_ACCESS_KEY_ID=$($r2['R2_ACCESS_KEY_ID'])"
        "AWS_SECRET_ACCESS_KEY=$($r2['R2_SECRET_ACCESS_KEY'])"
        "AWS_DEFAULT_REGION=auto"
        "ALERT_TO=$AlertTo"
        "ALERT_FROM=backup-alert@mail.nextdp.com"
        "ALERT_SMTP_HOST=127.0.0.1"
    ) -join "`n"
    [IO.File]::WriteAllText($tmpEnv, $vmEnv + "`n", $utf8)
    Remove-Variable vmEnv
    Copy-ToVm -Vm $vm -LocalPath $tmpEnv -RemotePath "/tmp/.offsite-restic.env"
} finally {
    if (Test-Path $tmpEnv) { Remove-Item -LiteralPath $tmpEnv -Force }
}
Invoke-VmCommand -Vm $vm -Command "chmod 600 /tmp/.offsite-restic.env"
Copy-ToVm -Vm $vm -LocalPath (Join-Path $repoRoot "templates\backup\nextdp-offsite-backup.sh") -RemotePath "/tmp/nextdp-offsite-backup.sh"
$run = if ($NoRunNow) { "0" } else { "1" }
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "16-setup-offsite-backup.sh") -EnvPrefix "RUN_NOW=$run"
