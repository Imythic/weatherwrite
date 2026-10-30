# WeatherWrite — Daily Rain Muse

**Live demo:** https://rain-muse-weatherwrite.vercel.app *(static snapshot of the last generated brief — the scheduled Lambda isn't running continuously in this deploy, so it won't refresh live)*

WeatherWrite is a minimal always-on creative agent built for the Weekend Creative Agent Challenge. A scheduled AWS Lambda pulls the current weather for a fixed location, asks Amazon Bedrock (Nova Lite) to write a short poem and image direction from it, and publishes the result as `brief.json` (plus artwork from Nova Canvas, when available), which a tiny static frontend reads and renders.

## Architecture

- **Lambda** (`lambda/generator.py`) fetches current weather from [Open-Meteo](https://open-meteo.com/) (no API key needed), asks **Amazon Bedrock Nova Lite** to write a poem + image prompt from it, optionally asks **Amazon Bedrock Nova Canvas** to generate matching artwork, and writes `brief.json` (+ `brief_image.png` if artwork was generated) — to S3 in production, or to `frontend/` locally.
- **S3 static website** serves the frontend and the generated files.
- **EventBridge** triggers the Lambda on a schedule (every 6 hours).
- Bedrock is optional and degrades gracefully: set `USE_BEDROCK=1` (with `BEDROCK_TEXT_MODEL` / `BEDROCK_IMAGE_MODEL`) in the Lambda environment to enable it. If a Bedrock call fails (e.g. a model isn't enabled for your account), the brief falls back to a built-in poem template rather than failing the run — check `text_source` / `image_source` / `has_image` in `brief.json` to see what actually generated each run.

## Quickstart (local preview, no AWS required)

1. Seed the static frontend locally:

```bash
python -c "import sys,json; sys.path.insert(0, 'lambda'); import generator; generator.handler({'local': True}, None)"
```

2. Serve the frontend locally:

```bash
cd frontend
python -m http.server 8000
# open http://localhost:8000
```

## Deploy to AWS (full provisioning)

Requirements: AWS CLI configured with credentials that can create S3, Lambda, IAM, and EventBridge resources.

1. Edit `deploy.sh` (or `deploy.ps1` on Windows) and set `BUCKET_NAME` to a globally unique name, and `REGION` (defaults to `us-east-1`).
2. Run:

```bash
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` defaults to local seeding (`LOCAL_SEED=1`), so running it without AWS credentials only seeds the frontend. Set `LOCAL_SEED=0` in the script to perform full provisioning.

The script creates an S3 website bucket, an IAM role for Lambda, the Lambda function itself, and an EventBridge schedule. After deployment it prints the S3 website URL.

Alternative deployment path via CloudFormation/SAM (no SAM CLI required) is documented in `README_DEPLOY.md`.

## Files of interest

- `lambda/generator.py` — Lambda handler that creates `brief.json` and uploads it to S3 (or writes it locally when seeded).
- `deploy.sh` / `deploy.ps1` — provisioning and packaging scripts (S3 website, IAM role, Lambda, EventBridge schedule).
- `package_lambda.sh` / `package_lambda.ps1` — package `lambda/` into a deployable zip.
- `frontend/` — static site that reads `brief.json`.
- `weatherwrite-sam.yaml` — CloudFormation/SAM template for an alternative deploy path.

## Notes

- If IAM propagation/assume-role errors occur during deploy, wait a few seconds and retry — this is normal AWS propagation behavior.
- Bedrock models must be enabled for your account/region (Bedrock console → Model access) before `USE_BEDROCK=1` will actually call them; until then, or if a call fails for any reason, the brief silently falls back to the built-in template.
