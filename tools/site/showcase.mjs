// Drawn app screens for the landing page: the Quick view on a phone, the DJ layout on a Mac and
// the visualizer on a second screen. They follow the app's layout and use the same design tokens
// (CSS classes in public/assets/site.css map to tokens.css), so they change when the design does.
// Deterministic: every "random" value comes from a fixed function of its index.

const f = (n) => Number(n.toFixed(1));

/** A track's three-band waveform envelope at bin i (0…1 each), reproducible. */
function bands(i, seed) {
  const beat = Math.abs(Math.sin((i + seed * 7) * 0.39));       // kick every ~8 bins
  const phrase = 0.75 + 0.25 * Math.sin((i + seed * 31) * 0.021);
  const low = Math.pow(beat, 6) * 0.9 * phrase + 0.08;
  const mid = (0.35 + 0.3 * Math.abs(Math.sin((i + seed) * 0.13)) * Math.abs(Math.cos((i + seed) * 0.05))) * phrase;
  const high = 0.15 + 0.25 * Math.abs(Math.sin((i * 1.7 + seed) * 0.9)) * phrase;
  return { low, mid, high };
}

/** Mirrored three-band waveform: low (widest) under mid under high, centred on y. */
function waveform(x, y, w, h, seed, { bin = 3, scroll = false } = {}) {
  const n = Math.floor(w / bin) * (scroll ? 2 : 1);
  const layers = { low: "", mid: "", high: "" };
  for (let i = 0; i < n; i++) {
    const b = bands(i, seed);
    const bx = f(x + i * bin);
    for (const k of ["low", "mid", "high"]) {
      const a = (b[k] * h) / 2;
      layers[k] += `<rect x="${bx}" y="${f(y - a)}" width="${bin - 0.8}" height="${f(a * 2)}"/>`;
    }
  }
  const body = `<g class="sc-wave-low">${layers.low}</g><g class="sc-wave-mid">${layers.mid}</g><g class="sc-wave-high">${layers.high}</g>`;
  if (!scroll) return body;
  const id = `clip-${seed}-${Math.round(x)}-${Math.round(y)}`;
  return `<clipPath id="${id}"><rect x="${x}" y="${y - h / 2}" width="${w}" height="${h}"/></clipPath>
<g clip-path="url(#${id})"><g class="sc-scroll">${body}</g></g>`;
}

function knob(cx, cy, r, value, label) {
  // 270° arc from 135° to 405°; value −1…1 fills from the top centre.
  const toXY = (deg) => [f(cx + r * Math.cos((deg * Math.PI) / 180)), f(cy + r * Math.sin((deg * Math.PI) / 180))];
  const arc = (a0, a1) => {
    const [x0, y0] = toXY(a0), [x1, y1] = toXY(a1);
    return `M${x0},${y0} A${r},${r} 0 ${Math.abs(a1 - a0) > 180 ? 1 : 0} ${a1 > a0 ? 1 : 0} ${x1},${y1}`;
  };
  const end = 270 + value * 135;
  return `<path class="sc-track" d="${arc(135, 405)}" stroke-width="${f(r * 0.18)}"/>
<path class="sc-arc" d="${arc(270, end === 270 ? 270.1 : end)}" stroke-width="${f(r * 0.18)}"/>
<text class="sc-label" x="${cx}" y="${f(cy + r + 14)}" text-anchor="middle">${label}</text>`;
}

function platter(cx, cy, r, letter, cls) {
  let grooves = "";
  for (let rr = r * 0.95; rr > r * 0.42; rr -= Math.max(2.5, r * 0.04)) grooves += `<circle cx="${cx}" cy="${cy}" r="${f(rr)}"/>`;
  return `<circle class="sc-surface2" cx="${cx}" cy="${cy}" r="${f(r * 1.08)}"/>
<g class="sc-spin ${cls}">
  <circle class="sc-bg" cx="${cx}" cy="${cy}" r="${r}"/>
  <g class="sc-grooves">${grooves}</g>
  <circle class="sc-surface3" cx="${cx}" cy="${cy}" r="${f(r * 0.36)}"/>
  <line class="sc-marker ${letter === "A" ? "sc-marker-a" : ""}" x1="${cx}" y1="${f(cy - r * 0.35)}" x2="${cx}" y2="${f(cy - r * 0.93)}" stroke-width="${f(Math.max(2, r * 0.03))}"/>
</g>
<text class="sc-deckletter ${letter === "A" ? "sc-text" : "sc-primary-text"}" x="${cx}" y="${f(cy + 6)}" text-anchor="middle">${letter}</text>`;
}

function pitchFader(x, y, h, value) {
  const ky = f(y + h / 2 + value * (h / 2 - 10));
  return `<rect class="sc-surface3" x="${x - 2}" y="${y}" width="4" height="${h}" rx="2"/>
<line class="sc-tick" x1="${x - 8}" x2="${x + 8}" y1="${y + h / 2}" y2="${y + h / 2}"/>
<rect class="${value === 0 ? "sc-surface2 sc-stroke" : "sc-primary"}" x="${x - 15}" y="${ky - 8}" width="30" height="16" rx="3"/>`;
}

