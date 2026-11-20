# Task 0.2 (docs/mail-vm-db-upgrade-r2.md): fetch the NextDP Mail storage tree from Azure disk
# nmc-mail-1-osdisk onto the Mail VM. Modes:
#   download : az disk grant-access (SAS kept in a temp file, never printed), AzCopy on the VM, verify
#   inspect  : loop-mount read-only and locate the storage tree
#   extract  : tar the storage tree (-SrcDir) and download it to this PC
#   cleanup  : unmount, delete the VHD on the VM, az disk revoke-access
param(
    [Parameter(Mandatory = $true)][ValidateSet("download", "verify", "inspect", "extract", "cleanup")][string]$Mode,
    [string]$SrcDir = "",
    [string]$LocalDir = "D:\nmc-backup\mail-vm\azure-mail1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
Initialize-Toolchain
$vm = Get-VmTarget -Name "Mail VM"
$repoRoot = Resolve-RepoRoot
$sub = "53b184f6-7bb2-4fb9-9970-bc1aaf1e5818"
$rg = "EMAIL"
$disk = "nmc-mail-1-osdisk"
$script = Join-Path $PSScriptRoot "15-fetch-azure-mail1-storage.sh"
$env:PYTHONIOENCODING = "utf-8"

switch ($Mode) {
    "download" {
        $sasFile = Join-Path $repoRoot "private-data\mail1-disk.sas"
        try {
            Write-Host "=== az disk grant-access ($disk, 24h, read) ==="
            $sas = az disk grant-access --subscription $sub -g $rg -n $disk --duration-in-seconds 86400 --access-level Read --query accessSAS -o tsv
            if ($LASTEXITCODE -ne 0 -or -not $sas -or -not ($sas -like "https://*")) { throw "grant-access failed or returned no SAS" }
            [IO.File]::WriteAllText($sasFile, $sas.Trim(), (New-Object Text.UTF8Encoding($false)))
            Remove-Variable sas
            Write-Host "  SAS obtained (not shown)"
            Copy-ToVm -Vm $vm -LocalPath $sasFile -RemotePath "/tmp/.mail1.sas"
        } finally {
            if (Test-Path $sasFile) { Remove-Item -LiteralPath $sasFile -Force }
        }
        Invoke-VmCommand -Vm $vm -Command "chmod 600 /tmp/.mail1.sas"
        Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=download"
    }
    "extract" {
        if (-not $SrcDir) { throw "-SrcDir is required for extract (path of the storage dir inside the disk, e.g. /opt/nextdp/storage/uploads)" }
        if ($SrcDir -notmatch '^/[A-Za-z0-9._/-]+$') { throw "Unsafe -SrcDir: $SrcDir" }
        Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=extract SRC_DIR=$SrcDir"
        New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
        & scp -i $vm.SshKey -o BatchMode=yes "$($vm.Target):/var/backups/nextdp/azure-mail1-storage.tar.gz" "$($vm.Target):/var/backups/nextdp/azure-mail1-storage.tar.gz.sha256" $LocalDir
        if ($LASTEXITCODE -ne 0) { throw "scp download failed" }
        $expected = ((Get-Content (Join-Path $LocalDir "azure-mail1-storage.tar.gz.sha256")) -split '\s+')[0]
        $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $LocalDir "azure-mail1-storage.tar.gz")).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA-256 mismatch on local copy" }
        Write-Host "Local copy verified: $LocalDir\azure-mail1-storage.tar.gz"
    }
    "cleanup" {
        Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=cleanup"
        Write-Host "=== az disk revoke-access ($disk) ==="
        az disk revoke-access --subscription $sub -g $rg -n $disk -o none
        if ($LASTEXITCODE -ne 0) { throw "revoke-access failed" }
        Write-Host "  revoked"
    }
    default {
        Invoke-VmScript -Vm $vm -LocalScriptPath $script -EnvPrefix "MODE=$Mode"
    }
}
