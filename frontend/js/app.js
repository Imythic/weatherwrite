async function loadBrief() {
  try {
    const res = await fetch(`brief.json?t=${Date.now()}`);
    if (!res.ok) throw new Error('No brief');
    const data = await res.json();
    document.getElementById('headline').textContent = data.headline;
    document.getElementById('poem').textContent = data.poem;
    document.getElementById('prompt').textContent = data.creative_prompt;
    document.getElementById('generated_at').textContent = `Generated: ${data.generated_at}`;

    const weatherEl = document.getElementById('weather');
    if (data.weather) {
      const w = data.weather;
      const temp = w.temperature_c != null ? `${w.temperature_c}°C, ` : '';
      weatherEl.textContent = `Weather: ${temp}${w.condition} in ${w.location}`;
    } else {
      weatherEl.textContent = '';
    }

    const img = document.getElementById('artwork');
    if (data.has_image) {
      img.src = `brief_image.png?t=${Date.now()}`;
      img.hidden = false;
    } else {
      img.hidden = true;
      img.removeAttribute('src');
    }
  } catch (e) {
    document.getElementById('headline').textContent = 'No brief available yet';
    document.getElementById('poem').textContent = '';
    document.getElementById('prompt').textContent = '';
  }
}

document.addEventListener('DOMContentLoaded', loadBrief);
