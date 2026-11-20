# Task 1.6 (docs/mail-vm-db-upgrade-r2.md): dry-run (default) or apply the AWS-delta merge into the
# staged R2 database on the Mail VM. -Apply is only used by the cutover (services must be stopped).
param(
    [string]$StageDb = "nextdp_mail_r2",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($StageDb -notmatch '^nextdp_mail_[a-z0-9_]+$') { throw "StageDb must match nextdp_mail_<suffix>" }

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"

$remoteSql = "/tmp/awsmig-13-merge-$PID.sql"
Copy-ToVm -Vm $vm -LocalPath (Join-Path $PSScriptRoot "13-merge-aws-delta.sql") -RemotePath $remoteSql
$dry = if ($Apply) { "0" } else { "1" }
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "13-merge-aws-delta.sh") `
    -EnvPrefix "STAGE_DB=$StageDb SQL_FILE=$remoteSql DRY_RUN=$dry"
