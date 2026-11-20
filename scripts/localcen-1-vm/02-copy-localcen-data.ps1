# One-time: copy LocalCen's DB dump, .env and shared/ files from Apps-Core-VM to LocalCen-1-VM.
# Read-only on Apps-Core-VM. The .env (secrets) passes through a 0600 temp file on this PC, deleted at the end.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$root = Resolve-RepoRoot
$src = Get-VmTarget -RepoRoot $root -Name "Apps-Core-VM"
$dst = Get-VmTarget -RepoRoot $root -Name "LocalCen-1-VM"
$tmp = Join-Path $env:TEMP "lc-copy-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$remoteStage = "/tmp/lc-copy-$PID"
$sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=20")

function Get-Remote([psobject]$Vm, [string]$Cmd, [string]$OutFile) {
    $p = Start-Process -FilePath ssh -ArgumentList (@("-i", $Vm.SshKey) + $sshOpts + @($Vm.Target, $Cmd)) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err"
    if ($p.ExitCode -ne 0) { throw "remote command failed on $($Vm.Name): $(Get-Content "$OutFile.err" -Raw)" }
    Remove-Item "$OutFile.err" -Force -ErrorAction SilentlyContinue
}

try {
    Write-Host "==> Reading from Apps-Core-VM (read-only)"
    Get-Remote $src "cd /tmp && sudo -u postgres pg_dump -Fc -d localcen_db" (Join-Path $tmp "localcen_db.dump")
    Get-Remote $src "sudo cat /srv/apps/localcen/shared/.env" (Join-Path $tmp "localcen.env")
    Get-Remote $src "sudo tar -czf - -C /srv/apps/localcen/shared --exclude=./.env ." (Join-Path $tmp "shared.tar.gz")
    Get-ChildItem $tmp | ForEach-Object { "  {0,-18} {1} bytes" -f $_.Name, $_.Length }
    if ((Get-Item (Join-Path $tmp "localcen_db.dump")).Length -lt 1000) { throw "dump too small" }

    Write-Host "==> Staging on LocalCen-1-VM"
    Invoke-VmCommand -Vm $dst -Command "mkdir -p $remoteStage && chmod 700 $remoteStage"
    foreach ($f in "localcen_db.dump", "localcen.env", "shared.tar.gz") { Copy-ToVm -Vm $dst -LocalPath (Join-Path $tmp $f) -RemotePath "$remoteStage/$f" }
    Invoke-VmCommand -Vm $dst -Command "chmod 600 $remoteStage/*"
    Invoke-VmScript -Vm $dst -LocalScriptPath (Join-Path $PSScriptRoot "02-copy-localcen-data.sh") -EnvPrefix "STAGE_DIR=$remoteStage"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    & ssh -i $dst.SshKey @sshOpts $dst.Target "rm -rf $remoteStage" 2>$null
}
