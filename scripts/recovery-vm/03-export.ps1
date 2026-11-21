# Export one inspected Azure disk on Recovery-VM into the R2 archive bucket (docs/azure-disk-archive.md §3, §5).
#   .\scripts\recovery-vm\03-export.ps1 -Disk nmc-php-stage-1-osdisk            # all steps: pg env code files upload
#   .\scripts\recovery-vm\03-export.ps1 -Disk nmc-php-stage-1-osdisk -Step pg   # one step
# Needs 02-disk -Mode download + inspect first. Nothing secret is printed.
param(
    [Parameter(Mandatory)] [string]$Disk,
    [ValidateSet("all", "pg", "env", "code", "files", "data", "upload")] [string]$Step = "all"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Disk -notmatch '^[A-Za-z0-9_.-]+$') { throw "Invalid -Disk" }
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Recovery-VM"
$o = @("-i", $vm.SshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=30")
$rs = "/tmp/03-export-$PID.sh"
& scp -q @o (Join-Path $PSScriptRoot "03-export.sh") "$($vm.Target):$rs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "script upload failed" }
& ssh -n @o $vm.Target "sed -i 's/\r$//' $rs && sudo env DISK=$Disk STEP=$Step bash $rs; echo rc=`$?; rm -f $rs"
