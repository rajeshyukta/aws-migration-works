# Import the old Azure PowerDNS zones of one account (pdns_azure on the DNS VM) into a live
# dns-service tenant. Dry run by default; -Commit writes. Rules: see 09-import-azure-zones.sh.
#
#   .\scripts\dns-vm\09-import-azure-zones.ps1                # dry run, nextdp account -> tenant 01a1f019-...
#   .\scripts\dns-vm\09-import-azure-zones.ps1 -Commit
# The zone refs come from live NextDP Core (dns_zones.id of the brand), read on Apps-Core-VM.
# The plan (one line per record set) is saved to temp/dns-import-<account>.tsv.
param(
    [string]$Account = "nextdp",
    [string]$KeyAccount = "",   # tenant whose API key is used (= target tenant); default: same as -Account
    [string]$TenantId = "01a1f019-22db-7b69-9787-ba6220281859",
    [string]$CoreBrandId = "34831870-c4c1-4d8b-bd45-b77672b541d3",
    [string[]]$SkipZones = @("rajesh1.com"),
    [string[]]$DropIps = @("20.235.94.100", "20.219.8.247", "4.224.62.222", "172.198.131.111"),
    [string[]]$DropHosts = @(
        "admin.presencive.com", "console.presencive.com", "accounts.presencive.com",
        "admin.nextdigital.in", "console.nextdigital.in", "accounts.nextdigital.in",
        "admin.leadyourbiz.com", "console.leadyourbiz.com", "accounts.leadyourbiz.com",
        "admin.digpre.com", "console.digpre.com", "accounts.digpre.com",
        "admin.nextdp.com", "console.nextdp.com", "accounts.nextdp.com",
        "admin.yourdpm.com", "accounts.yourdpm.com",
        "admin.ogcen.com", "my.ogcen.com", "accounts.ogcen.com",
        "admin.proseva.org", "console.proseva.org", "accounts.proseva.org",
        "admin.localcen.com", "console.localcen.com", "accounts.localcen.com"),
    [string[]]$IpMap = @("20.207.200.1=3.6.143.66"),
    [switch]$KeepLiveGoogleMx,   # default: an old Google MX replaced on AWS is put back
    [switch]$Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $KeyAccount) { $KeyAccount = $Account }
if ($KeyAccount -notmatch '^[a-z0-9-]+$' -or $Account -notmatch '^[a-z0-9-]+$' -or $TenantId -notmatch '^[0-9a-f-]{36}$' -or $CoreBrandId -notmatch '^[0-9a-f-]{36}$') { throw "Invalid account/tenant/brand id" }
foreach ($v in @($SkipZones + $DropHosts)) { if ($v -notmatch '^[a-z0-9.*-]+$') { throw "Invalid name: $v" } }
foreach ($v in $DropIps) { if ($v -notmatch '^[0-9a-f.:]+$') { throw "Invalid IP: $v" } }
foreach ($v in $IpMap) { if ($v -notmatch '^[0-9a-f.:]+=[0-9a-f.:]+$') { throw "Invalid -IpMap entry: $v" } }

. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$core = Get-VmTarget -Name "Apps-Core-VM"
$dns = Get-VmTarget -Name "DNS VM"
$repo = Resolve-RepoRoot
$o = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
New-Item -ItemType Directory -Force -Path (Join-Path $repo "temp") | Out-Null

# 1. refs: fqdn -> NextDP Core dns_zones.id of the brand
$refsLocal = Join-Path $repo "temp\dns-import-refs-$Account.tsv"
$refs = & ssh -n -i $core.SshKey @o $core.Target "cd /tmp && sudo -u postgres psql -d nextdp_core -XAt -F'|' -c \`"SELECT lower(fqdn), id FROM dns_zones WHERE brand_id = '$CoreBrandId' ORDER BY 1\`""
if ($LASTEXITCODE -ne 0) { throw "could not read NextDP Core zone ids" }
$refs = @($refs | Where-Object { $_ -match '^[a-z0-9.-]+\|[0-9a-f-]{36}$' } | ForEach-Object { $_ -replace '\|', "`t" })
[IO.File]::WriteAllText($refsLocal, ($refs -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "NextDP Core zone ids for brand ${CoreBrandId}: $($refs.Count)"

# 2. run on the DNS VM
$remoteRefs = "/tmp/dns-import-refs-$PID.tsv"
$remotePlan = "/tmp/dns-import-$Account-$PID.tsv"
$remoteScript = "/tmp/dns-import-$PID.sh"
& scp -i $dns.SshKey @o $refsLocal "$($dns.Target):$remoteRefs" | Out-Null
& scp -i $dns.SshKey @o (Join-Path $PSScriptRoot "09-import-azure-zones.sh") "$($dns.Target):$remoteScript" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
$dry = if ($Commit) { "0" } else { "1" }
$google = if ($KeepLiveGoogleMx) { "0" } else { "1" }
$envs = "ACCOUNT=$Account KEY_ACCOUNT=$KeyAccount TENANT_ID=$TenantId REFS_FILE=$remoteRefs PLAN_TSV=$remotePlan DRY_RUN=$dry RESTORE_GOOGLE_MX=$google " +
        "SKIP_ZONES='$($SkipZones -join ' ')' DROP_IPS='$($DropIps -join ' ')' DROP_HOSTS='$($DropHosts -join ' ')' IP_MAP='$($IpMap -join ' ')'"
try {
    & ssh -n -i $dns.SshKey @o $dns.Target "sed -i 's/\r$//' $remoteScript && $envs bash $remoteScript > /tmp/dns-import-$PID.log 2>&1; echo rc=`$? >> /tmp/dns-import-$PID.log"
    & scp -i $dns.SshKey @o "$($dns.Target):/tmp/dns-import-$PID.log" (Join-Path $repo "temp\dns-import-$Account.log") | Out-Null
    & scp -i $dns.SshKey @o "$($dns.Target):$remotePlan" (Join-Path $repo "temp\dns-import-$Account.tsv") | Out-Null
} finally {
    & ssh -n -i $dns.SshKey @o $dns.Target "sudo rm -f $remoteRefs $remotePlan $remoteScript /tmp/dns-import-$PID.log"
}
Get-Content (Join-Path $repo "temp\dns-import-$Account.log")
Write-Host "Plan: temp\dns-import-$Account.tsv"
if (-not $Commit) { Write-Host "DRY RUN: nothing written. Re-run with -Commit to apply." }
