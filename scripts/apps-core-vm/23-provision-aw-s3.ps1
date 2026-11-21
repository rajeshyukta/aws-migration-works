# Provision the AWS S3 bucket for Associate Works (its own setup doc: projects/products/associate-works/docs/references/
# s3-master-bucket-setup.md): private (all four Block Public Access ON), ACLs off, versioning ON, SSE-S3 (AES256 +
# Bucket Key), CORS for the two app origins (browser presigned GET / PUT / POST / HEAD), a least-privilege IAM user.
# The old bucket `associate-works` belongs to the suspended account (head-bucket 403), so the name is new.
#   .\scripts\apps-core-vm\23-provision-aw-s3.ps1
# Credentials go ONLY to private-data/associate-works-s3.env (gitignored); the secret is never printed. Idempotent.
param(
    [string]$BucketName = "associate-works-aps1",
    [string]$Region = "ap-south-1",
    [string]$IamUserName = "associate-works-app",
    [string]$PolicyName = "associate-works-s3-master"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "mail-vm\common.ps1")
$repoRoot = Resolve-RepoRoot
$envOut = Join-Path $repoRoot "private-data\associate-works-s3.env"
$utf8 = [Text.UTF8Encoding]::new($false)
$tmp = Join-Path $env:TEMP "aw-s3-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$awsExe = (Get-Command aws.exe -CommandType Application | Select-Object -First 1).Source
$env:AWS_PAGER = ""   # never wait on a pager

function Invoke-AwsCli([string[]]$CliArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $o = & $awsExe @CliArgs 2>&1; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return @{ rc = $rc; out = ($o | Out-String).Trim() }
}
function Invoke-AwsCliOk([string[]]$CliArgs) {
    $r = Invoke-AwsCli $CliArgs
    if ($r.rc -ne 0) { throw "aws $($CliArgs[0]) $($CliArgs[1]) failed: $($r.out)" }
    return $r.out
}
function New-JsonFile($obj) {
    $f = Join-Path $tmp ([guid]::NewGuid().ToString() + ".json")
    [IO.File]::WriteAllText($f, ($obj | ConvertTo-Json -Depth 8), $utf8)
    return "file://$f"
}

