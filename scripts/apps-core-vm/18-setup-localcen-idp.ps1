# LocalCen objects in Next iDP (cconsole apps/key/webhook, realm localcen + tenant key, people realm
# localcen-people on myaccount.localcen.com with phone-only Reverse OTP sign-in). See the .sh header.
#   .\scripts\apps-core-vm\18-setup-localcen-idp.ps1            # read-only check
#   .\scripts\apps-core-vm\18-setup-localcen-idp.ps1 -Apply     # create / update, values -> /root/.localcen-idp.env
# Needs a Next iDP platform-admin login. If private-data/nextidp-operator.env exists
# (NEXTIDP_OPERATOR_EMAIL=..., NEXTIDP_OPERATOR_PASSWORD=...), it is installed on the VM as
# /root/.nextidp-operator.env (0600) and used first; otherwise /root/.nextidp-admin-secrets.env.
param([switch]$Apply, [string]$OwnerEmail = "rajesh@cconsole.com")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($OwnerEmail -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$') { throw "Invalid -OwnerEmail" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Apps-Core-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$op = Join-Path (Resolve-RepoRoot) "private-data\nextidp-operator.env"
if (Test-Path $op) {
    $tmp = "/tmp/.nextidp-operator-$PID.env"
    & ssh -n @o $vm.Target "umask 077 && : > $tmp" | Out-Null
    & scp @o $op "$($vm.Target):$tmp" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "operator file upload failed" }
    & ssh -n @o $vm.Target "sed -i 's/\r$//' $tmp && sudo install -o root -g root -m 0600 $tmp /root/.nextidp-operator.env; rm -f $tmp"
    Write-Host "Installed /root/.nextidp-operator.env from private-data (not printed)"
}
$rs = "/tmp/18-lc-idp-$PID.sh"; $rl = "/tmp/18-lc-idp-$PID.log"
& scp @o (Join-Path $PSScriptRoot "18-setup-localcen-idp.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && MODE=$mode OWNER_EMAIL=$OwnerEmail bash $rs > $rl 2>&1; echo rc=`$? >> $rl; cat $rl; rm -f $rs $rl"
