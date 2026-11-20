# Build/test locally and deploy ALL OGCEN PHP 8.4 + static sites onto Lightsail Web-1 (3.6.143.66)
# Never modifies OGCEN repository files or azure fleet deploy scripts; reads no private-data secrets.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$ogcenRoot = "E:\workspace\projects\sites\ogcen"
if (-not (Test-Path -LiteralPath $ogcenRoot)) {
    throw "OGCEN repository not found at $ogcenRoot"
}
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Web-1"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"
Write-Host "Source repo: $ogcenRoot"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Required tool 'node' not found on PATH."
}

function Invoke-Checked {
    param([string]$Label, [string]$Exe, [string[]]$Arguments)
    Write-Host "  -> $Label"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed (exit $LASTEXITCODE)."
    }
}

Write-Host "=== [1/5] Run OGCEN local Node test suites ===" -ForegroundColor Cyan
Push-Location $ogcenRoot
try {
    Invoke-Checked "softskills.training tests"   "node" @("--test", "softskills.traning\tools\site-v4.test.js", "softskills.traning\tools\php-site-v4.test.js")
    Invoke-Checked "nextskillclub.com tests"     "node" @("--test", "nextskillclub.com\tools\php-site.test.js")
    Invoke-Checked "localcen.com v6 tests"       "node" @("--test", "localcen.com\tools\site-v6.test.js")
    Invoke-Checked "mrajesh.com tests"           "node" @("--test", "mrajesh.com\tools\site.test.js", "mrajesh.com\tools\php-site.test.js")
    Invoke-Checked "daiskills.com tests"         "node" @("--test", "daiskills.com\tools\php-site.test.js")
    Invoke-Checked "navduta.com tests"           "node" @("--test", "navduta.com\tools\site.test.js")
    Invoke-Checked "dev10.srikalabhairavam check" "node" @("srikalabhairavam-com\static-site-v10\_src\check.js")
} finally {
    Pop-Location
}

$release = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$work = Join-Path $env:TEMP "web1-ogcen-$release"
$archive = "$work.tar.gz"
$remoteStage = "/tmp/web1-ogcen-$release"

function Copy-FilteredTree {
    param(
        [string]$Src,
        [string]$Dst,
        [string[]]$ExcludeNames = @(),
        [string[]]$ExcludePatterns = @()
    )
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Src -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing symlink/reparse point: $($item.FullName)"
        }
        if ($ExcludeNames -contains $item.Name) { continue }
        $skip = $false
        foreach ($pat in $ExcludePatterns) {
            if ($item.Name -like $pat) { $skip = $true; break }
        }
        if ($skip) { continue }
        $destPath = Join-Path $Dst $item.Name
        if ($item.PSIsContainer) {
            Copy-FilteredTree -Src $item.FullName -Dst $destPath -ExcludeNames $ExcludeNames -ExcludePatterns $ExcludePatterns
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $destPath
        }
    }
}

function Write-CleanLfFile {
    param([string]$SrcPath, [string]$DstPath, [switch]$StripBind)
    $text = ([IO.File]::ReadAllText($SrcPath)) -replace "`r`n", "`n" -replace "`r", ""
    if ($StripBind) {
        $text = [regex]::Replace($text, '(?m)^[ \t]*bind[ \t]+172\.16\.0\.4[ \t]*\n', '')
    }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $parent = Split-Path -Parent $DstPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($DstPath, $text, [Text.UTF8Encoding]::new($false))
}

