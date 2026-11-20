# Remove the old LocalCen install from Apps-Core-VM (LocalCen now runs on LocalCen-1-VM) and download the final
# archive (DB dump + config) to D:\nmc-backup\apps-core\localcen-retired-<ts>\.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -RepoRoot (Resolve-RepoRoot) -Name "Apps-Core-VM"
$log = Join-Path (Resolve-RepoRoot) "temp\14-remove-localcen-out.txt"
Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "14-remove-localcen.sh") 2>&1 | ForEach-Object { "$_" } | Tee-Object $log
$arch = ((Get-Content $log | Where-Object { $_ -match "ARCHIVE=" } | Select-Object -Last 1) -replace ".*ARCHIVE=", "").Trim()
if ($arch) {
    $local = Join-Path "D:\nmc-backup\apps-core" ("localcen-retired-" + (Split-Path $arch -Leaf))
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    & scp -q -i $vm.SshKey -o BatchMode=yes "$($vm.Target):$arch/*" $local
    if ($LASTEXITCODE -ne 0) { throw "download of $arch failed" }
    Get-ChildItem $local | ForEach-Object { "  saved {0} ({1} bytes)" -f $_.FullName, $_.Length }
}
