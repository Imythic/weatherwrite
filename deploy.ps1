param(
    [string]$BucketName = "weatherwrite-omarf-20260823-7b2c",
    [string]$Region = "us-east-1",
    [switch]$LocalSeed = $true
)

Set-StrictMode -Version Latest

function Check-Cmd($name) {
    return (Get-Command $name -ErrorAction SilentlyContinue) -ne $null
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path $scriptDir

Write-Output "Using BUCKET_NAME=$BucketName, REGION=$Region, LocalSeed=$LocalSeed"

if ($LocalSeed) {
    Write-Output "LOCAL_SEED: running local generator and exiting"
    if (Check-Cmd python3) { $py = "python3" }
    elseif (Check-Cmd python) { $py = "python" }
    else { Write-Error "python not found on PATH; cannot run local seed"; exit 1 }

    $tmp = [System.IO.Path]::GetTempFileName() + '.py'
    $pycode = @'
import sys, json, os
sys.path.insert(0, os.path.join(os.getcwd(), 'lambda'))
import generator
res = generator.handler({'local': True}, None)
print(json.dumps(res, indent=2))
'@
    Set-Content -Path $tmp -Value $pycode -Encoding UTF8
    Push-Location $repoRoot
    & $py $tmp
    $LASTEXITCODE | Out-Null
    Pop-Location
    Remove-Item $tmp -ErrorAction SilentlyContinue
    exit 0
}

if (-not (Check-Cmd aws)) {
    Write-Error "AWS CLI not found in PATH. Install AWS CLI v2 and retry."
    exit 1
}

# 1) Create S3 bucket (handle us-east-1 special case)
try {
    if (aws s3api head-bucket --bucket $BucketName 2>$null) {
        Write-Output "Bucket $BucketName already exists."
    }
} catch {
    Write-Output "Creating bucket: $BucketName"
    if ($Region -eq 'us-east-1') {
        aws s3api create-bucket --bucket $BucketName --region $Region
    } else {
        aws s3api create-bucket --bucket $BucketName --region $Region --create-bucket-configuration LocationConstraint=$Region
    }
}

# verify bucket exists now
try {
    aws s3api head-bucket --bucket $BucketName 2>$null
} catch {
    Write-Error "Failed to create or access bucket $BucketName. Aborting."
    exit 1
}

# 2) Enable website hosting
aws s3 website s3://$BucketName/ --index-document index.html --error-document index.html

# 3) Upload frontend
Write-Output "Uploading frontend to s3://$BucketName/"
aws s3 sync frontend\ s3://$BucketName/ --acl public-read --delete

# 4) Create IAM role for Lambda
$trust = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
'@
$trustFile = Join-Path $env:TEMP 'weatherwrite-trust.json'
    # write trust file without BOM to avoid CLI JSON parsing issues
    [System.IO.File]::WriteAllText($trustFile, $trust, (New-Object System.Text.UTF8Encoding($false)))

Write-Output "Wrote trust file: $trustFile"
Get-Content -Path $trustFile | Write-Output

$roleName = 'weatherwrite-lambda-role'
try {
    aws iam get-role --role-name $roleName >/dev/null 2>&1
    Write-Output "IAM role $roleName exists."
} catch {
    Write-Output "Creating IAM role $roleName"
    # use file:/// URI with forward slashes to avoid Windows path parsing issues
    # Use Windows-friendly file URI (no leading extra slash) so AWS CLI accepts the paramfile on Windows
    $trustUri = "file://" + $trustFile
    $createRoleOut = & aws iam create-role --role-name $roleName --assume-role-policy-document $trustUri 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create IAM role. AWS output:\n$createRoleOut"
        exit 1
    }
    $attachOut = & aws iam attach-role-policy --role-name $roleName --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to attach basic execution policy to role. AWS output:\n$attachOut"
        exit 1
    }
    $s3policy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
            "Resource": [
                "arn:aws:s3:::$BucketName",
                "arn:aws:s3:::$BucketName/*"
            ]
        }
    ]
}
"@
    $policyFile = Join-Path $env:TEMP 'weatherwrite-s3policy.json'
    # write policy file without BOM and use file:/// URI
    [System.IO.File]::WriteAllText($policyFile, $s3policy, (New-Object System.Text.UTF8Encoding($false)))
    $policyUri = "file://" + $policyFile
    $putPolicyOut = & aws iam put-role-policy --role-name $roleName --policy-name WeatherWriteS3Access --policy-document $policyUri 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to put inline S3 policy on role. AWS output:\n$putPolicyOut"
        exit 1
    }
}

Write-Output "Waiting 10s for IAM propagation..."
Start-Sleep -Seconds 10

$roleArn = aws iam get-role --role-name $roleName --query Role.Arn --output text
Write-Output "Using role: $roleArn"
if (-not $roleArn) {
    Write-Error "Role ARN is empty; role creation must have failed. Aborting."
    exit 1
}

# 5) Package Lambda function
Push-Location $repoRoot
$zip = Join-Path $repoRoot 'lambda_package.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $repoRoot 'lambda\*') -DestinationPath $zip -Force
Pop-Location

# 6) Create or update Lambda function
$lambdaName = 'weatherwrite-generator'
try {
    aws lambda get-function --function-name $lambdaName >/dev/null 2>&1
    Write-Output "Updating Lambda function $lambdaName"
    aws lambda update-function-code --function-name $lambdaName --zip-file fileb://$zip
} catch {
    Write-Output "Creating Lambda function $lambdaName"
    aws lambda create-function --function-name $lambdaName --runtime python3.11 --role $roleArn --handler generator.handler --zip-file fileb://$zip --timeout 30
}

# 7) Give the Lambda permission to be invoked by EventBridge (ignore errors)
& aws lambda add-permission --function-name $lambdaName --action lambda:InvokeFunction --principal events.amazonaws.com --statement-id "AllowEventsTrigger" 2>$null

# 8) Create EventBridge schedule (every 6 hours)
$ruleName = 'weatherwrite-schedule'
aws events put-rule --name $ruleName --schedule-expression "rate(6 hours)" --state ENABLED
$targetArn = aws lambda get-function --function-name $lambdaName --query Configuration.FunctionArn --output text
aws events put-targets --rule $ruleName --targets "Id=1,Arn=$targetArn"

# 9) Add permission so EventBridge can invoke the Lambda
$ruleArn = aws events describe-rule --name $ruleName --query Arn --output text
aws lambda add-permission --function-name $lambdaName --statement-id "EventBridgeInvoke" --action "lambda:InvokeFunction" --principal events.amazonaws.com --source-arn $ruleArn 2>$null

# 10) Run the lambda once to produce initial `brief.json`
Write-Output "Invoking generator once to populate site"
aws lambda invoke --function-name $lambdaName --payload '{}' $env:TEMP\weatherwrite-invoke.json

# 11) Print website URL
Write-Output "Deployment complete. Your S3 website URL will be:"
if ($Region -eq 'us-east-1') {
    Write-Output "http://$BucketName.s3-website.amazonaws.com/"
} else {
    Write-Output "http://$BucketName.s3-website-$Region.amazonaws.com/"
}

Write-Output "Cleanup: removing temporary files"
Remove-Item -Path $trustFile -ErrorAction SilentlyContinue
Remove-Item -Path $policyFile -ErrorAction SilentlyContinue
Remove-Item -Path $env:TEMP\weatherwrite-invoke.json -ErrorAction SilentlyContinue
Remove-Item -Path $zip -ErrorAction SilentlyContinue
