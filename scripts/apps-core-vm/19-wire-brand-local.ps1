# Connect a NextDP Core brand to its LocalCen tenant (made by localcen-1-vm/06-create-localcen-tenant).
#   .\scripts\apps-core-vm\19-wire-brand-local.ps1 -Brand localcen                 # check (dry run)
#   .\scripts\apps-core-vm\19-wire-brand-local.ps1 -Brand nextdp -EnableFeature -Apply
# The tenant's key + webhook secret go LocalCen-1-VM:/root/.localcen-tenant-<slug>.env ->
# private-data/localcen-tenant-<slug>.env (PC copy, gitignored) -> Apps-Core-VM 0600 temp file (deleted after).
param(
    [Parameter(Mandatory)] [string]$Brand,
    [string]$LocalSlug = "",
    [string]$ConsoleHost = "",
    [switch]$EnableFeature,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $LocalSlug) { $LocalSlug = $Brand }
foreach ($v in $Brand, $LocalSlug) { if ($v -notmatch '^[a-z0-9-]+$') { throw "Invalid slug $v" } }
if (-not $ConsoleHost) { $ConsoleHost = "console.$Brand.com" }
if ($ConsoleHost -notmatch '^[a-z0-9.-]+\.[a-z]{2,}$') { throw "Invalid -ConsoleHost" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$lc = Get-VmTarget -RepoRoot $repo -Name "LocalCen-1-VM"
$ac = Get-VmTarget -RepoRoot $repo -Name "Apps-Core-VM"
$lo = @("-i", $lc.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$ao = @("-i", $ac.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$copy = Join-Path $repo "private-data\localcen-tenant-$LocalSlug.env"
$raw = & ssh -n @lo $lc.Target "sudo cat /root/.localcen-tenant-$LocalSlug.env"
if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "could not read /root/.localcen-tenant-$LocalSlug.env on LocalCen-1-VM" }
$lines = @($raw | Where-Object { $_ -match '^LOCAL_[A-Z_]+=' })
[IO.File]::WriteAllText($copy, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Saved $copy ($($lines.Count) keys, not printed)"
$tmp = "/tmp/.localcen-tenant-$PID.env"
& ssh -n @ao $ac.Target "umask 077 && : > $tmp" | Out-Null
& scp -q @ao $copy "$($ac.Target):$tmp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
$rs = "/tmp/19-wire-local-$PID.sh"
& scp -q @ao (Join-Path $PSScriptRoot "19-wire-brand-local.sh") "$($ac.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "script upload failed" }
$mode = if ($Apply) { "apply" } else { "check" }
$feat = if ($EnableFeature) { "1" } else { "0" }
& ssh -n @ao $ac.Target "sed -i 's/\r$//' $rs $tmp && MODE=$mode BRAND=$Brand ENABLE_FEATURE=$feat CONSOLE_HOST=$ConsoleHost IN_FILE=$tmp bash $rs; echo rc=`$?; rm -f $rs $tmp"