try {
    $acct = Invoke-AwsCliOk @("sts", "get-caller-identity", "--query", "Account", "--output", "text")
    Write-Host "AWS account $acct"
    $hb = Invoke-AwsCli @("s3api", "head-bucket", "--bucket", $BucketName, "--region", $Region)
    if ($hb.rc -ne 0) {
        if ($hb.out -match '\(403\)|Forbidden') { throw "bucket name $BucketName belongs to another account; pick another -BucketName" }
        Invoke-AwsCliOk @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region, "--create-bucket-configuration", "LocationConstraint=$Region") | Out-Null
        Write-Host "created bucket $BucketName ($Region)"
    } else { Write-Host "bucket $BucketName exists (ours)" }
    Invoke-AwsCliOk @("s3api", "put-bucket-ownership-controls", "--bucket", $BucketName, "--ownership-controls", "Rules=[{ObjectOwnership=BucketOwnerEnforced}]") | Out-Null
    Invoke-AwsCliOk @("s3api", "put-public-access-block", "--bucket", $BucketName, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true") | Out-Null
    Invoke-AwsCliOk @("s3api", "put-bucket-versioning", "--bucket", $BucketName, "--versioning-configuration", "Status=Enabled") | Out-Null
    Invoke-AwsCliOk @("s3api", "put-bucket-encryption", "--bucket", $BucketName, "--server-side-encryption-configuration", (New-JsonFile @{ Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = "AES256" }; BucketKeyEnabled = $true }) })) | Out-Null
    Invoke-AwsCliOk @("s3api", "put-bucket-cors", "--bucket", $BucketName, "--cors-configuration", (New-JsonFile @{ CORSRules = @(@{ AllowedHeaders = @("*"); AllowedMethods = @("GET", "PUT", "POST", "HEAD"); AllowedOrigins = @("https://associate.works", "https://admin.associate.works"); ExposeHeaders = @("ETag"); MaxAgeSeconds = 3000 }) })) | Out-Null
    # replaced / deleted object versions expire after 30 days; unfinished multipart uploads after 7
    Invoke-AwsCliOk @("s3api", "put-bucket-lifecycle-configuration", "--bucket", $BucketName, "--lifecycle-configuration", (New-JsonFile @{ Rules = @(@{ ID = "noncurrent-30d"; Status = "Enabled"; Filter = @{ Prefix = "" }; NoncurrentVersionExpiration = @{ NoncurrentDays = 30 }; AbortIncompleteMultipartUpload = @{ DaysAfterInitiation = 7 } }) })) | Out-Null
    Invoke-AwsCliOk @("s3api", "put-bucket-tagging", "--bucket", $BucketName, "--tagging", "TagSet=[{Key=project,Value=associate-works},{Key=managed-by,Value=aws-setup-and-migrations}]") | Out-Null
    Write-Host "bucket settings: private (Block Public Access x4), versioning on, SSE-S3, CORS (2 origins), lifecycle"

    $pol = @{ Version = "2012-10-17"; Statement = @(
        @{ Sid = "ListTheBucketOnly"; Effect = "Allow"; Action = @("s3:ListBucket", "s3:GetBucketLocation"); Resource = "arn:aws:s3:::$BucketName" },
        @{ Sid = "ObjectReadWriteDelete"; Effect = "Allow"; Action = @("s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"); Resource = "arn:aws:s3:::$BucketName/*" }) }
    $arn = "arn:aws:iam::${acct}:policy/$PolicyName"
    if ((Invoke-AwsCli @("iam", "get-policy", "--policy-arn", $arn)).rc -ne 0) {
        Invoke-AwsCliOk @("iam", "create-policy", "--policy-name", $PolicyName, "--description", "Associate Works: objects in s3://$BucketName only", "--policy-document", (New-JsonFile $pol)) | Out-Null
        Write-Host "created IAM policy $PolicyName"
    } else { Write-Host "IAM policy $PolicyName exists" }
    if ((Invoke-AwsCli @("iam", "get-user", "--user-name", $IamUserName)).rc -ne 0) {
        Invoke-AwsCliOk @("iam", "create-user", "--user-name", $IamUserName, "--tags", "Key=project,Value=associate-works") | Out-Null
        Write-Host "created IAM user $IamUserName"
    } else { Write-Host "IAM user $IamUserName exists" }
    Invoke-AwsCliOk @("iam", "attach-user-policy", "--user-name", $IamUserName, "--policy-arn", $arn) | Out-Null

    $have = @{}
    if (Test-Path $envOut) { Get-Content $envOut | ForEach-Object { if ($_ -match '^([A-Z0-9_]+)=(.*)$') { $have[$Matches[1]] = $Matches[2] } } }
    $keys = @((Invoke-AwsCliOk @("iam", "list-access-keys", "--user-name", $IamUserName, "--output", "json") | ConvertFrom-Json).AccessKeyMetadata)
    if ($have.ContainsKey("S3_KEY") -and ($keys | Where-Object { $_.AccessKeyId -eq $have["S3_KEY"] -and $_.Status -eq "Active" })) {
        Write-Host "access key in private-data is active - kept"
    } else {
        if ($keys.Count -ge 2) { throw "$IamUserName already has 2 keys, none of them in $envOut" }
        $k = (Invoke-AwsCliOk @("iam", "create-access-key", "--user-name", $IamUserName, "--output", "json") | ConvertFrom-Json).AccessKey
        $content = "# Associate Works S3 (AWS) - KEEP PRIVATE, NEVER COMMIT`nAWS_ACCOUNT_ID=$acct`nIAM_USER=$IamUserName`nSTORAGE_DRIVER=s3`nS3_ENDPOINT=`nS3_BUCKET=$BucketName`nS3_REGION=$Region`nS3_KEY=$($k.AccessKeyId)`nS3_SECRET=$($k.SecretAccessKey)`nS3_SSE=AES256`n"
        [IO.File]::WriteAllText($envOut, $content, $utf8)
        Write-Host "created access key $($k.AccessKeyId) (secret saved to $envOut, not printed)"
        $k = $null; $content = ""
    }
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
