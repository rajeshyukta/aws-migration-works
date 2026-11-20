# Programmatically onboard a brand on NextDP Core via BrandProvisioner + idp.Service.Provision:
# child realm ndp-<slug> (accounts.<primary domain>) under nextdp-core, brand superadmin +
# realm_admin, brand nameservers, /root/.<slug>-brand-idp.env on the VM (pulled to
# private-data/<slug>-brand-idp.env). Defaults = the nextdp brand. Restarts nextdp at the end.
#   .\scripts\apps-core-vm\13-setup-nextdp-brand.ps1 -Slug nextdigital -Name NextDigital -PrimaryDomain nextdigital.in `
#       -SenderEmail support@nextdigital.in -PrimaryProduct local -Features dns,domains,idp_login,local `
#       -AdminEmail rajesh@nextdigital.in -Nameservers ns11.nextdp.com,ns12.nextdp.com
param(
    [string]$Slug = "nextdp",
    [string]$Name = "NextDP",
    [string]$PrimaryDomain = "nextdp.com",
    [string]$AdminDomain = "",      # default admin.<PrimaryDomain>
    [string]$ConsoleDomain = "",    # default console.<PrimaryDomain>
    [string]$SenderName = "",       # default = Name
    [string]$SenderEmail = "noreply@nextdp.com",
    [string]$PrimaryProduct = "domains",
    [string[]]$Features = @("domains", "dns", "blogs", "handcraft", "direct_register"),
    [string]$AdminEmail = "rajesh@nextdp.com",
    [string]$AdminName = "Rajesh",
    [string[]]$Nameservers = @(),
    [switch]$SkipPull
)
if (-not $AdminDomain) { $AdminDomain = "admin.$PrimaryDomain" }
if (-not $ConsoleDomain) { $ConsoleDomain = "console.$PrimaryDomain" }
if (-not $SenderName) { $SenderName = $Name }
if ($Slug -notmatch '^[a-z0-9-]+$') { throw "Invalid -Slug" }
foreach ($v in @($PrimaryDomain, $AdminDomain, $ConsoleDomain) + $Nameservers) { if ($v -notmatch '^[a-z0-9.-]+$') { throw "Invalid host: $v" } }
foreach ($v in @($SenderEmail, $AdminEmail)) { if ($v -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$') { throw "Invalid email: $v" } }
foreach ($v in $Features + @($PrimaryProduct)) { if ($v -notmatch '^[a-z_]+$') { throw "Invalid feature/product: $v" } }
if ($Name -notmatch '^[A-Za-z0-9 ._-]+$' -or $SenderName -notmatch '^[A-Za-z0-9 ._-]+$' -or $AdminName -notmatch '^[A-Za-z0-9 ._-]+$') { throw "Invalid name" }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
Initialize-Toolchain

$repoRoot = Resolve-RepoRoot
$vm = Get-VmTarget -RepoRoot $repoRoot -Name "Apps-Core-VM"
Write-Host "Target VM: $($vm.Name) ($($vm.Target))"

$nextdpBackend = "E:\workspace\projects\platform\nextdp-core\backend"
$tmpGoDir = Join-Path $nextdpBackend "extra-works\awsmig-brand-$PID"
$localBin = Join-Path $env:TEMP "awsmig-brand-boot-$PID"
$remoteBin = "/tmp/awsmig-brand-boot-$PID"

$mainGo = @'
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/raiworks/rapidgo/v2/core/config"
	"github.com/raiworks/rapidgo/v2/core/encryption"
	"github.com/raiworks/rapidgo/v2/database"
	"github.com/rajeshyukta/nextdp/app/idp"
	"github.com/rajeshyukta/nextdp/app/services"
	"github.com/rajeshyukta/nextdp/database/migrations"
	"gorm.io/gorm"
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	metaOut := flag.String("meta-out", "", "path to write non-secret brand metadata JSON")
	secretOut := flag.String("secret-out", "", "path to write decrypted brand IdP secrets (0600)")
	flag.Parse()

	config.Load()
	if ek := config.Env("ENCRYPTION_KEY", ""); ek != "" {
		if err := encryption.Init(); err != nil {
			log.Fatalf("encryption init: %v", err)
		}
	}
	db, err := database.Connect()
	if err != nil {
		log.Fatalf("db connect: %v", err)
	}

	slug := envOr("BRAND_SLUG", "nextdp")
	var brand migrations.Brand
	brandAction := "existing"
	err = db.Where("slug = ?", slug).First(&brand).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		prov := services.NewBrandProvisioner(db, &services.AuthService{DB: db})
		created, perr := prov.ProvisionBrand(services.BrandProvisionRequest{
			Slug:            slug,
			Name:            envOr("BRAND_NAME", "NextDP"),
			PrimaryDomain:   envOr("BRAND_PRIMARY_DOMAIN", "nextdp.com"),
			AdminDomain:     envOr("BRAND_ADMIN_DOMAIN", "admin.nextdp.com"),
			ConsoleDomain:   envOr("BRAND_CONSOLE_DOMAIN", "console.nextdp.com"),
			SenderName:      envOr("BRAND_SENDER_NAME", "NextDP"),
			SenderEmail:     envOr("BRAND_SENDER_EMAIL", "noreply@nextdp.com"),
			PrimaryProduct:  envOr("BRAND_PRIMARY_PRODUCT", "domains"),
			EnabledFeatures: strings.Split(envOr("BRAND_FEATURES", "domains,dns,blogs,handcraft,direct_register"), ","),
		})
		if perr != nil {
			log.Fatalf("ProvisionBrand: %v", perr)
		}
		brand = *created
		brandAction = "created"
	} else if err != nil {
		log.Fatalf("lookup brand: %v", err)
	}

	provisionAction := "existing"
	if brand.IdpRealmID == "" {
		if brand.IdpHost == "" {
			brand.IdpHost = migrations.DefaultIdpHost(brand)
			if err := db.Model(&migrations.Brand{}).Where("id = ?", brand.ID).Update("idp_host", brand.IdpHost).Error; err != nil {
				log.Fatalf("set idp_host: %v", err)
			}
		}
		idpSvc := idp.New(idp.ConfigFromEnv(), nil, idp.Hooks{}, db)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := idpSvc.Provision(ctx, db, &brand); err != nil {
			log.Fatalf("idp.Provision: %v", err)
		}
		provisionAction = "provisioned"
	}

	if err := db.Where("id = ?", brand.ID).First(&brand).Error; err != nil {
		log.Fatalf("reload brand: %v", err)
	}

	if *secretOut != "" {
		sec := fmt.Sprintf(
			"NEXTDP_BRAND_IDP_ADMIN_SECRET=%s\nNEXTDP_BRAND_IDP_CONSOLE_SECRET=%s\nNEXTDP_BRAND_IDP_REALM_KEY=%s\n",
			brand.IdpAdminSecret, brand.IdpConsoleSecret, brand.IdpRealmKey,
		)
		if err := os.WriteFile(*secretOut, []byte(sec), 0o600); err != nil {
			log.Fatalf("write secrets: %v", err)
		}
	}

	meta := map[string]any{
		"brand_id":               brand.ID,
		"slug":                   brand.Slug,
		"name":                   brand.Name,
		"primary_domain":         brand.PrimaryDomain,
		"admin_domain":           brand.AdminDomain,
		"console_domain":         brand.ConsoleDomain,
		"primary_product":        brand.PrimaryProduct,
		"idp_host":               brand.IdpHost,
		"idp_realm_id":           brand.IdpRealmID,
		"idp_issuer":             brand.IdpIssuer,
		"idp_admin_client_id":    brand.IdpAdminClientID,
		"idp_console_client_id":  brand.IdpConsoleClientID,
		"idp_status":             brand.IdpStatus,
		"brand_action":           brandAction,
		"provision_action":       provisionAction,
	}
	payload, err := json.Marshal(meta)
	if err != nil {
		log.Fatalf("encode output: %v", err)
	}
	if *metaOut != "" {
		if err := os.WriteFile(*metaOut, payload, 0o600); err != nil {
			log.Fatalf("write meta: %v", err)
		}
	} else {
		fmt.Println(string(payload))
	}
}
'@ -replace "`r`n", "`n"

