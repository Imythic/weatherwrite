Deployment notes — WeatherWrite

Quick steps to package and deploy using AWS CLI / CloudFormation (no SAM CLI required):

1) Package Lambda code into a zip (PowerShell):

   .\package_lambda.ps1

   or (bash):

   ./package_lambda.sh weatherwrite-generator.zip

2) Upload the code zip to an S3 staging bucket (you choose the bucket):

   aws s3 cp weatherwrite-generator.zip s3://<staging-bucket>/weatherwrite-generator.zip

3) Package the CloudFormation template:

   aws cloudformation package --template-file weatherwrite-sam.yaml --s3-bucket <staging-bucket> --output-template-file packaged.yaml

4) Deploy the stack:

   aws cloudformation deploy --template-file packaged.yaml --stack-name weatherwrite-stack --capabilities CAPABILITY_NAMED_IAM

5) After deploy, the stack outputs include the website URL. The generator will run on schedule.

Local preview / seed:

 - Generate locally: run the `generator.handler({'local': True})` call to write `frontend/brief.json`.
 - Upload objects manually if needed: `aws s3 cp frontend/ s3://<bucket>/ --recursive` (do not use `--acl` if your bucket blocks ACLs).
