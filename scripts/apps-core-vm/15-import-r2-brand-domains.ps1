# Import all domains of an old Azure brand (staged nextdp_core_r2) into a live NextDP Core brand as
# external domains + managed-DNS zone rows. Dry run by default; -Commit writes. See docs/azure-r2-restore.md.
#
#   .\scripts\apps-core-vm\15-import-r2-brand-domains.ps1 -SourceBrand nextdigital -DestBrandId 34831870-c4c1-4d8b-bd45-b77672b541d3 -OwnerPublicId xcztbuqqh
#   ... -Commit                         # write
#   -OwnerPublicId = public id of the ONE live account that gets every domain (no users are created)
#   ... -Skip a.com,b.in                # leave these out
# The per-domain report is saved to temp/r2-import-<brand>.tsv.
param(
    [Parameter(Mandatory = $true)][string]$SourceBrand,
    [Parameter(Mandatory = $true)][string]$DestBrandId,
    [Parameter(Mandatory = $true)][string]$OwnerPublicId,
    [string[]]$Skip = @(),
    [switch]$Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($SourceBrand -notmatch '^[a-z][a-z0-9_]*$') { throw "Invalid -SourceBrand" }
if ($DestBrandId -notmatch '^[0-9a-f-]{36}$') { throw "Invalid -DestBrandId" }
if ($OwnerPublicId -notmatch '^[a-z0-9]{4,32}$') { throw "Invalid -OwnerPublicId" }
foreach ($s in $Skip) { if ($s -notmatch '^[a-z0-9.-]+$') { throw "Invalid fqdn in -Skip: $s" } }

. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Apps-Core-VM"
$dry = if ($Commit) { "0" } else { "1" }
$remoteTsv = "/tmp/r2-import-$SourceBrand-$PID.tsv"
$envPrefix = "SRC_BRAND_SLUG=$SourceBrand DST_BRAND_ID=$DestBrandId OWNER_PUBLIC_ID=$OwnerPublicId SKIP_FQDNS='$($Skip -join ' ')' DRY_RUN=$dry REPORT_TSV=$remoteTsv"
try {
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "15-import-r2-brand-domains.sh") -EnvPrefix $envPrefix | Out-Host
    $local = Join-Path (Resolve-RepoRoot) "temp\r2-import-$SourceBrand.tsv"
    New-Item -ItemType Directory -Force -Path (Split-Path $local) | Out-Null
    & scp -i $vm.SshKey -o BatchMode=yes "$($vm.Target):$remoteTsv" $local
    if ($LASTEXITCODE -eq 0) { Write-Host "Report: $local" }
} finally {
    & ssh -i $vm.SshKey -o BatchMode=yes $vm.Target "rm -f $remoteTsv" 2>$null
}
if (-not $Commit) { Write-Host "DRY RUN: nothing written. Re-run with -Commit to apply." }
