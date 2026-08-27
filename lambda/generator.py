import json
import os
import base64
import traceback
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

try:
    import boto3
except Exception:
    boto3 = None

# boto3 may be unavailable in local dev environments; create clients only when present
s3 = boto3.client('s3') if boto3 is not None else None
# Accept either BUCKET_NAME (preferred) or TARGET_BUCKET (legacy) for compatibility
BUCKET = os.environ.get('BUCKET_NAME') or os.environ.get('TARGET_BUCKET')

# Local write flag: set env LOCAL_WRITE=1 or pass event {'local': True}
LOCAL_WRITE = os.environ.get('LOCAL_WRITE', '0') == '1'

# Fixed location for the weather signal (defaults to Seattle, WA)
LOCATION_NAME = os.environ.get('LOCATION_NAME', 'Seattle, WA')
LATITUDE = os.environ.get('LATITUDE', '47.6062')
LONGITUDE = os.environ.get('LONGITUDE', '-122.3321')

# Optional Bedrock integration (invoke only when enabled)
USE_BEDROCK = os.environ.get('USE_BEDROCK', '0') == '1'
TEXT_MODEL = os.environ.get('BEDROCK_TEXT_MODEL', 'amazon.nova-lite-v1:0')
IMAGE_MODEL = os.environ.get('BEDROCK_IMAGE_MODEL', 'amazon.nova-canvas-v1:0')
bedrock_client = None
if USE_BEDROCK and boto3 is not None:
    try:
        bedrock_client = boto3.client('bedrock-runtime')
    except Exception:
        bedrock_client = None

WEATHER_CODES = {
    0: 'clear sky', 1: 'mostly clear', 2: 'partly cloudy', 3: 'overcast',
    45: 'fog', 48: 'depositing rime fog',
    51: 'light drizzle', 53: 'moderate drizzle', 55: 'dense drizzle',
    61: 'light rain', 63: 'moderate rain', 65: 'heavy rain',
    71: 'light snow', 73: 'moderate snow', 75: 'heavy snow',
    80: 'light rain showers', 81: 'moderate rain showers', 82: 'violent rain showers',
    95: 'thunderstorm', 96: 'thunderstorm with hail', 99: 'severe thunderstorm with hail',
}


def fetch_weather():
    url = (
        'https://api.open-meteo.com/v1/forecast'
        f'?latitude={LATITUDE}&longitude={LONGITUDE}&current_weather=true'
    )
    try:
        with urllib.request.urlopen(url, timeout=6) as resp:
            data = json.loads(resp.read().decode('utf-8'))
        current = data.get('current_weather', {})
        code = current.get('weathercode')
        return {
            'temperature_c': current.get('temperature'),
            'windspeed_kmh': current.get('windspeed'),
            'condition': WEATHER_CODES.get(code, 'unsettled weather'),
            'location': LOCATION_NAME,
            'source': 'open-meteo',
        }
    except Exception as e:
        print('Weather fetch failed:', e)
        return {
            'temperature_c': None,
            'windspeed_kmh': None,
            'condition': 'unsettled weather',
            'location': LOCATION_NAME,
            'source': 'unavailable',
        }


def template_poem(weather):
    poem = (
        "Clouds keep a ledger of small mercies;\n"
        "A rim of light reminds the rooftops to remember rain.\n"
        "Collect what falls, let the city drink slowly —\n"
        "A quiet architecture of care."
    )
    image_prompt = (
        f"A hopeful, cinematic watercolor scene of {weather['condition']} over "
        f"{weather['location']}, soft light on rooftops, water collection theme."
    )
    return poem, image_prompt


def call_bedrock_text(weather):
    temp_clause = (
        f", currently {weather['temperature_c']}°C"
        if weather.get('temperature_c') is not None else ''
    )
    prompt = (
        f"Write a short, original 4-line poem about {weather['condition']} weather "
        f"in {weather['location']}{temp_clause}. Tone: hopeful, cinematic. Then write "
        "one sentence describing matching artwork for the poem. "
        "Reply with strict JSON only, no prose, no markdown fences, in the form: "
        '{"poem": "...", "image_prompt": "..."}'
    )
    resp = bedrock_client.converse(
        modelId=TEXT_MODEL,
        messages=[{'role': 'user', 'content': [{'text': prompt}]}],
        inferenceConfig={'maxTokens': 300, 'temperature': 0.8},
    )
    text = resp['output']['message']['content'][0]['text'].strip()

    # Models sometimes wrap JSON in prose or code fences; extract the first {...} block.
    start = text.find('{')
    end = text.rfind('}')
    if start == -1 or end == -1 or end < start:
        raise ValueError(f'No JSON object found in model output: {text[:200]!r}')
    parsed = json.loads(text[start:end + 1])
    poem = parsed['poem']
    image_prompt = parsed['image_prompt']
    return poem, image_prompt


