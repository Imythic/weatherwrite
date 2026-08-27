#!/usr/bin/env bash
set -euo pipefail

# WeatherWrite deployment script
# Edit BUCKET_NAME below — must be globally unique
BUCKET_NAME="weatherwrite-omarf-20260823-7b2c"
REGION="us-east-1"
# When set to 1, perform a local seed by invoking the lambda generator
# with a `local` flag and skip AWS provisioning (useful for testing).
# Default enabled for easier local testing.
LOCAL_SEED=1
LAMBDA_NAME="weatherwrite-generator"
ROLE_NAME="weatherwrite-lambda-role"
ZIP_NAME="lambda_package.zip"

# Location used for the weather signal (Open-Meteo, no API key required)
LOCATION_NAME="Seattle, WA"
LATITUDE="47.6062"
LONGITUDE="-122.3321"

# Set to 1 to enrich the brief via Amazon Bedrock (Nova Lite for text, Nova
# Canvas for artwork). Requires model access granted in the Bedrock console
# for the configured models. Falls back to the built-in template on failure.
USE_BEDROCK="1"
BEDROCK_TEXT_MODEL="amazon.nova-lite-v1:0"
BEDROCK_IMAGE_MODEL="amazon.nova-canvas-v1:0"

echo "Using BUCKET_NAME=${BUCKET_NAME}"

# Local temp dir (not /tmp: unreliable under Git Bash on Windows). Use a
# native Windows-style path (via `pwd -W` when available) so it resolves
# correctly whether it's read by bash or handed to a native exe like aws.exe.
TMP_DIR="$( (pwd -W 2>/dev/null || pwd) )/.deploy-tmp"
mkdir -p "$TMP_DIR"

if [ "${LOCAL_SEED}" = "1" ]; then
  echo "LOCAL_SEED=1: invoking local generator to write frontend/brief.json and exiting"
  if command -v python3 >/dev/null 2>&1; then
    PY_CMD=python3
  elif command -v python >/dev/null 2>&1; then
    PY_CMD=python
  else
    echo "python not found on PATH; cannot run local seed"
    exit 1
  fi
  # Resolve script (project root) path
  SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd || echo .)"

  # If bash is available, run a here-doc in a subshell to keep behavior consistent.
  if command -v bash >/dev/null 2>&1; then
    bash -c "cd '$SCRIPT_DIR' && $PY_CMD - <<'PY'
import sys, json, os
sys.path.insert(0, os.path.join(os.getcwd(), 'lambda'))
import generator
res = generator.handler({'local': True}, None)
print(json.dumps(res, indent=2))
PY"
  else
    # Fallback: run a single-line python invocation from the project root
    (cd "$SCRIPT_DIR" 2>/dev/null || true)
    $PY_CMD -c "import sys,json,os; sys.path.insert(0, os.path.join(os.getcwd(),'lambda')); import generator; res=generator.handler({'local': True}, None); print(json.dumps(res, indent=2))"
  fi
  exit 0
fi

# 1) Create S3 bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket $BUCKET_NAME already exists."
else
  echo "Creating bucket: $BUCKET_NAME"
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
    --create-bucket-configuration LocationConstraint=$REGION
fi

# 2) Enable website hosting
aws s3 website s3://$BUCKET_NAME/ --index-document index.html --error-document index.html

# 3) Upload frontend
# (no --acl: modern buckets have ACLs disabled; public read comes from the bucket policy)
aws s3 sync frontend/ s3://$BUCKET_NAME/ --delete

# Ensure the bucket policy grants public GetObject (idempotent, scoped to this bucket)
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy '{"Version":"2012-10-17","Statement":[{"Sid":"PublicReadGetObject","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::'$BUCKET_NAME'/*"}]}'

# 4) Create IAM role for Lambda
TRUST_POLICY=$(cat <<EOF
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
EOF
)

echo "$TRUST_POLICY" > "$TMP_DIR/weatherwrite-trust.json"

if aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
  echo "IAM role $ROLE_NAME exists."
else
  echo "Creating IAM role $ROLE_NAME"
  aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document "file://$TMP_DIR/weatherwrite-trust.json"
  aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi

