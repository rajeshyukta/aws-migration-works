# Provision dedicated AWS S3 bucket ('nextidp' in ap-south-1) and least-privilege IAM user
# ('nextidp-app') via AWS CLI, saving credentials ONLY into gitignored private-data/ files
# without printing SecretAccessKey to stdout. Idempotent for bucket/policy/user creation.
param(
    [string]$BucketName = "nextidp",
    [string]$Region = "ap-south-1",
    [string]$IamUserName = "nextidp-app",
    [string]$PolicyName = "nextidp-s3-assets-rw"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
$repoRoot = Resolve-RepoRoot

$awsPrivate = Join-Path $repoRoot "private-data"
$idpPrivate = "E:\workspace\projects\platform\nextidp\private-data"
New-Item -ItemType Directory -Path $awsPrivate -Force | Out-Null

$s3EnvAws = Join-Path $awsPrivate "nextidp-s3.env"
$s3EnvIdp = Join-Path $idpPrivate "aws-s3-live.env"

$utf8NoBom = [Text.UTF8Encoding]::new($false)
$tmpDir = Join-Path $env:TEMP "awsmig-s3setup-$PID"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

function Invoke-AwsRaw {
    param([string[]]$AwsArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & aws @AwsArgs 2>&1
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return @{ ExitCode = $rc; Output = ($out | Out-String).Trim() }
}

function Invoke-AwsJson {
    param([string[]]$AwsArgs)
    $res = Invoke-AwsRaw $AwsArgs
    if ($res.ExitCode -ne 0) {
        throw "aws $($AwsArgs -join ' ') failed (exit $($res.ExitCode)): $($res.Output)"
    }
    if (-not $res.Output) { return $null }
    return ($res.Output | ConvertFrom-Json)
}

function Invoke-AwsOk {
    param([string[]]$AwsArgs)
    $res = Invoke-AwsRaw $AwsArgs
    if ($res.ExitCode -ne 0) {
        throw "aws $($AwsArgs -join ' ') failed (exit $($res.ExitCode)): $($res.Output)"
    }
}

try {
    Write-Host "==> Verifying AWS identity"
    $ident = Invoke-AwsJson @("sts", "get-caller-identity", "--output", "json")
    $accountId = $ident.Account
    Write-Host "Authenticated AWS Account: $accountId ($($ident.Arn))"

    # 1. Create S3 bucket if missing
    Write-Host "==> Ensuring S3 bucket s3://$BucketName in $Region"
    $hb = Invoke-AwsRaw @("s3api", "head-bucket", "--bucket", $BucketName)
    if ($hb.ExitCode -ne 0) {
        if ($Region -eq "us-east-1") {
            Invoke-AwsOk @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region)
        } else {
            Invoke-AwsOk @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region, "--create-bucket-configuration", "LocationConstraint=$Region")
        }
        Write-Host "Created bucket: $BucketName ($Region)"
    } else {
        Write-Host "Bucket already exists (owned by us): $BucketName"
    }

    # 2. Object Ownership: BucketOwnerEnforced (ACLs disabled)
    Write-Host "==> Setting Object Ownership = BucketOwnerEnforced"
    Invoke-AwsOk @("s3api", "put-bucket-ownership-controls", "--bucket", $BucketName, "--ownership-controls", "Rules=[{ObjectOwnership=BucketOwnerEnforced}]")

    # 3. Block Public Access: block ACLs only, allow scoped public bucket policy
    Write-Host "==> Configuring Block Public Access (block ACLs, allow scoped bucket policy)"
    Invoke-AwsOk @("s3api", "put-public-access-block", "--bucket", $BucketName, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false")

    # 4. Versioning: Suspended (disabled)
    Write-Host "==> Ensuring Bucket Versioning = Suspended"
    Invoke-AwsOk @("s3api", "put-bucket-versioning", "--bucket", $BucketName, "--versioning-configuration", "Status=Suspended")

    # 5. Default Encryption: SSE-S3 AES256 + Bucket Key enabled
    Write-Host "==> Configuring Default Encryption (AES256 + BucketKeyEnabled)"
    $encFile = Join-Path $tmpDir "enc.json"
    $encJson = @{
        Rules = @(
            @{
                ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = "AES256" }
                BucketKeyEnabled = $true
            }
        )
    } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($encFile, $encJson, $utf8NoBom)
    Invoke-AwsOk @("s3api", "put-bucket-encryption", "--bucket", $BucketName, "--server-side-encryption-configuration", "file://$encFile")

    # 6. Bucket Policy: anonymous s3:GetObject ONLY on avatars/* and realms/* (listing denied)
    Write-Host "==> Applying PublicReadAssets bucket policy (avatars/* and realms/* only)"
    $polFile = Join-Path $tmpDir "bucket-policy.json"
    $bucketPolicy = @{
        Version = "2012-10-17"
        Statement = @(
            @{
                Sid = "PublicReadAssets"
                Effect = "Allow"
                Principal = "*"
                Action = "s3:GetObject"
                Resource = @(
                    "arn:aws:s3:::${BucketName}/avatars/*",
                    "arn:aws:s3:::${BucketName}/realms/*"
                )
            }
        )
    } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($polFile, $bucketPolicy, $utf8NoBom)
    Invoke-AwsOk @("s3api", "put-bucket-policy", "--bucket", $BucketName, "--policy", "file://$polFile")

    # 7. CORS: GET / HEAD for consoles and browser image fetches
    Write-Host "==> Applying CORS configuration"
    $corsFile = Join-Path $tmpDir "cors.json"
    $corsJson = @{
        CORSRules = @(
            @{
                AllowedHeaders = @()
                AllowedMethods = @("GET", "HEAD")
                AllowedOrigins = @("*")
                ExposeHeaders  = @("ETag", "Cache-Control")
                MaxAgeSeconds  = 86400
            }
        )
    } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($corsFile, $corsJson, $utf8NoBom)
    Invoke-AwsOk @("s3api", "put-bucket-cors", "--bucket", $BucketName, "--cors-configuration", "file://$corsFile")

    # 8. Tags
    Write-Host "==> Tagging bucket"
    Invoke-AwsOk @("s3api", "put-bucket-tagging", "--bucket", $BucketName, "--tagging", "TagSet=[{Key=project,Value=nextidp},{Key=purpose,Value=avatars-and-branding},{Key=managed-by,Value=aws-setup-and-migrations}]")

    # 9. Least-privilege IAM policy
    Write-Host "==> Ensuring IAM policy $PolicyName"
    $iamPolFile = Join-Path $tmpDir "iam-policy.json"
    $iamPolicyObj = @{
        Version = "2012-10-17"
        Statement = @(
            @{
                Sid = "AssetObjects"
                Effect = "Allow"
                Action = @("s3:PutObject", "s3:GetObject", "s3:DeleteObject")
                Resource = @(
                    "arn:aws:s3:::${BucketName}/avatars/*",
                    "arn:aws:s3:::${BucketName}/realms/*"
                )
            },
            @{
                Sid = "AssetListing"
                Effect = "Allow"
                Action = "s3:ListBucket"
                Resource = "arn:aws:s3:::${BucketName}"
                Condition = @{
                    StringLike = @{
                        "s3:prefix" = @("avatars/*", "avatars/", "realms/*", "realms/")
                    }
                }
            },
            @{
                Sid = "BucketLocation"
                Effect = "Allow"
                Action = "s3:GetBucketLocation"
                Resource = "arn:aws:s3:::${BucketName}"
            }
        )
    } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($iamPolFile, $iamPolicyObj, $utf8NoBom)

    $policyArn = "arn:aws:iam::${accountId}:policy/${PolicyName}"
    $gp = Invoke-AwsRaw @("iam", "get-policy", "--policy-arn", $policyArn)
    if ($gp.ExitCode -ne 0) {
        $polRes = Invoke-AwsJson @("iam", "create-policy", "--policy-name", $PolicyName, "--description", "Least-privilege S3 access for Next iDP avatars and realm branding in s3://$BucketName", "--policy-document", "file://$iamPolFile", "--output", "json")
        $policyArn = $polRes.Policy.Arn
        Write-Host "Created IAM policy: $policyArn"
    } else {
        # Update policy version safely if policy already existed (prune non-default versions if >=5)
        $vers = (Invoke-AwsJson @("iam", "list-policy-versions", "--policy-arn", $policyArn, "--output", "json")).Versions
        $nonDefault = @($vers | Where-Object { -not $_.IsDefaultVersion })
        if ($vers.Count -ge 5 -and $nonDefault.Count -gt 0) {
            $oldest = $nonDefault | Sort-Object CreateDate | Select-Object -First 1
            Invoke-AwsOk @("iam", "delete-policy-version", "--policy-arn", $policyArn, "--version-id", $oldest.VersionId)
        }
        Invoke-AwsOk @("iam", "create-policy-version", "--policy-arn", $policyArn, "--policy-document", "file://$iamPolFile", "--set-as-default")
        Write-Host "Updated IAM policy default version: $policyArn"
    }

    # 10. IAM User + attach policy + create access key if needed
    Write-Host "==> Ensuring IAM user $IamUserName"
    $gu = Invoke-AwsRaw @("iam", "get-user", "--user-name", $IamUserName)
    if ($gu.ExitCode -ne 0) {
        Invoke-AwsOk @("iam", "create-user", "--user-name", $IamUserName, "--tags", "Key=project,Value=nextidp", "Key=managed-by,Value=aws-setup-and-migrations")
        Write-Host "Created IAM user: $IamUserName"
    } else {
        Write-Host "IAM user already exists: $IamUserName"
    }

    Invoke-AwsOk @("iam", "attach-user-policy", "--user-name", $IamUserName, "--policy-arn", $policyArn)

    # Reuse existing key from private-data if its AccessKeyId is still active on IAM; otherwise create a fresh key.
    $existingKeys = (Invoke-AwsJson @("iam", "list-access-keys", "--user-name", $IamUserName, "--output", "json")).AccessKeyMetadata
    $reuseEnv = $null
    if (Test-Path -LiteralPath $s3EnvAws) {
        $parsed = @{}
        foreach ($line in (Get-Content -LiteralPath $s3EnvAws)) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=(.*)$') { $parsed[$matches[1]] = $matches[2].Trim() }
        }
        if ($parsed["S3_KEY"] -and $parsed["S3_SECRET"] -and ($existingKeys | Where-Object { $_.AccessKeyId -eq $parsed["S3_KEY"] -and $_.Status -eq "Active" })) {
            $reuseEnv = $parsed
            Write-Host "Existing active access key in private-data matches IAM ($($parsed['S3_KEY'])) - reusing without rotating."
        }
    }

    $accessKeyId = ""
    $secretAccessKey = ""
    if ($reuseEnv) {
        $accessKeyId = $reuseEnv["S3_KEY"]
        $secretAccessKey = $reuseEnv["S3_SECRET"]
    } else {
        if ($existingKeys.Count -ge 2) {
            throw "IAM user $IamUserName already has 2 access keys in AWS but none matching $s3EnvAws; delete an unused key before creating a new one."
        }
        $created = Invoke-AwsJson @("iam", "create-access-key", "--user-name", $IamUserName, "--output", "json")
        $accessKeyId = $created.AccessKey.AccessKeyId
        $secretAccessKey = $created.AccessKey.SecretAccessKey
        $created = $null
        Write-Host "Created fresh IAM access key for ${IamUserName}: $accessKeyId (secret suppressed)"
    }

    $assetsBaseUrl = "https://${BucketName}.s3.${Region}.amazonaws.com"
    $envContent = @"