function pads(x, y, w, colors) {
  const pw = (w - 3 * 6) / 4, ph = 26;
  let s = "";
  for (let i = 0; i < 8; i++) {
    const px = f(x + (i % 4) * (pw + 6)), py = f(y + Math.floor(i / 4) * (ph + 6));
    const on = colors[i];
    s += `<rect class="${on ? `sc-cue-${on}` : "sc-surface sc-stroke"}" x="${px}" y="${py}" width="${f(pw)}" height="${ph}" rx="4"/>`;
  }
  return s;
}

/** The Quick view, portrait phone: one deck, one big Mix button. */
export function phoneQuick() {
  const W = 390, H = 844;
  return `<svg class="sc-screen" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="sc-phone-title">
<title id="sc-phone-title">Soundboard Quick view on iPhone: deck A playing Night Drive at 124 BPM, Glasshouse up next, and the Mix button</title>
<rect class="sc-bg" width="${W}" height="${H}"/>
<text class="sc-chip" x="20" y="74">Friday set ⌄</text>
<circle class="sc-surface" cx="358" cy="68" r="14"/><path class="sc-icon" d="M351,64h14M351,72h14"/>
<text class="sc-meta" x="20" y="98">Master USB-C · cue headphones</text>
<rect class="sc-surface" x="20" y="116" width="350" height="16" rx="3"/>
<rect class="sc-primary-dim" x="20" y="116" width="128" height="16" rx="3"/>
<rect class="sc-surface" x="20" y="146" width="350" height="230" rx="10"/>
${waveform(20, 261, 350, 190, 1, { bin: 4, scroll: true })}
<line class="sc-playhead" x1="195" x2="195" y1="150" y2="372"/>
<text class="sc-title" x="20" y="418">Night Drive</text>
<text class="sc-sub" x="20" y="442">Oona Vale</text>
<text class="sc-bpm" x="370" y="420" text-anchor="end">124.00</text>
<text class="sc-meta" x="370" y="442" text-anchor="end">8A · −3:12</text>
<rect class="sc-surface" x="20" y="470" width="350" height="66" rx="10"/>
<text class="sc-meta" x="36" y="494">Up next · plays well</text>
<text class="sc-row" x="36" y="520">Glasshouse</text>
<text class="sc-meta-strong" x="354" y="520" text-anchor="end">125.00 · 9A</text>
<rect class="sc-primary" x="20" y="556" width="350" height="76" rx="12"/>
<text class="sc-cta" x="40" y="602">Mix into Glasshouse</text>
<text class="sc-cta-meta" x="350" y="601" text-anchor="end">BASS SWAP · 16</text>
${knob(64, 690, 22, 0, "TRIM")}${knob(150, 690, 22, 0.35, "HIGH")}${knob(236, 690, 22, 0, "MID")}${knob(322, 690, 22, -0.6, "LOW")}
<rect class="sc-surface sc-stroke" x="20" y="760" width="56" height="44" rx="8"/><path class="sc-icon-fill" d="M42,772v20l8-10z M52,772v20"/>
<rect class="sc-surface sc-stroke" x="84" y="760" width="56" height="44" rx="8"/><circle class="sc-icon" cx="112" cy="782" r="9"/>
<rect class="sc-surface" x="156" y="776" width="214" height="12" rx="3"/><rect class="sc-primary" x="156" y="776" width="150" height="12" rx="3"/>
</svg>`;
}