# Keep the inline S3 and Bedrock policies up to date whether the role is new or existing
aws iam put-role-policy --role-name $ROLE_NAME --policy-name WeatherWriteS3Access --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::'$BUCKET_NAME'","arn:aws:s3:::'$BUCKET_NAME'/*"]}]}'
aws iam put-role-policy --role-name $ROLE_NAME --policy-name WeatherWriteBedrockAccess --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:InvokeModel"],"Resource":["arn:aws:bedrock:'$REGION'::foundation-model/'$BEDROCK_TEXT_MODEL'","arn:aws:bedrock:'$REGION'::foundation-model/'$BEDROCK_IMAGE_MODEL'"]}]}'

# Allow IAM propagation to settle
echo "Waiting 10s for IAM propagation..."
sleep 10

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)
echo "Using role: $ROLE_ARN"

# 5) Package Lambda function
rm -f "$ZIP_NAME"
if command -v zip >/dev/null 2>&1; then
  (cd lambda && zip -r "../$ZIP_NAME" .)
elif command -v powershell.exe >/dev/null 2>&1; then
  echo "zip not found; packaging with PowerShell Compress-Archive"
  powershell.exe -NoProfile -Command "Compress-Archive -Path 'lambda\\*' -DestinationPath '$ZIP_NAME' -Force"
else
  echo "Neither zip nor powershell.exe found; cannot package Lambda"
  exit 1
fi

# 6) Create or update Lambda function
if aws lambda get-function --function-name $LAMBDA_NAME >/dev/null 2>&1; then
  echo "Updating Lambda function $LAMBDA_NAME"
  aws lambda update-function-code --function-name $LAMBDA_NAME --zip-file fileb://$ZIP_NAME
  aws lambda wait function-updated --function-name $LAMBDA_NAME
else
  echo "Creating Lambda function $LAMBDA_NAME"
  aws lambda create-function --function-name $LAMBDA_NAME \
    --runtime python3.11 --role "$ROLE_ARN" --handler generator.handler --zip-file fileb://$ZIP_NAME --timeout 30
  aws lambda wait function-active --function-name $LAMBDA_NAME
fi

# 6b) Always (re)apply the environment variables so config can't silently drift
# (JSON, not the Variables={a=b,c=d} shorthand: values like "Seattle, WA" contain commas)
echo "Setting Lambda environment variables"
ENV_JSON=$(cat <<EOF
{"Variables":{"BUCKET_NAME":"$BUCKET_NAME","LOCATION_NAME":"$LOCATION_NAME","LATITUDE":"$LATITUDE","LONGITUDE":"$LONGITUDE","USE_BEDROCK":"$USE_BEDROCK","BEDROCK_TEXT_MODEL":"$BEDROCK_TEXT_MODEL","BEDROCK_IMAGE_MODEL":"$BEDROCK_IMAGE_MODEL"}}
EOF
)
aws lambda update-function-configuration --function-name $LAMBDA_NAME --environment "$ENV_JSON"
aws lambda wait function-updated --function-name $LAMBDA_NAME

# 7) Give the Lambda permission to be invoked by EventBridge (idempotent: ignore "already exists")
aws lambda add-permission --function-name $LAMBDA_NAME --action lambda:InvokeFunction --principal events.amazonaws.com --statement-id "AllowEventsTrigger" 2>/dev/null || true

# 8) Create EventBridge schedule (every 6 hours)
RULE_NAME="weatherwrite-schedule"
aws events put-rule --name $RULE_NAME --schedule-expression "rate(6 hours)" --state ENABLED
TARGET_ID="1"
aws events put-targets --rule $RULE_NAME --targets "Id=$TARGET_ID,Arn=$(aws lambda get-function --function-name $LAMBDA_NAME --query Configuration.FunctionArn --output text)"

# 9) Add permission so EventBridge can invoke the Lambda (idempotent: ignore "already exists")
aws lambda add-permission --function-name $LAMBDA_NAME --statement-id "EventBridgeInvoke" --action "lambda:InvokeFunction" --principal events.amazonaws.com --source-arn $(aws events describe-rule --name $RULE_NAME --query Arn --output text) 2>/dev/null || true

# 10) Run the lambda once to produce initial `brief.json`
echo "Invoking generator once to populate site"
aws lambda invoke --function-name $LAMBDA_NAME --payload '{}' "$TMP_DIR/weatherwrite-invoke.json"

# 11) Print website URL
echo "Deployment complete. Your S3 website URL will be:"
if [ "$REGION" = "us-east-1" ]; then
  echo "http://$BUCKET_NAME.s3-website.amazonaws.com/"
else
  echo "http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com/"
fi

echo "Cleanup: removing temporary files"
rm -rf "$TMP_DIR" "$ZIP_NAME"
