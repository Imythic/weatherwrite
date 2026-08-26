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

echo "Using BUCKET_NAME=${BUCKET_NAME}"

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
aws s3 sync frontend/ s3://$BUCKET_NAME/ --acl public-read --delete

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

echo "$TRUST_POLICY" > /tmp/weatherwrite-trust.json

if aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
  echo "IAM role $ROLE_NAME exists."
else
  echo "Creating IAM role $ROLE_NAME"
  aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file:///tmp/weatherwrite-trust.json
  # Attach basic execution policy and S3 access
  aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam put-role-policy --role-name $ROLE_NAME --policy-name WeatherWriteS3Access --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::'$BUCKET_NAME'","arn:aws:s3:::'$BUCKET_NAME'/*"]}]}'
fi

# Allow IAM propagation to settle
echo "Waiting 10s for IAM propagation..."
sleep 10

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)
echo "Using role: $ROLE_ARN"

# 5) Package Lambda function
cd lambda
zip -r ../$ZIP_NAME .
cd ..

# 6) Create or update Lambda function
if aws lambda get-function --function-name $LAMBDA_NAME >/dev/null 2>&1; then
  echo "Updating Lambda function $LAMBDA_NAME"
  aws lambda update-function-code --function-name $LAMBDA_NAME --zip-file fileb://$ZIP_NAME
else
  echo "Creating Lambda function $LAMBDA_NAME"
  aws lambda create-function --function-name $LAMBDA_NAME \
    --runtime python3.11 --role "$ROLE_ARN" --handler generator.handler --zip-file fileb://$ZIP_NAME --timeout 30
fi

# 7) Give the Lambda permission to be invoked by EventBridge
aws lambda add-permission --function-name $LAMBDA_NAME --action lambda:InvokeFunction --principal events.amazonaws.com --statement-id "AllowEventsTrigger" || true

# 8) Create EventBridge schedule (every 6 hours)
RULE_NAME="weatherwrite-schedule"
aws events put-rule --name $RULE_NAME --schedule-expression "rate(6 hours)" --state ENABLED
TARGET_ID="1"
aws events put-targets --rule $RULE_NAME --targets "Id=$TARGET_ID,Arn=$(aws lambda get-function --function-name $LAMBDA_NAME --query Configuration.FunctionArn --output text)"

# 9) Add permission so EventBridge can invoke the Lambda (idempotent)
aws lambda add-permission --function-name $LAMBDA_NAME --statement-id "EventBridgeInvoke" --action "lambda:InvokeFunction" --principal events.amazonaws.com --source-arn $(aws events describe-rule --name $RULE_NAME --query Arn --output text) || true

# 10) Run the lambda once to produce initial `brief.json`
echo "Invoking generator once to populate site"
aws lambda invoke --function-name $LAMBDA_NAME --payload '{}' /tmp/weatherwrite-invoke.json

# 11) Print website URL
echo "Deployment complete. Your S3 website URL will be:"
if [ "$REGION" = "us-east-1" ]; then
  echo "http://$BUCKET_NAME.s3-website.amazonaws.com/"
else
  echo "http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com/"
fi

echo "Cleanup: removing temporary files"
rm -f /tmp/weatherwrite-trust.json /tmp/weatherwrite-invoke.json $ZIP_NAME
