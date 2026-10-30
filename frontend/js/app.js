const WEATHER_MAP = [
  { test: /thunder|storm/i, cls: 'weather-storm', icon: '⛈️' },
  { test: /snow|sleet|flurr/i, cls: 'weather-snow', icon: '🌨️' },
  { test: /fog|mist|haze/i, cls: 'weather-fog', icon: '🌫️' },
  { test: /rain|drizzle|shower/i, cls: 'weather-rain', icon: '🌧️' },
  { test: /overcast|cloud/i, cls: 'weather-clouds', icon: '⛅' },
  { test: /clear|sun/i, cls: 'weather-clear', icon: '☀️' },
];

function classifyCondition(condition) {
  if (!condition) return WEATHER_MAP[4];
  return WEATHER_MAP.find((w) => w.test.test(condition)) || WEATHER_MAP[4];
}

function isNightNow() {
  const h = new Date().getHours();
  return h < 6 || h >= 19;
}

function formatGeneratedAt(iso) {
  if (!iso) return '';
  try {
    const d = new Date(iso);
    return d.toLocaleString(undefined, {
      month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
    });
  } catch {
    return iso;
  }
}

async function loadBrief() {
  const body = document.body;
  try {
    const res = await fetch(`brief.json?t=${Date.now()}`);
    if (!res.ok) throw new Error('No brief');
    const data = await res.json();

    document.getElementById('headline').textContent = data.headline;
    document.getElementById('poem').textContent = data.poem || '';
    document.getElementById('prompt').textContent = data.creative_prompt
      ? `Art direction — ${data.creative_prompt}`
      : '';

    const w = data.weather || {};
    const match = classifyCondition(w.condition);
    body.classList.remove(...WEATHER_MAP.map((m) => m.cls));
    body.classList.add(match.cls);
    body.classList.toggle('is-night', isNightNow() && match.cls !== 'weather-clear');

    document.getElementById('weatherIcon').textContent = match.icon;
    document.getElementById('weatherTemp').textContent =
      w.temperature_c != null ? `${Math.round(w.temperature_c)}°C` : '—';
    document.getElementById('weatherCond').textContent = w.condition || 'Unknown';
    document.getElementById('weatherLocation').textContent = w.location || '';

    const img = document.getElementById('artwork');
    const fallback = document.getElementById('artworkFallback');
    if (data.has_image) {
      img.onerror = () => { img.hidden = true; fallback.hidden = false; };
      img.src = `brief_image.png?t=${Date.now()}`;
      img.hidden = false;
      fallback.hidden = true;
    } else {
      img.hidden = true;
      img.removeAttribute('src');
      fallback.hidden = false;
    }

    const sourceLabel = w.source ? `Weather via ${w.source}` : '';
    document.getElementById('metaSource').textContent = sourceLabel;
    document.getElementById('metaSource').hidden = !sourceLabel;
    document.getElementById('metaGenerated').textContent = `Generated ${formatGeneratedAt(data.generated_at)}`;
  } catch (e) {
    document.getElementById('headline').textContent = 'No brief available yet';
    document.getElementById('poem').textContent = 'Check back soon — the next muse is on its way.';
    document.getElementById('prompt').textContent = '';
    document.getElementById('artworkFallback').hidden = false;
  }
}

document.addEventListener('DOMContentLoaded', loadBrief);
