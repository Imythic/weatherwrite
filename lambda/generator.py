import json
import os
try:
    import boto3
except Exception:
    boto3 = None
from datetime import datetime
from pathlib import Path

# boto3 may be unavailable in local dev environments; create client only when present
s3 = boto3.client('s3') if boto3 is not None else None
# Accept either BUCKET_NAME (preferred) or TARGET_BUCKET (legacy) for compatibility
BUCKET = os.environ.get('BUCKET_NAME') or os.environ.get('TARGET_BUCKET')

# Local write flag: set env LOCAL_WRITE=1 or pass event {'local': True}
LOCAL_WRITE = os.environ.get('LOCAL_WRITE', '0') == '1'

# Optional Bedrock runtime client (invoke only when enabled)
USE_BEDROCK = os.environ.get('USE_BEDROCK', '0') == '1'
BEDROCK_MODEL = os.environ.get('BEDROCK_MODEL')
bedrock_client = None
if USE_BEDROCK and boto3 is not None:
    try:
        bedrock_client = boto3.client('bedrock-runtime')
    except Exception:
        bedrock_client = None

def make_brief():
    now = datetime.utcnow()
    time_label = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    poem = (
        "Clouds keep a ledger of small mercies;\n"
        "A rim of light reminds the rooftops to remember rain.\n"
        "Collect what falls, let the city drink slowly —\n"
        "A quiet architecture of care."
    )
    prompt = (
        "Compose a short social copy and an image direction for a sustainable water campaign. "
        "Tone: hopeful, cinematic."
    )
    brief = {
        'generated_at': time_label,
        'headline': f"Daily Rain Muse — {now.strftime('%b %d, %Y')}",
        'poem': poem,
        'creative_prompt': prompt,
        'artifact': {'kind': 'daily-creative-brief', 'title': 'Daily Rain Muse'}
    }
    return brief


import traceback

def handler(event, context):
    try:
        brief = make_brief()
        # Event-local override
        event_local = False
        try:
            if isinstance(event, dict):
                event_local = bool(event.get('local', False))
        except Exception:
            event_local = False

        do_local = LOCAL_WRITE or event_local

        if not do_local and not BUCKET:
            print('TARGET bucket not set (BUCKET_NAME/TARGET_BUCKET); failing')
            return {'statusCode': 500, 'error': 'TARGET bucket not set (BUCKET_NAME/TARGET_BUCKET)'}

        # If Bedrock is enabled and a model is configured, attempt to enrich the brief
        if USE_BEDROCK and bedrock_client and BEDROCK_MODEL:
            try:
                payload = {'input': brief['poem']}
                resp = bedrock_client.invoke_model(modelId=BEDROCK_MODEL, contentType='application/json', body=json.dumps(payload))
                # Response body may be a streaming body or bytes
                body_stream = resp.get('body')
                if body_stream:
                    try:
                        body_bytes = body_stream.read()
                        model_out = body_bytes.decode('utf-8')
                    except Exception:
                        model_out = str(body_stream)
                    # Attach model output for later use
                    brief['bedrock_output'] = model_out
            except Exception as e:
                print('Bedrock call failed:', e)

        body = json.dumps(brief)
        key = 'brief.json'

        if do_local:
            try:
                # Resolve frontend path relative to repo
                frontend_path = Path(__file__).resolve().parents[1] / 'frontend' / key
                frontend_path.parent.mkdir(parents=True, exist_ok=True)
                frontend_path.write_text(body, encoding='utf-8')
                print(f'Wrote brief to {frontend_path}')
                return {'statusCode': 200, 'body': body, 'location': str(frontend_path)}
            except Exception as e:
                print('Local write failed:', e)
                return {'statusCode': 500, 'error': str(e)}

        # Default: upload to S3
        if s3 is None:
            print('boto3/s3 client not available in runtime')
            return {'statusCode': 500, 'error': 'boto3 not available'}
        try:
            # Some S3 buckets have ACLs disabled at the account level; omit ACL when not needed
            s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType='application/json')
            print('Wrote brief to s3://%s/%s' % (BUCKET, key))
            return {
                'statusCode': 200,
                'body': body
            }
        except Exception as e:
            # Log the error and return structured failure so Lambda doesn't mark it as 'Unhandled'
            print('S3 upload failed:', e)
            traceback.print_exc()
            return {'statusCode': 500, 'error': str(e)}

    except Exception as e:
        # Catch-all to prevent unhandled exceptions; log full traceback for diagnostics
        print('Unhandled exception in handler:', e)
        traceback.print_exc()
        return {'statusCode': 500, 'error': str(e)}
