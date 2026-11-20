# Rebuild the two domain inventory docs from the staged R2 copies (read-only on every VM):
#   docs/azure-r2-brands-and-domains.md   (NextDP Core brands, from nextdp_core_r2 on Apps-Core-VM)
#   docs/azure-r2-dns-zones.md            (dns-service zones, from dns_service_r2 on the DNS VM)
#
# Stage the copies first (once):
#   .\scripts\r2\stage-r2-db.ps1 -Vm "Apps-Core-VM" -Database nextdp_core
#   .\scripts\r2\stage-r2-db.ps1 -Vm "DNS VM" -Database dns_service
# Then:
#   .\scripts\r2\make-domain-docs.ps1              # export JSON from both VMs + write both docs
#   .\scripts\r2\make-domain-docs.ps1 -SkipExport  # rewrite the docs from the last JSON export
#
# The JSON exports (they contain customer emails) stay in temp/r2-exports/ (gitignored).
param(
    [switch]$SkipExport,
    [string]$ExportDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\mail-vm\common.ps1")
$repo = Resolve-RepoRoot
if (-not $ExportDir) { $ExportDir = Join-Path $repo "temp\r2-exports" }
New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null

$jobs = @(
    @{ Vm = "Apps-Core-VM"; Script = "export-nextdp-core-brands.sh"; File = "nextdp-core-brands.json" },
    @{ Vm = "DNS VM";       Script = "export-dns-zones.sh";          File = "dns-zones.json" }
)

if (-not $SkipExport) {
    Initialize-Toolchain
    foreach ($j in $jobs) {
        $vm = Get-VmTarget -Name $j.Vm
        $remote = "/tmp/r2-export-$PID-$($j.File)"
        Write-Host "== $($j.Vm): $($j.Script)"
        try {
            Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot $j.Script) -EnvPrefix "OUT_FILE=$remote" | Out-Host
            & scp -i $vm.SshKey -o BatchMode=yes -o ConnectTimeout=20 "$($vm.Target):$remote" (Join-Path $ExportDir $j.File)
            if ($LASTEXITCODE -ne 0) { throw "scp download failed for $($j.File)" }
        } finally {
            & ssh -i $vm.SshKey -o BatchMode=yes -o ConnectTimeout=20 $vm.Target "rm -f $remote" 2>$null
        }
    }
}

$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { $python = Get-Command py -ErrorAction Stop }
& $python.Source (Join-Path $PSScriptRoot "build-domain-docs.py") `
    --brands-json (Join-Path $ExportDir "nextdp-core-brands.json") `
    --dns-json (Join-Path $ExportDir "dns-zones.json") `
    --out-dir (Join-Path $repo "docs")
if ($LASTEXITCODE -ne 0) { throw "build-domain-docs.py failed" }
