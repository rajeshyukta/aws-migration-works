# Pull NextDP Core (nextdp-core / id.nextdp.com) and NextDP brand (ndp-nextdp / accounts.nextdp.com)
# realm credentials plus /srv/apps/nextdp/shared/.env from Apps-Core-VM (43.204.42.99)
# into gitignored private-data/ folders without echoing secrets.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"

$awsPrivate  = Join-Path $repoRoot "private-data"
$corePrivate = "E:\workspace\projects\platform\nextdp-core\private-data"
$idpPrivate  = "E:\workspace\projects\platform\nextidp\private-data"

$remoteTmpDir = "/tmp/awsmig-ndppull-$PID"
$localTmpDir  = Join-Path $env:TEMP "awsmig-ndppull-$PID"
New-Item -ItemType Directory -Path $localTmpDir -Force | Out-Null

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail
mkdir -m 0700 -p "$OUT_DIR"

for pair in \
  "/root/.nextdp-core-idp.env:nextdp-core-idp-realm.env" \
  "/root/.nextdp-brand-idp.env:nextdp-brand-idp-realm.env" \
  "/srv/apps/nextdp/shared/.env:aws-vm-nextdp-core.env"
do
  src="${pair%%:*}"
  dst="${pair##*:}"
  if sudo test -f "$src"; then
    sudo cat "$src" > "$OUT_DIR/$dst"
    chmod 0600 "$OUT_DIR/$dst"
  else
    echo "WARN: $src not found on Apps-Core-VM" >&2
  fi
done
'@ -replace "`r`n", "`n"

$localSh = Join-Path $localTmpDir "pull.sh"
[IO.File]::WriteAllText($localSh, $remoteScript, [Text.UTF8Encoding]::new($false))

try {
    $remoteSh = "/tmp/awsmig-ndppull-$PID.sh"
    Copy-ToVm -Vm $vm -LocalPath $localSh -RemotePath $remoteSh
    Invoke-VmCommand -Vm $vm -Command "sed -i 's/\r$//' $remoteSh && chmod +x $remoteSh && { OUT_DIR=$remoteTmpDir bash $remoteSh; rc=`$?; rm -f $remoteSh; exit `$rc; }"

    & scp -i $vm.SshKey -o StrictHostKeyChecking=accept-new -o BatchMode=yes `
        "$($vm.Target):$remoteTmpDir/*.env" `
        $localTmpDir
    if ($LASTEXITCODE -ne 0) { throw "scp download failed" }

    $targets = @{
        "nextdp-core-idp-realm.env" = @(
            (Join-Path $awsPrivate "nextdp-core-idp-realm.env"),
            (Join-Path $corePrivate "aws-nextdp-core-idp.env"),
            (Join-Path $idpPrivate "aws-nextdp-core-realm.env")
        )
        "nextdp-brand-idp-realm.env" = @(
            (Join-Path $awsPrivate "nextdp-brand-idp-realm.env"),
            (Join-Path $corePrivate "aws-nextdp-brand-idp.env"),
            (Join-Path $idpPrivate "aws-nextdp-brand-realm.env")
        )
        "aws-vm-nextdp-core.env" = @(
            (Join-Path $awsPrivate "aws-vm-nextdp-core.env"),
            (Join-Path $corePrivate "aws-shared.env")
        )
    }

    foreach ($name in $targets.Keys) {
        $srcFile = Join-Path $localTmpDir $name
        if (-not (Test-Path -LiteralPath $srcFile)) { continue }
        $raw = ([IO.File]::ReadAllText($srcFile)) -replace "`r`n", "`n"
        foreach ($dst in $targets[$name]) {
            $dir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($dst, $raw, [Text.UTF8Encoding]::new($false))
            Write-Host "Saved: $dst ($((Get-Item $dst).Length) bytes)" -ForegroundColor Green
        }
    }

    $coreFile = Join-Path $localTmpDir "nextdp-core-idp-realm.env"
    $brandFile = Join-Path $localTmpDir "nextdp-brand-idp-realm.env"
    if ((Test-Path -LiteralPath $coreFile) -or (Test-Path -LiteralPath $brandFile)) {
        $summaryParts = New-Object System.Collections.Generic.List[string]
        $summaryParts.Add("# NextDP Core & NextDP Brand Next iDP Realms (Apps-Core-VM 43.204.42.99)")
        $summaryParts.Add("# Pulled cleanly into gitignored private-data/ without echoing to stdout.")
        $summaryParts.Add("")
        if (Test-Path -LiteralPath $coreFile) {
            $summaryParts.Add("## Platform Realm (nextdp-core / id.nextdp.com)")
            $coreText = ([IO.File]::ReadAllText($coreFile)) -replace "`r`n", "`n"
            $summaryParts.Add($coreText)
        }
        if (Test-Path -LiteralPath $brandFile) {
            $summaryParts.Add("## Brand Sub-Realm (ndp-nextdp / accounts.nextdp.com)")
            $brandText = ([IO.File]::ReadAllText($brandFile)) -replace "`r`n", "`n"
            $summaryParts.Add($brandText)
        }
        $summaryText = ($summaryParts -join "`n").TrimEnd() + "`n"
        foreach ($dst in @(
            (Join-Path $awsPrivate "nextdp-idp-realms.txt"),
            (Join-Path $corePrivate "aws-nextdp-idp-realms.txt"),
            (Join-Path $idpPrivate "aws-nextdp-idp-realms.txt")
        )) {
            [IO.File]::WriteAllText($dst, $summaryText, [Text.UTF8Encoding]::new($false))
            Write-Host "Saved: $dst ($((Get-Item $dst).Length) bytes)" -ForegroundColor Green
        }
    }
} finally {
    Invoke-VmCommand -Vm $vm -Command "rm -rf -- $remoteTmpDir"
    if (Test-Path -LiteralPath $localTmpDir) { Remove-Item -LiteralPath $localTmpDir -Recurse -Force }
}