try {
    New-Item -ItemType Directory -Path $tmpGoDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmpGoDir "main.go"), $mainGo, [Text.UTF8Encoding]::new($false))

    Write-Host "==> Cross-compiling temporary brand bootstrap binary (linux/amd64)..." -ForegroundColor Cyan
    $prevGoos = $env:GOOS; $prevGoarch = $env:GOARCH; $prevCgo = $env:CGO_ENABLED
    Push-Location $nextdpBackend
    try {
        $env:GOOS = "linux"
        $env:GOARCH = "amd64"
        $env:CGO_ENABLED = "0"
        & go build -o $localBin ./extra-works/awsmig-brand-$PID
        if ($LASTEXITCODE -ne 0) { throw "go build brand-bootstrap failed" }
    } finally {
        Pop-Location
        $env:GOOS = $prevGoos; $env:GOARCH = $prevGoarch; $env:CGO_ENABLED = $prevCgo
    }

    if (Test-Path -LiteralPath $tmpGoDir) {
        Remove-Item -LiteralPath $tmpGoDir -Recurse -Force
    }

    Copy-ToVm -Vm $vm -LocalPath $localBin -RemotePath $remoteBin
    Invoke-VmCommand -Vm $vm -Command "chmod 0700 $remoteBin"

    Invoke-VmScript -Vm $vm `
        -LocalScriptPath (Join-Path $PSScriptRoot "13-setup-nextdp-brand.sh") `
        -EnvPrefix ("BRAND_BOOT_BIN=$remoteBin BRAND_SLUG=$Slug BRAND_NAME='$Name' BRAND_PRIMARY_DOMAIN=$PrimaryDomain " +
            "BRAND_ADMIN_DOMAIN=$AdminDomain BRAND_CONSOLE_DOMAIN=$ConsoleDomain BRAND_SENDER_NAME='$SenderName' " +
            "BRAND_SENDER_EMAIL=$SenderEmail BRAND_PRIMARY_PRODUCT=$PrimaryProduct BRAND_FEATURES=$($Features -join ',') " +
            "BRAND_ADMIN_EMAIL=$AdminEmail BRAND_ADMIN_NAME='$AdminName' BRAND_NAMESERVERS=$($Nameservers -join ',')") | Out-Host
} finally {
    if (Test-Path -LiteralPath $tmpGoDir) { Remove-Item -LiteralPath $tmpGoDir -Recurse -Force }
    if (Test-Path -LiteralPath $localBin) { Remove-Item -LiteralPath $localBin -Force }
    Invoke-VmCommand -Vm $vm -Command "rm -f -- $remoteBin"
}

if (-not $SkipPull) {
    if ($Slug -eq "nextdp") {
        $pullScript = Join-Path $PSScriptRoot "pull-nextdp-idp-credentials.ps1"
        if (Test-Path -LiteralPath $pullScript) { & $pullScript }
    } else {
        # /root/.<slug>-brand-idp.env -> private-data/<slug>-brand-idp.env (0600 temp copy on the VM, deleted)
        $local = Join-Path $repoRoot "private-data\$Slug-brand-idp.env"
        $tmp = "/tmp/.$Slug-brand-idp-$PID.env"
        try {
            Invoke-VmCommand -Vm $vm -Command "sudo install -o $($vm.User) -m 0600 /root/.$Slug-brand-idp.env $tmp"
            & scp -i $vm.SshKey -o BatchMode=yes "$($vm.Target):$tmp" $local
            if ($LASTEXITCODE -ne 0) { throw "pull failed" }
            Write-Host "Pulled brand credentials to $local (not printed)"
        } finally {
            & ssh -n -i $vm.SshKey -o BatchMode=yes $vm.Target "rm -f $tmp" 2>$null
        }
    }
}
