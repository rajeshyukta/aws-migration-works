# Build dns-service (React consoles + linux/amd64 Go binary) and deploy onto DNS VM (52.66.165.1)
param(
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$dnsRepo = "E:\workspace\projects\platform\dns-service"
if (-not (Test-Path $dnsRepo)) { throw "dns-service repo missing: $dnsRepo" }

$vm = Get-VmTarget -RepoRoot $repoRoot -Name "DNS VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dns-service-stage-$PID")
$tar = Join-Path ([System.IO.Path]::GetTempPath()) ("dns-service-$PID.tar.gz")
$remoteTar = "/tmp/dns-service-$PID.tar.gz"
$remoteCaddy = "/tmp/dns-vm-$PID.Caddyfile"
$caddyFile = Join-Path $repoRoot "templates\Caddyfile.dns-vm"

try {
    if (-not $SkipFrontendBuild) {
        Write-Host "==> Building dns-service SPAs (tenant + admin)..."
        Push-Location (Join-Path $dnsRepo "frontend")
        try {
            $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = "0"
            & pnpm install --frozen-lockfile
            if ($LASTEXITCODE -ne 0) { throw "pnpm install failed" }
            & pnpm build:tenant
            if ($LASTEXITCODE -ne 0) { throw "tenant build failed" }
            & pnpm build:admin
            if ($LASTEXITCODE -ne 0) { throw "admin build failed" }
        } finally {
            Pop-Location
        }
    }

    foreach ($d in @("frontend\tenant\dist\index.html", "frontend\admin\dist\index.html")) {
        if (-not (Test-Path (Join-Path $dnsRepo $d))) { throw "Missing frontend build: $d" }
    }

    Write-Host "==> Embedding consoles and building linux/amd64 binary..."
    try {
        foreach ($app in @("tenant", "admin")) {
            $dst = Join-Path $dnsRepo "resources\consoles\$app"
            if (Test-Path $dst) { Remove-Item (Join-Path $dst "*") -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -Recurse (Join-Path $dnsRepo "frontend\$app\dist\*") $dst
        }

        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        $stamp = (git -C $dnsRepo rev-parse --short HEAD).Trim() + "-" + (Get-Date -Format "yyyyMMddHHmm")
        $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
        try {
            & go -C $dnsRepo build -trimpath -ldflags "-s -w -X github.com/RajeshYukta/dns-service/app/idp.BuildVersion=$stamp" -o (Join-Path $stage "dns") ./cmd
            if ($LASTEXITCODE -ne 0) { throw "go build failed" }
        } finally {
            Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        }
    } finally {
        & git -C $dnsRepo checkout -- resources/consoles
        & git -C $dnsRepo clean -fdq resources/consoles
    }

    & tar -czf $tar -C $stage dns
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    Write-Host "==> Uploading & deploying dns-service..."
    Copy-ToVm -Vm $vm -LocalPath $tar -RemotePath $remoteTar
    Copy-ToVm -Vm $vm -LocalPath $caddyFile -RemotePath $remoteCaddy
    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "02-deploy-dns-service.sh") `
        -EnvPrefix "TARBALL=$remoteTar CADDY_SRC=$remoteCaddy"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
    & ssh -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 $vm.Target "rm -f $remoteTar $remoteCaddy" 2>$null
}
