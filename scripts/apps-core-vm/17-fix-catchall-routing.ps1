# Deploy the Apps-Core catch-all routing fix (router in templates/caddy/apps-core-tls-ask.py +
# templates/Caddyfile.apps-core-vm). Backs up, validates, reloads Caddy, tests, rolls back on failure.
#   .\scripts\apps-core-vm\17-fix-catchall-routing.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Apps-Core-VM"
$repo = Resolve-RepoRoot
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$rc = "/tmp/Caddyfile.new-$PID"; $ra = "/tmp/apps-core-tls-ask.new-$PID.py"; $rs = "/tmp/17-fix-$PID.sh"; $rl = "/tmp/17-fix-$PID.log"
& scp @o (Join-Path $repo "templates\Caddyfile.apps-core-vm") "$($vm.Target):$rc" | Out-Null
& scp @o (Join-Path $repo "templates\caddy\apps-core-tls-ask.py") "$($vm.Target):$ra" | Out-Null
& scp @o (Join-Path $PSScriptRoot "17-fix-catchall-routing.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rc $ra $rs && NEW_CADDYFILE=$rc NEW_ASK=$ra bash $rs > $rl 2>&1; echo rc=`$? >> $rl; cat $rl; rm -f $rs $rl"
