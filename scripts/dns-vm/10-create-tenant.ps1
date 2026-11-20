# Create a dns-service tenant (+ API key + webhook URL/secret) on the DNS VM and pull its secrets
# to private-data/dns-<slug>.env. Dry run by default; -Commit writes.
#   .\scripts\dns-vm\10-create-tenant.ps1 -Slug nextdigital -Name NextDigital -Nameservers ns11.nextdp.com,ns12.nextdp.com `
#       -SoaContact dns-admin@nextdigital.in -WebhookUrl https://console.nextdigital.in/webhooks/dns -Commit
# Then connect the brand: scripts/apps-core-vm/16-setup-brand-dns-connection.ps1 -KeyFile dns-<slug>.env ...
param(
    [Parameter(Mandatory = $true)][string]$Slug,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Nameservers,
    [Parameter(Mandatory = $true)][string]$SoaContact,
    [string]$WebhookUrl = "",
    [switch]$Commit
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Slug -notmatch '^[a-z0-9-]+$' -or $Name -notmatch '^[A-Za-z0-9 ._-]+$') { throw "Invalid -Slug/-Name" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "DNS VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$rs = "/tmp/10-tenant-$PID.sh"
& scp @o (Join-Path $PSScriptRoot "10-create-tenant.sh") "$($vm.Target):$rs" | Out-Null
$dry = if ($Commit) { "0" } else { "1" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && SLUG=$Slug NAME='$Name' NAMESERVERS=$($Nameservers -join ',') SOA_CONTACT=$SoaContact WEBHOOK_URL=$WebhookUrl DRY_RUN=$dry bash $rs; rc=`$?; rm -f $rs; exit `$rc"
if ($LASTEXITCODE -ne 0) { throw "tenant script failed" }
if ($Commit) {
    $local = Join-Path (Resolve-RepoRoot) "private-data\dns-$Slug.env"
    $tmp = "/tmp/.dns-$Slug-$PID.env"
    try {
        & ssh -n @o $vm.Target "sudo install -o $($vm.User) -m 0600 /root/.dns-$Slug-secrets.env $tmp"
        & scp @o "$($vm.Target):$tmp" $local | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pull failed" }
        Write-Host "Pulled tenant secrets to $local (not printed)"
    } finally {
        & ssh -n @o $vm.Target "rm -f $tmp" 2>$null
    }
}
