async function loadBrief() {
  try {
    const res = await fetch('brief.json');
    if (!res.ok) throw new Error('No brief');
    const data = await res.json();
    document.getElementById('headline').textContent = data.headline;
    document.getElementById('poem').textContent = data.poem;
    document.getElementById('prompt').textContent = data.creative_prompt;
    document.getElementById('generated_at').textContent = `Generated: ${data.generated_at}`;
  } catch (e) {
    document.getElementById('headline').textContent = 'No brief available yet';
    document.getElementById('poem').textContent = '';
    document.getElementById('prompt').textContent = '';
  }
}

document.addEventListener('DOMContentLoaded', loadBrief);
