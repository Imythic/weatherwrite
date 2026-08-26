# WeatherWrite — Builder Center Submission Draft

Project: WeatherWrite — Daily Rain Muse

Summary
- WeatherWrite produces a short creative brief (copy + image direction + a short poem) every scheduled interval and publishes it as a static `brief.json` that a lightweight static frontend consumes.
- Architecture: AWS Lambda (Python) generates the brief → writes `brief.json` to S3 (public) → S3 serves a static frontend. Lambda is scheduled via EventBridge (cron/6-hour cadence) so the site is always refreshed.

Why it qualifies
- Static site on S3 (static frontend included). Lambda function packaged and deployed (zip + IAM role). EventBridge rule schedules Lambda (always-on behavior requirement satisfied).
- Optional Bedrock integration included: the Lambda can optionally call Bedrock (controlled via `USE_BEDROCK` and `BEDROCK_MODEL`).

What to include in the Builder Center submission
- This repo, with `frontend/`, `lambda/generator.py`, and `deploy.sh`.
- A short README with: how to run locally, how to deploy (BUCKET_NAME + region + AWS creds), and how to preview the seeded static site.
- Notes about Bedrock: enable with env vars and provide model id; the project degrades gracefully when Bedrock is not available.

Security & operational notes
- The `deploy.sh` script creates an S3 bucket, IAM role, and Lambda. Review the script before running in a real account.
- `deploy.sh` supports local seeding mode for preview (`LOCAL_SEED=1`) and will not call AWS when used only for local testing.

Deliverables
- Packaged Lambda zip (produced by `package_lambda.sh` / `package_lambda.ps1`).
- `frontend/` static site with `brief.json` seeded for preview.

Contact
- The creative-agent companion project (local development of the generator service) lives in a separate repo/folder, not included here.
