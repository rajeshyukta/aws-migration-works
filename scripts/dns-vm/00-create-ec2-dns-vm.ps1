# Idempotently create the dual-IP DNS-VM (EC2 t3.small, Ubuntu 24.04) in ap-south-1b
# and attach both Elastic IPs: 52.66.165.1 (NS-1, primary) and 52.66.25.51 (NS-2, secondary).
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$aws = ""
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if ($awsCmd) { $aws = $awsCmd.Source }
elseif (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe") {
    $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}
if (-not $aws) { throw "aws CLI not found" }

$region = "ap-south-1"
$vpcId = "vpc-07956d60b5c929e71"
$subnetId = "subnet-0bcbdbc33be3f45c1"
$amiId = "ami-050de854a1e5cfc1c"
$keyName = "dithim-aws"
$eipNs1 = "eipalloc-0f467a2873cd95ffb"   # 52.66.165.1
$eipNs2 = "eipalloc-07e92fb800a084178"   # 52.66.25.51

Write-Host "==> Ensuring Security Group DNS-VM-SG in $vpcId..."
$sgId = (& $aws ec2 describe-security-groups --region $region --filters "Name=vpc-id,Values=$vpcId" "Name=group-name,Values=DNS-VM-SG" --query "SecurityGroups[0].GroupId" --output text).Trim()
if (-not $sgId -or $sgId -eq "None") {
    $sgId = (& $aws ec2 create-security-group --region $region --group-name DNS-VM-SG --description "DNS-VM dual-IP NS1/NS2 + dns-service" --vpc-id $vpcId --query "GroupId" --output text).Trim()
}
$sgJson = (& $aws ec2 describe-security-groups --region $region --group-ids $sgId --query "SecurityGroups[0].IpPermissions" --output json) | ConvertFrom-Json
foreach ($rule in @(
    @{ proto = "tcp"; port = 22 },
    @{ proto = "tcp"; port = 80 },
    @{ proto = "tcp"; port = 443 },
    @{ proto = "tcp"; port = 53 },
    @{ proto = "udp"; port = 53 }
)) {
    $exists = $sgJson | Where-Object { $_.IpProtocol -eq $rule.proto -and $_.FromPort -eq $rule.port -and ($_.IpRanges.CidrIp -contains "0.0.0.0/0") }
    if (-not $exists) {
        & $aws ec2 authorize-security-group-ingress --region $region --group-id $sgId --protocol $rule.proto --port $rule.port --cidr 0.0.0.0/0 | Out-Null
    }
}
Write-Host "    SG: $sgId"

Write-Host "==> Checking existing DNS-VM instance..."
$instId = (& $aws ec2 describe-instances --region $region --filters "Name=tag:Name,Values=DNS-VM" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text).Trim()
if (-not $instId -or $instId -eq "None") {
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dns-vm-aws-$PID")
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $netIfFile = Join-Path $tmpDir "netif.json"
        $bdmFile = Join-Path $tmpDir "bdm.json"
        $tagsFile = Join-Path $tmpDir "tags.json"

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $netIfObj = @(@{
            DeviceIndex = 0
            SubnetId = $subnetId
            Groups = @($sgId)
            AssociatePublicIpAddress = $false
            SecondaryPrivateIpAddressCount = 1
            DeleteOnTermination = $true
        })
        [System.IO.File]::WriteAllText($netIfFile, (ConvertTo-Json -InputObject $netIfObj -Depth 5), $utf8NoBom)

        $bdmObj = @(@{
            DeviceName = "/dev/sda1"
            Ebs = @{
                VolumeSize = 30
                VolumeType = "gp3"
                DeleteOnTermination = $true
            }
        })
        [System.IO.File]::WriteAllText($bdmFile, (ConvertTo-Json -InputObject $bdmObj -Depth 5), $utf8NoBom)

        $tagsObj = @(
            @{ ResourceType = "instance"; Tags = @(@{ Key = "Name"; Value = "DNS-VM" }) },
            @{ ResourceType = "volume"; Tags = @(@{ Key = "Name"; Value = "DNS-VM" }) }
        )
        [System.IO.File]::WriteAllText($tagsFile, (ConvertTo-Json -InputObject $tagsObj -Depth 5), $utf8NoBom)

        Write-Host "==> Launching EC2 t3.small (Ubuntu 24.04, 30 GB gp3) in $subnetId..."
        $instId = (& $aws ec2 run-instances `
            --region $region `
            --image-id $amiId `
            --instance-type t3.small `
            --key-name $keyName `
            --network-interfaces "file://$netIfFile" `
            --block-device-mappings "file://$bdmFile" `
            --tag-specifications "file://$tagsFile" `
            --metadata-options "HttpTokens=required,HttpEndpoint=enabled" `
            --query "Instances[0].InstanceId" --output text).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $instId) { throw "run-instances failed" }
        Write-Host "    Waiting for instance-running ($instId)..."
        & $aws ec2 wait instance-running --region $region --instance-ids $instId
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "    Instance: $instId"

$eniJson = (& $aws ec2 describe-instances --region $region --instance-ids $instId --query "Reservations[0].Instances[0].NetworkInterfaces[0].{EniId:NetworkInterfaceId,Privs:PrivateIpAddresses[].{Ip:PrivateIpAddress,Primary:Primary}}" --output json) | ConvertFrom-Json
$eniId = $eniJson.EniId
$priv1 = ($eniJson.Privs | Where-Object { $_.Primary -eq $true }).Ip
$priv2Obj = $eniJson.Privs | Where-Object { $_.Primary -ne $true } | Select-Object -First 1
if (-not $priv2Obj) {
    Write-Host "==> Assigning secondary private IP on $eniId..."
    & $aws ec2 assign-private-ip-addresses --region $region --network-interface-id $eniId --secondary-private-ip-address-count 1 | Out-Null
    $eniJson = (& $aws ec2 describe-instances --region $region --instance-ids $instId --query "Reservations[0].Instances[0].NetworkInterfaces[0].{EniId:NetworkInterfaceId,Privs:PrivateIpAddresses[].{Ip:PrivateIpAddress,Primary:Primary}}" --output json) | ConvertFrom-Json
    $priv2Obj = $eniJson.Privs | Where-Object { $_.Primary -ne $true } | Select-Object -First 1
}
$priv2 = $priv2Obj.Ip

Write-Host "==> Associating NS-1 (52.66.165.1) -> $priv1 and NS-2 (52.66.25.51) -> $priv2..."
& $aws ec2 associate-address --region $region --allocation-id $eipNs1 --network-interface-id $eniId --private-ip-address $priv1 --allow-reassociation | Out-Null
& $aws ec2 associate-address --region $region --allocation-id $eipNs2 --network-interface-id $eniId --private-ip-address $priv2 --allow-reassociation | Out-Null

Write-Host "==> Waiting for EC2 status checks (instance-status-ok)..."
& $aws ec2 wait instance-status-ok --region $region --instance-ids $instId

Write-Host "DNS-VM ready:"
Write-Host "  InstanceId = $instId"
Write-Host "  ENI        = $eniId"
Write-Host "  Primary    = 52.66.165.1 ($priv1)"
Write-Host "  Secondary  = 52.66.25.51 ($priv2)"
