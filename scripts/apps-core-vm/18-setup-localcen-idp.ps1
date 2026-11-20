# LocalCen objects in Next iDP (cconsole apps/key/webhook + owner realm_admin; people realm
# localcen-people on myaccount.localcen.com with phone-only Reverse OTP sign-in). See the .sh header.
#   .\scripts\apps-core-vm\18-setup-localcen-idp.ps1            # read-only check
#   .\scripts\apps-core-vm\18-setup-localcen-idp.ps1 -Apply     # create / update, values -> /root/.localcen-idp.env
# Needs private-data/localcen-idp-input.env (owner-made: LOCALCEN_REALM_ID=, LOCALCEN_TENANT_KEY=).
# It is installed on the VM as /root/.localcen-idp-input.env (0600) and never printed.
# cconsole is changed with the cconsole realm admin from /root/.nextidp-cconsole-dns.env.
param([switch]$Apply, [string]$OwnerEmail = "rajesh@cconsole.com")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($OwnerEmail -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$') { throw "Invalid -OwnerEmail" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Apps-Core-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$in = Join-Path (Resolve-RepoRoot) "private-data\localcen-idp-input.env"
if (-not (Test-Path $in)) { throw "missing $in (LOCALCEN_REALM_ID=, LOCALCEN_TENANT_KEY=)" }
$names = Get-Content $in | ForEach-Object { if ($_ -match '^\s*([A-Z_]+)\s*=\s*\S') { $Matches[1] } }
foreach ($k in "LOCALCEN_REALM_ID", "LOCALCEN_TENANT_KEY") { if ($names -notcontains $k) { throw "$k missing in $in" } }
$tmp = "/tmp/.localcen-idp-input-$PID.env"
& ssh -n @o $vm.Target "umask 077 && : > $tmp" | Out-Null
& scp -q @o $in "$($vm.Target):$tmp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "input file upload failed" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $tmp && sudo install -o root -g root -m 0600 $tmp /root/.localcen-idp-input.env; rm -f $tmp"
Write-Host "Installed /root/.localcen-idp-input.env from private-data (not printed)"
$rs = "/tmp/18-lc-idp-$PID.sh"; $rl = "/tmp/18-lc-idp-$PID.log"
& scp -q @o (Join-Path $PSScriptRoot "18-setup-localcen-idp.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && MODE=$mode OWNER_EMAIL=$OwnerEmail bash $rs > $rl 2>&1; echo rc=`$? >> $rl; cat $rl; rm -f $rs $rl"
