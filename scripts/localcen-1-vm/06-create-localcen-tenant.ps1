# Create a LocalCen tenant for a NextDP Core brand (org in cconsole, tenant row, API key). See the .sh header.
#   .\scripts\localcen-1-vm\06-create-localcen-tenant.ps1 -Slug localcen -Name LocalCen -WebhookUrl https://console.localcen.com/webhooks/local-2fa
#   ... -Apply   # writes; the key + webhook secret stay in LocalCen-1-VM:/root/.localcen-tenant-<slug>.env (0600)
param(
    [Parameter(Mandatory)] [string]$Slug,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$WebhookUrl,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Slug -notmatch '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$') { throw "Invalid -Slug" }
if ($Name -notmatch '^[A-Za-z0-9 .&-]{2,80}$') { throw "Invalid -Name" }
if ($WebhookUrl -notmatch '^https://[a-z0-9.-]+/[A-Za-z0-9/_-]*$') { throw "Invalid -WebhookUrl" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "LocalCen-1-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$rs = "/tmp/06-lc-tenant-$PID.sh"
& scp -q @o (Join-Path $PSScriptRoot "06-create-localcen-tenant.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && MODE=$mode SLUG=$Slug NAME='$Name' WEBHOOK_URL='$WebhookUrl' bash $rs; echo rc=`$?; rm -f $rs"