# AWS S3 object storage for Next iDP avatars & realm logos — KEEP PRIVATE, NEVER COMMIT
AWS_ACCOUNT_ID=${accountId}
IAM_USER=${IamUserName}
IAM_POLICY_ARN=${policyArn}
AVATAR_STORE=s3
S3_BUCKET=${BucketName}
S3_REGION=${Region}
S3_KEY=${accessKeyId}
S3_SECRET=${secretAccessKey}
S3_ENDPOINT=
S3_SSE=AES256
S3_ACL=
N1_ASSETS_KEY_PREFIX=
N1_ASSETS_BASE_URL=${assetsBaseUrl}
"@ -replace "`r`n", "`n"

    [IO.File]::WriteAllText($s3EnvAws, $envContent, $utf8NoBom)
    Write-Host "Saved: $s3EnvAws ($((Get-Item $s3EnvAws).Length) bytes)" -ForegroundColor Green
    if (Test-Path -LiteralPath $idpPrivate) {
        [IO.File]::WriteAllText($s3EnvIdp, $envContent, $utf8NoBom)
        Write-Host "Saved: $s3EnvIdp ($((Get-Item $s3EnvIdp).Length) bytes)" -ForegroundColor Green
    }

    # Clear secret variables quickly
    $secretAccessKey = ""
    $envContent = ""
} finally {
    if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
}
