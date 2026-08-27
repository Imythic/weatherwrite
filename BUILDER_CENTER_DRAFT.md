# WeatherWrite — Builder Center Submission Draft

Project: WeatherWrite — Daily Rain Muse

Summary
- WeatherWrite pulls real weather from Open-Meteo, sends it to Amazon Bedrock (Nova Lite) to write a short original poem + image-direction prompt, optionally sends that prompt to Bedrock (Nova Canvas) for matching artwork, and publishes the result as static `brief.json` / `brief_image.png` files that a lightweight static frontend consumes.
- Architecture: AWS Lambda (Python) fetches weather → calls Bedrock for text (and optionally image) → writes `brief.json`/`brief_image.png` to S3 (public) → S3 serves a static frontend. Lambda is scheduled via EventBridge (cron/6-hour cadence) so the site is always refreshed.

Why it qualifies
- Static site on S3 (static frontend included). Lambda function packaged and deployed (zip + IAM role). EventBridge rule schedules Lambda (always-on behavior requirement satisfied).
- Live Bedrock integration: the Lambda calls Bedrock Nova Lite for text generation on every scheduled run (controlled via `USE_BEDROCK`, `BEDROCK_TEXT_MODEL`, `BEDROCK_IMAGE_MODEL`), and degrades gracefully to a built-in template if a Bedrock call fails for any reason (e.g. a model not being enabled for the account).

Security & operational notes
- The `deploy.sh` script creates an S3 bucket, IAM role, and Lambda. Review the script before running in a real account.
- `deploy.sh` supports local seeding mode for preview (`LOCAL_SEED=1`) and will not call AWS when used only for local testing.

Deliverables
- Packaged Lambda zip (produced by `package_lambda.sh` / `package_lambda.ps1`).
- `frontend/` static site with `brief.json` seeded for preview.

Contact
- The creative-agent companion project (local development of the generator service) lives in a separate repo/folder, not included here.