try {
    Write-Host "=== [2/5] Stage PHP + static payloads (no secrets or legacy bind directives) ===" -ForegroundColor Cyan
    $phpDeny = @(".env", ".env.example", ".git", "node_modules", "data", "storage", "sessions", "config.json")
    $phpDenyPat = @("*.sqlite", "*.sqlite-*", "*.pem", "*.key", "*.log", ".*")
    $staticDeny = @("_src", "shots", "screenshots", "node_modules", ".git", "cgi-bin", ".htaccess", "build-manifest.json", ".well-known")
    $staticDenyPat = @("README*", "*.bak-*", "*.ps1", "*.sh", "*.php", "*.phtml", "*.phar", "*.sql", "*.sqlite", "*.log", ".*")

    # Release-based PHP apps
    foreach ($item in @("app", "public", "tests")) {
        Copy-FilteredTree (Join-Path $ogcenRoot "softskills.traning\php-site\$item") (Join-Path $work "phpapps\softskills.training\$item") $phpDeny $phpDenyPat
        Copy-FilteredTree (Join-Path $ogcenRoot "nextskillclub.com\php-site\$item") (Join-Path $work "phpapps\nextskillclub.com\$item") $phpDeny $phpDenyPat
    }
    foreach ($item in @("app", "public", "tests", "router.php")) {
        $lSrc = Join-Path $ogcenRoot "localcen.com\php-site-v6\$item"
        $lDst = Join-Path $work "phpapps\localcen.com\$item"
        if (Test-Path $lSrc -PathType Container) { Copy-FilteredTree $lSrc $lDst $phpDeny $phpDenyPat } else { Copy-Item $lSrc $lDst }
        $mSrc = Join-Path $ogcenRoot "mrajesh.com\php-site\$item"
        $mDst = Join-Path $work "phpapps\mrajesh.com\$item"
        if (Test-Path $mSrc -PathType Container) { Copy-FilteredTree $mSrc $mDst $phpDeny $phpDenyPat } else { Copy-Item $mSrc $mDst }
    }
    foreach ($item in @("public", "app", "tools", "build-manifest.json")) {
        $dSrc = Join-Path $ogcenRoot "daiskills.com\php-site\$item"
        $dDst = Join-Path $work "phpapps\daiskills.com\$item"
        if (Test-Path $dSrc -PathType Container) { Copy-FilteredTree $dSrc $dDst $phpDeny $phpDenyPat } else { Copy-Item $dSrc $dDst }
    }
    foreach ($item in @("app", "public")) {
        Copy-FilteredTree (Join-Path $ogcenRoot "srikalabhairavam-com\php-site\$item") (Join-Path $work "phpapps\dev.srikalabhairavam.com\$item") $phpDeny $phpDenyPat
    }

    # Flat SQLite/read-only PHP apps
    foreach ($pair in @(
        @{ Domain = "organicgrowth.center"; Src = "php-site-v1" },
        @{ Domain = "nextdigital.in";       Src = "nextdigital.in\php-site" },
        @{ Domain = "proseva.org";          Src = "proseva-works\php-site" }
    )) {
        Copy-FilteredTree (Join-Path $ogcenRoot "$($pair.Src)\public") (Join-Path $work "phpapps\$($pair.Domain)\public") $phpDeny $phpDenyPat
        Copy-FilteredTree (Join-Path $ogcenRoot "$($pair.Src)\app")    (Join-Path $work "phpapps\$($pair.Domain)\app")    $phpDeny $phpDenyPat
        New-Item -ItemType Directory -Path (Join-Path $work "phpapps\$($pair.Domain)\tools") -Force | Out-Null
        Copy-Item (Join-Path $ogcenRoot "$($pair.Src)\tools\init-db.php") (Join-Path $work "phpapps\$($pair.Domain)\tools\init-db.php")
        Copy-Item (Join-Path $ogcenRoot "$($pair.Src)\tools\dump-db.php") (Join-Path $work "phpapps\$($pair.Domain)\tools\dump-db.php")
    }
    Copy-FilteredTree (Join-Path $ogcenRoot "afteraiwork.com\php-site\public") (Join-Path $work "phpapps\afteraiwork.com\public") $phpDeny $phpDenyPat
    Copy-FilteredTree (Join-Path $ogcenRoot "afteraiwork.com\php-site\app")    (Join-Path $work "phpapps\afteraiwork.com\app")    $phpDeny $phpDenyPat

    # Non-secret default env & existing FPM pool files
    Write-CleanLfFile (Join-Path $ogcenRoot "localcen.com\deploy\php-v6\site.env") (Join-Path $work "env\localcen.com.env")
    Write-CleanLfFile (Join-Path $ogcenRoot "mrajesh.com\deploy\php\site.env")     (Join-Path $work "env\mrajesh.com.env")
    Write-CleanLfFile (Join-Path $ogcenRoot "softskills.traning\deploy\php\app-softskills.training.conf")    (Join-Path $work "fpm\app-softskills.training.conf")
    Write-CleanLfFile (Join-Path $ogcenRoot "nextskillclub.com\deploy\php\app-nextskillclub.com.conf")     (Join-Path $work "fpm\app-nextskillclub.com.conf")
    Write-CleanLfFile (Join-Path $ogcenRoot "localcen.com\deploy\php-v6\app-localcen.com.conf")            (Join-Path $work "fpm\app-localcen.com.conf")
    Write-CleanLfFile (Join-Path $ogcenRoot "mrajesh.com\deploy\php\app-mrajesh.com.conf")                 (Join-Path $work "fpm\app-mrajesh.com.conf")
    Write-CleanLfFile (Join-Path $ogcenRoot "srikalabhairavam-com\php-site\deploy\php-fpm.conf")           (Join-Path $work "fpm\app-dev.srikalabhairavam.com.conf")

    # Static sites
    foreach ($sp in @(
        @{ Domain = "rajeshforbharat.com";       Src = "rajeshforbharat.com" },
        @{ Domain = "forbharat.in";              Src = "forbharat.in\coming-soon" },
        @{ Domain = "haindaviswaraj.org.in";     Src = "haindaviswaraj.org.in\coming-soon" },
        @{ Domain = "dev.haindaviswaraj.org.in"; Src = "haindaviswaraj.org.in\static-site-v1" },
        @{ Domain = "jyothularajesh.com";        Src = "jyothularajesh.com\coming-soon" },
        @{ Domain = "navduta.com";               Src = "navduta.com\static-site" },
        @{ Domain = "srikalabhairavam.com";      Src = "srikalabhairavam-com\coming-soon" },
        @{ Domain = "dev2.srikalabhairavam.com"; Src = "srikalabhairavam-com\static-site-v2" },
        @{ Domain = "dev8.srikalabhairavam.com"; Src = "srikalabhairavam-com\static-site-v8" },
        @{ Domain = "dev9.srikalabhairavam.com"; Src = "srikalabhairavam-com\static-site-v9" },
        @{ Domain = "dev10.srikalabhairavam.com";Src = "srikalabhairavam-com\static-site-v10" },
        @{ Domain = "kalabhairavam.com";         Src = "kalabhairavam-com" }
    )) {
        Copy-FilteredTree (Join-Path $ogcenRoot $sp.Src) (Join-Path $work "static\$($sp.Domain)") $staticDeny $staticDenyPat
    }

    # Caddy site configs (strip bind 172.16.0.4 + normalize LF)
    $caddyMap = @(
        @{ Name = "softskills.training.caddy";       Src = (Join-Path $ogcenRoot "softskills.traning\deploy\php\softskills.training.caddy") },
        @{ Name = "daiskills.com.caddy";             Src = (Join-Path $ogcenRoot "daiskills.com\deploy\daiskills.com.caddy") },
        @{ Name = "nextskillclub.com.caddy";         Src = (Join-Path $ogcenRoot "nextskillclub.com\deploy\php\nextskillclub.com.caddy") },
        @{ Name = "localcen.com.caddy";              Src = (Join-Path $ogcenRoot "localcen.com\deploy\php-v6\localcen.com.caddy") },
        @{ Name = "mrajesh.com.caddy";               Src = (Join-Path $ogcenRoot "mrajesh.com\deploy\php\mrajesh.com.caddy") },
        @{ Name = "organicgrowth.center.caddy";      Src = (Join-Path $ogcenRoot "deploy\organicgrowth.center.caddy") },
        @{ Name = "afteraiwork.com.caddy";           Src = (Join-Path $ogcenRoot "afteraiwork.com\php-site\deploy\afteraiwork.com.caddy") },
        @{ Name = "nextdigital.in.caddy";            Src = (Join-Path $ogcenRoot "nextdigital.in\php-site\deploy\nextdigital.in.caddy") },
        @{ Name = "proseva.org.caddy";               Src = (Join-Path $ogcenRoot "proseva-works\php-site\deploy\proseva.org.caddy") },
        @{ Name = "dev2.srikalabhairavam.com.caddy"; Src = (Join-Path $ogcenRoot "srikalabhairavam-com\deploy-dev2\dev2.srikalabhairavam.com.caddy") },
        @{ Name = "dev8.srikalabhairavam.com.caddy"; Src = (Join-Path $ogcenRoot "srikalabhairavam-com\deploy-dev8\dev8.srikalabhairavam.com.caddy") },
        @{ Name = "dev9.srikalabhairavam.com.caddy"; Src = (Join-Path $ogcenRoot "srikalabhairavam-com\deploy-dev9\dev9.srikalabhairavam.com.caddy") },
        @{ Name = "dev10.srikalabhairavam.com.caddy";Src = (Join-Path $ogcenRoot "srikalabhairavam-com\deploy-dev10\dev10.srikalabhairavam.com.caddy") },
        @{ Name = "forbharat.in.caddy";              Src = (Join-Path $ogcenRoot "forbharat.in\deploy\forbharat.in.caddy") },
        @{ Name = "haindaviswaraj.org.in.caddy";     Src = (Join-Path $ogcenRoot "haindaviswaraj.org.in\deploy\haindaviswaraj.org.in.caddy") },
        @{ Name = "dev.haindaviswaraj.org.in.caddy"; Src = (Join-Path $ogcenRoot "haindaviswaraj.org.in\deploy\dev.haindaviswaraj.org.in.caddy") },
        @{ Name = "jyothularajesh.com.caddy";        Src = (Join-Path $ogcenRoot "jyothularajesh.com\deploy\jyothularajesh.com.caddy") },
        @{ Name = "navduta.com.caddy";               Src = (Join-Path $ogcenRoot "navduta.com\deploy\navduta.com.caddy") },
        @{ Name = "rajeshforbharat.com.caddy";       Src = (Join-Path $repoRoot "templates\caddy\rajeshforbharat.com.caddy") },
        @{ Name = "kalabhairavam.com.caddy";         Src = (Join-Path $repoRoot "templates\caddy\kalabhairavam.com.caddy") },
        @{ Name = "rajeshyukta.in.caddy";            Src = (Join-Path $repoRoot "templates\caddy\rajeshyukta.in.caddy") }
    )
    foreach ($c in $caddyMap) {
        Write-CleanLfFile $c.Src (Join-Path $work "caddy\$($c.Name)") -StripBind
    }

    # Merge srikalabhairavam.com.caddy (apex/in + PHP dev.srikalabhairavam.com)
    $skbBase = ([IO.File]::ReadAllText((Join-Path $ogcenRoot "srikalabhairavam-com\deploy\srikalabhairavam.com.caddy"))) -replace "`r`n", "`n" -replace "`r", ""
    $skbBase = [regex]::Replace($skbBase, '(?m)^[ \t]*bind[ \t]+172\.16\.0\.4[ \t]*\n', '')
    $skbDev  = ([IO.File]::ReadAllText((Join-Path $ogcenRoot "srikalabhairavam-com\php-site\deploy\dev.srikalabhairavam.com.caddy"))) -replace "`r`n", "`n" -replace "`r", ""
    $skbDev  = [regex]::Replace($skbDev, '(?m)^[ \t]*bind[ \t]+172\.16\.0\.4[ \t]*\n', '')
    $skbMerged = [regex]::Replace($skbBase, '(?ms)^dev\.srikalabhairavam\.com[ \t]*\{\n.*?^\}[ \t]*\n?', $skbDev.TrimEnd() + "`n")
    if ($skbMerged -notmatch 'php_fastcgi unix//run/php/app-dev\.srikalabhairavam\.com\.sock') {
        throw "Failed to merge PHP dev.srikalabhairavam.com block into srikalabhairavam.com.caddy"
    }
    [IO.File]::WriteAllText((Join-Path $work "caddy\srikalabhairavam.com.caddy"), $skbMerged, [Text.UTF8Encoding]::new($false))

    Write-Host "=== [3/5] Package archive & upload to Web-1 ===" -ForegroundColor Cyan
    & tar.exe -czf $archive -C $work phpapps env fpm static caddy
    if ($LASTEXITCODE -ne 0) { throw "tar packaging failed." }

    Invoke-VmCommand -Vm $vm -Command "mkdir -m 0700 -p $remoteStage"
    Copy-ToVm -Vm $vm -LocalPath $archive -RemotePath "$remoteStage/payload.tar.gz"
    Invoke-VmCommand -Vm $vm -Command "tar -xzf $remoteStage/payload.tar.gz -C $remoteStage"

    Write-Host "=== [4/5] Install & verify remotely on Web-1 ===" -ForegroundColor Cyan
    Invoke-VmScript -Vm $vm -LocalScriptPath (Join-Path $PSScriptRoot "02-deploy-ogcen-sites.sh") -EnvPrefix "STAGE_DIR=$remoteStage RELEASE=$release"
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -rf -- $remoteStage"
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
}
Write-Host "=== [5/5] Deployment complete ===" -ForegroundColor Green