def call_bedrock_image(image_prompt):
    body = {
        'taskType': 'TEXT_IMAGE',
        'textToImageParams': {'text': image_prompt[:1024]},
        'imageGenerationConfig': {
            'numberOfImages': 1,
            'height': 512,
            'width': 512,
            'cfgScale': 8.0,
            'seed': 0,
        },
    }
    resp = bedrock_client.invoke_model(
        modelId=IMAGE_MODEL,
        contentType='application/json',
        accept='application/json',
        body=json.dumps(body),
    )
    payload = json.loads(resp['body'].read())
    images = payload.get('images')
    if not images:
        raise ValueError(f'No images in Bedrock response: {payload}')
    return base64.b64decode(images[0])


def make_brief():
    weather = fetch_weather()
    now = datetime.utcnow()
    time_label = now.strftime('%Y-%m-%dT%H:%M:%SZ')

    poem = None
    image_prompt = None
    image_bytes = None
    text_source = 'template'
    image_source = None

    if USE_BEDROCK and bedrock_client:
        try:
            poem, image_prompt = call_bedrock_text(weather)
            text_source = 'bedrock:' + TEXT_MODEL
        except Exception as e:
            print('Bedrock text generation failed, falling back to template:', e)
            traceback.print_exc()

    if poem is None:
        poem, image_prompt = template_poem(weather)

    if USE_BEDROCK and bedrock_client:
        try:
            image_bytes = call_bedrock_image(image_prompt)
            image_source = 'bedrock:' + IMAGE_MODEL
        except Exception as e:
            print('Bedrock image generation failed, continuing without artwork:', e)
            traceback.print_exc()

    brief = {
        'generated_at': time_label,
        'headline': f"Daily Rain Muse — {weather['condition'].title()} in {weather['location']}",
        'weather': weather,
        'poem': poem,
        'creative_prompt': image_prompt,
        'text_source': text_source,
        'image_source': image_source,
        'has_image': image_bytes is not None,
        'artifact': {'kind': 'daily-creative-brief', 'title': 'Daily Rain Muse'},
    }
    return brief, image_bytes


def handler(event, context):
    try:
        brief, image_bytes = make_brief()

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

        body = json.dumps(brief)
        key = 'brief.json'
        image_key = 'brief_image.png'

        if do_local:
            try:
                frontend_dir = Path(__file__).resolve().parents[1] / 'frontend'
                frontend_dir.mkdir(parents=True, exist_ok=True)
                brief_path = frontend_dir / key
                brief_path.write_text(body, encoding='utf-8')
                print(f'Wrote brief to {brief_path}')
                image_path = None
                if image_bytes is not None:
                    image_path = frontend_dir / image_key
                    image_path.write_bytes(image_bytes)
                    print(f'Wrote image to {image_path}')
                return {
                    'statusCode': 200,
                    'body': body,
                    'location': str(brief_path),
                    'image_location': str(image_path) if image_path else None,
                }
            except Exception as e:
                print('Local write failed:', e)
                return {'statusCode': 500, 'error': str(e)}

        # Default: upload to S3
        if s3 is None:
            print('boto3/s3 client not available in runtime')
            return {'statusCode': 500, 'error': 'boto3 not available'}
        try:
            s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType='application/json')
            print('Wrote brief to s3://%s/%s' % (BUCKET, key))
            if image_bytes is not None:
                s3.put_object(Bucket=BUCKET, Key=image_key, Body=image_bytes, ContentType='image/png')
                print('Wrote image to s3://%s/%s' % (BUCKET, image_key))
            return {'statusCode': 200, 'body': body}
        except Exception as e:
            print('S3 upload failed:', e)
            traceback.print_exc()
            return {'statusCode': 500, 'error': str(e)}

    except Exception as e:
        print('Unhandled exception in handler:', e)
        traceback.print_exc()
        return {'statusCode': 500, 'error': str(e)}