/** The DJ layout, Mac window: two platters, pitch faders, pads, crossfader. */
export function macDJ() {
  const W = 1440, H = 900;
  return `<svg class="sc-screen" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="sc-mac-title">
<title id="sc-mac-title">Soundboard DJ layout on a Mac: two jog wheels with pitch faders, waveforms, hot cue pads and the crossfader</title>
<rect class="sc-bg" width="${W}" height="${H}"/>
<circle class="sc-surface3" cx="26" cy="24" r="6"/><circle class="sc-surface3" cx="46" cy="24" r="6"/><circle class="sc-surface3" cx="66" cy="24" r="6"/>
<rect class="sc-surface sc-stroke" x="260" y="44" width="120" height="34" rx="6"/>
<text class="sc-seg" x="290" y="66" text-anchor="middle">MIX</text>
<rect class="sc-primary" x="322" y="48" width="54" height="26" rx="4"/><text class="sc-seg-on" x="349" y="66" text-anchor="middle">DJ</text>
<text class="sc-meta" x="400" y="66">Master Pioneer DDJ · cue on channels 3–4</text>
<text class="sc-chip" x="1180" y="66" text-anchor="end">Friday set ⌄</text>
${deckColumn(24, "A", "Night Drive", "Oona Vale", "124.00", "8A · +0.8%")}
${deckColumn(1236, "B", "Glasshouse", "Pelle Ark", "124.00", "9A · −0.8%", true)}
<rect class="sc-surface" x="260" y="96" width="920" height="16" rx="3"/><rect class="sc-primary-dim" x="260" y="96" width="402" height="16" rx="3"/>
<rect class="sc-surface" x="260" y="118" width="920" height="16" rx="3"/><rect class="sc-primary-dim" x="260" y="118" width="88" height="16" rx="3"/>
<rect class="sc-surface" x="260" y="146" width="920" height="70" rx="8"/>
${waveform(260, 181, 920, 64, 1, { bin: 4, scroll: true })}
<rect class="sc-surface" x="260" y="222" width="920" height="70" rx="8"/>
${waveform(260, 257, 920, 64, 5, { bin: 4, scroll: true })}
<line class="sc-playhead" x1="720" x2="720" y1="146" y2="292"/>
${pitchFader(300, 330, 260, -0.1)}
${platter(480, 460, 140, "A", "")}
${platter(960, 460, 140, "B", "sc-spin-b")}
${pitchFader(1140, 330, 260, 0.1)}
<rect class="sc-surface" x="676" y="440" width="88" height="40" rx="6"/>
<rect class="sc-primary" x="716" y="446" width="10" height="28" rx="2"/>
<text class="sc-meta" x="720" y="500" text-anchor="middle">IN PHASE</text>
${pads(260, 640, 330, ["1", "2", 0, "3", 0, 0, "4", 0])}
${pads(850, 640, 330, ["2", 0, "1", 0, 0, "3", 0, 0])}
<rect class="sc-surface" x="620" y="650" width="200" height="10" rx="3"/>
<rect class="sc-text-fill" x="704" y="642" width="14" height="26" rx="3"/>
<text class="sc-label" x="620" y="684">A</text><text class="sc-label" x="820" y="684" text-anchor="end">B</text>
<rect class="sc-primary" x="620" y="700" width="200" height="54" rx="10"/>
<text class="sc-cta-s" x="636" y="733">Mix into Glasshouse</text>
${knob(320, 800, 20, 0, "TRIM")}${knob(390, 800, 20, 0.3, "HIGH")}${knob(460, 800, 20, 0, "MID")}${knob(530, 800, 20, -0.7, "LOW")}
${knob(910, 800, 20, 0, "TRIM")}${knob(980, 800, 20, 0, "HIGH")}${knob(1050, 800, 20, 0.2, "MID")}${knob(1120, 800, 20, 0.1, "LOW")}
</svg>`;
}

function deckColumn(x, letter, title, artist, bpm, meta, right = false) {
  const ax = right ? x + 180 : x;
  const anchor = right ? "end" : "start";
  return `<text class="sc-meta" x="${ax}" y="118" text-anchor="${anchor}">DECK ${letter}</text>
<text class="sc-row" x="${ax}" y="148" text-anchor="${anchor}">${title}</text>
<text class="sc-sub" x="${ax}" y="170" text-anchor="${anchor}">${artist}</text>
<text class="sc-bpm-s" x="${ax}" y="214" text-anchor="${anchor}">${bpm}</text>
<text class="sc-meta" x="${ax}" y="236" text-anchor="${anchor}">${meta}</text>
<rect class="sc-surface sc-stroke" x="${x}" y="760" width="86" height="44" rx="8"/>
<rect class="${letter === "A" ? "sc-primary" : "sc-surface sc-stroke"}" x="${x + 94}" y="760" width="86" height="44" rx="8"/>
<rect class="sc-surface sc-stroke" x="${x}" y="812" width="180" height="44" rx="8"/>`;
}

/** The visualizer on a second screen (TV or projector), spectrum style with track info. */
export function tvVisualizer() {
  const W = 1280, H = 720;
  let bars = "";
  const n = 32, gap = 6, bw = (W - 160 - gap * (n - 1)) / n;
  for (let i = 0; i < n; i++) {
    const v = 0.2 + 0.75 * Math.pow(Math.abs(Math.sin(i * 0.37 + 0.6)) * (1 - i / (n * 1.6)), 0.9);
    const h = v * 300, x = f(80 + i * (bw + gap));
    const cls = i < 11 ? "sc-wave-low" : i < 22 ? "sc-wave-mid" : "sc-wave-high";
    bars += `<g class="${cls}"><rect class="sc-bar" x="${x}" y="${f(400 - h)}" width="${f(bw)}" height="${f(h)}" rx="4"/>
<rect opacity="0.22" x="${x}" y="400" width="${f(bw)}" height="${f(h * 0.45)}" rx="4"/></g>`;
  }
  return `<svg class="sc-screen sc-dark" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="sc-tv-title">
<title id="sc-tv-title">The visualizer on a second screen: a spectrum of the master output with the track title and tempo</title>
<rect class="sc-void" width="${W}" height="${H}"/>
${bars}
<text class="sc-tv-title" x="80" y="620">Glasshouse</text>
<text class="sc-tv-sub" x="80" y="660">Pelle Ark · 124 BPM</text>
</svg>`;
}
