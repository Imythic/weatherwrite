# WeatherWrite — Daily Rain Muse

An always-on creative agent that pulls the real weather and turns it into a
fresh AI-written poem every 6 hours — with no one having to open anything
for it to happen.

Built for the AWS Builder Center Weekend Creative Agent Challenge.

Try it here: http://weatherwrite-omarf-20260823-7b2c.s3-website-us-east-1.amazonaws.com/
Source code: https://github.com/Imythic/weatherwrite

## What it does

Each scheduled run, the agent:
1. Pulls current weather conditions (temperature, wind, sky condition) for a
   fixed location (Seattle, WA) from Open-Meteo — no API key needed.
2. Sends that weather into **Amazon Bedrock (Nova Lite)** to write a short,
   original poem and a matching image-direction prompt, themed to the day's
   conditions.
3. Optionally sends the image prompt to **Amazon Bedrock (Nova Canvas)** to
   generate matching artwork. If image generation isn't available, the
   brief is published without it rather than failing the run.
4. Writes the result to an **S3** bucket as `brief.json` (+ `brief_image.png`
   when artwork was generated), which also serves as a static website.

Visiting the site any time shows whatever the agent generated most recently
— it doesn't need to be told to run, and nothing has to stay running between
generations. `brief.json` records exactly what produced each run
(`text_source`, `image_source`, `has_image`), so it's honest about whether a
given brief came from the model or the fallback template.

## Architecture

```
EventBridge rule (rate: every 6h)
        |
        v
   AWS Lambda (weatherwrite-generator)  ---->  Open-Meteo (weather, no key needed)
        |
        |----> Amazon Bedrock: Nova Lite   (writes the poem + image prompt)
        |----> Amazon Bedrock: Nova Canvas (generates matching artwork, when available)
        |
        v
   Amazon S3 (brief.json, brief_image.png, static website hosting)
        |
        v
   Anyone visiting the S3 website URL
```

All Free Tier eligible: Lambda's monthly free request/compute allowance
easily covers a run every 6 hours, S3 storage for a couple of small files is
negligible, the EventBridge rule has no charge at this volume, and Bedrock
is pay-per-call but cheap for one short text generation every 6 hours.

## Deploying it yourself

1. In the Bedrock console, request model access for **Nova Lite** and
   **Nova Canvas** (Model access page).
2. Edit the variables at the top of `deploy.sh` (or `deploy.ps1` on
   Windows) — bucket name must be globally unique.
3. Run `chmod +x deploy.sh && ./deploy.sh` with the AWS CLI configured
   against your account. (`deploy.sh` defaults to `LOCAL_SEED=1`, which
   only seeds the frontend locally — set it to `0` to actually provision
   AWS resources.)
4. Visit the printed S3 website URL.

Alternative CloudFormation/SAM path documented in `README_DEPLOY.md`
(`weatherwrite-sam.yaml`).

## Files

- `lambda/generator.py` — the agent itself (weather + Bedrock text/image + S3 publish)
- `frontend/index.html` — static site that displays the latest brief and artwork
- `deploy.sh` / `deploy.ps1` — end-to-end AWS CLI deployment
- `package_lambda.sh` / `package_lambda.ps1` — package the Lambda into a zip
- `policy.json` — S3 bucket public-read policy
- `weatherwrite-deploy-policy.json` — least-privilege IAM policy for the
  deploying user/role
- `weatherwrite-sam.yaml` — CloudFormation/SAM template (alternative deploy)

## What I learned

Two things stood out, and neither was about the creative generation itself.

First: making the agent genuinely low-maintenance is where the real work
is. After first deploying, the scheduled Lambda was silently failing on
every run because the `BUCKET_NAME` environment variable hadn't been set —
the site sat on a two-day-old brief with no visible error on the frontend.
Tracking that down through CloudWatch Logs, and then making `deploy.sh`
always re-apply the full environment configuration on every deploy (instead
of only setting it once by hand), turned a silent one-off failure mode into
something that can't drift again.

Second: "the model exists" isn't the same as "the model is callable."
Amazon Nova Canvas showed up as an available foundation model, but Bedrock
rejected every invocation with "Legacy and you have not been actively using
the model in the last 30 days" — an account-level restriction, not a config
or permissions bug. The generator treats this the same way it treats a
transient failure: catch it, log it, publish the brief without artwork
instead of breaking the whole pipeline. The poem generation via Nova Lite
worked immediately once IAM had `bedrock:InvokeModel` scoped to the model
ARN.

#agents
