# Wire LocalCen (LocalCen-1-VM) to Next iDP with the values from apps-core-vm/18-setup-localcen-idp.
#   .\scripts\localcen-1-vm\05-wire-localcen-idp.ps1          # check: which keys are missing / change
#   .\scripts\localcen-1-vm\05-wire-localcen-idp.ps1 -Apply   # backup .env, merge, client keys, restart, health
# The values go Apps-Core-VM:/root/.localcen-idp.env -> private-data/localcen-idp.env (PC copy, gitignored)
# -> LocalCen-1-VM (0600 temp file, deleted after). Never printed.
param([switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$repo = Resolve-RepoRoot
$src = Get-VmTarget -RepoRoot $repo -Name "Apps-Core-VM"
$dst = Get-VmTarget -RepoRoot $repo -Name "LocalCen-1-VM"
$copy = Join-Path $repo "private-data\localcen-idp.env"
$so = @("-i", $src.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")
$do = @("-i", $dst.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20")

# 1. pull the values (sudo cat on the VM straight into the gitignored PC copy)
$raw = & ssh -n @so $src.Target "sudo cat /root/.localcen-idp.env"
if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "could not read /root/.localcen-idp.env on Apps-Core-VM" }
$lines = @($raw | Where-Object { $_ -match '^[A-Z_]+=' })
[IO.File]::WriteAllText($copy, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Saved $copy ($($lines.Count) keys, not printed)"

# 2. upload to LocalCen-1-VM as a 0600 temp file, run the .sh
$tmp = "/tmp/.localcen-idp-$PID.env"
& ssh -n @do $dst.Target "umask 077 && : > $tmp" | Out-Null
& scp -q @do $copy "$($dst.Target):$tmp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "upload failed" }
$rs = "/tmp/05-wire-idp-$PID.sh"
& scp -q @do (Join-Path $PSScriptRoot "05-wire-localcen-idp.sh") "$($dst.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "script upload failed" }
$mode = if ($Apply) { "apply" } else { "check" }
& ssh -n @do $dst.Target "sed -i 's/\r$//' $rs && MODE=$mode IN_FILE=$tmp bash $rs; echo rc=`$?; rm -f $rs $tmp"
