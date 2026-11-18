# Run this script YOURSELF in your own PowerShell terminal (not via an AI agent)
# to search D:\WorkSpace\nextmanager-core (including private-data/) for R2 / restic credentials.
param(
    [string[]]$Roots = @(
        "D:\WorkSpace\nextmanager-core",
        "D:\WorkSpace\PROJECTS\nextmanager-core"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$pattern = 'restic|repo_password|r2|cloudflare|nxtmngr|b45ac396|access_key|secret_access_key|api_token|secretbox'
$skipExtensions = @('.pem', '.pub', '.exe', '.dll', '.bin', '.zip', '.7z', '.gz', '.tar', '.dump', '.png', '.jpg', '.svg', '.woff2', '.apk')

Write-Host "=== Credential File Check (local console only) ===" -ForegroundColor Cyan

foreach ($root in $Roots) {
    if (-not (Test-Path $root)) {
        Write-Host "[SKIP] Not found: $root" -ForegroundColor Yellow
        continue
    }
    Write-Host "`n>>> Scanning: $root" -ForegroundColor Green

    # 1. Print small credential / txt files under private-data\
    $privDir = Join-Path $root "private-data"
    if (Test-Path $privDir) {
        Get-ChildItem $privDir -Recurse -File -Force | Where-Object {
            $_.Name -match '\.(txt|env|md|json|conf)$' -and $_.Length -lt 32768 -and $_.FullName -notmatch '\\\.archive\\'
        } | ForEach-Object {
            Write-Host "`n--- File: $($_.FullName) ($($_.Length) bytes) ---" -ForegroundColor Yellow
            Get-Content $_.FullName
        }
    }

    # 2. Keyword search in private-data\, extra-works\, and any .env* files (keeps output focused)
    Write-Host "`n--- Keyword matches in private-data / extra-works / .env* ---" -ForegroundColor Cyan
    $searchTargets = @(
        (Join-Path $root "private-data"),
        (Join-Path $root "extra-works")
    ) | Where-Object { Test-Path $_ }

    $files = @()
    if ($searchTargets.Count -gt 0) {
        $files += Get-ChildItem $searchTargets -Recurse -File -Force -ErrorAction SilentlyContinue
    }
    $files += Get-ChildItem $root -Recurse -File -Force -Filter ".env*" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\|\\node_modules\\' }

    $files | Where-Object {
        $_.FullName -notmatch '\\minio\\|\\bundle-src\\' -and
        $skipExtensions -notcontains $_.Extension.ToLower() -and
        $_.Name -notin @('minio', 'mc', 'nextmanager-core', 'nextmanager-core-db', '.env.example') -and
        $_.Length -lt 1048576
    } | Select-String -Pattern $pattern | ForEach-Object {
        Write-Host ("{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim())
    }
}

Write-Host "`nDone. Copy any R2/restic credentials found into E:\workspace\aws-setup-and-migrations\private-data\r2.env" -ForegroundColor Green
