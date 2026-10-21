// Procedural canvases for the room: wood, plaster, the record, the stained-glass shade,
// the transport button faces and the song label. Ported from the Mac app's renderers.

function canvas(w, h = w) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return [c, c.getContext("2d")];
}

class ValueNoise {
  constructor(seed) {
    let s = seed * 747796405 + 2891336453;
    const next = () => ((s = (s * 1103515245 + 12345) >>> 0) / 4294967296);
    this.table = Array.from({ length: 256 }, next);
    const p = Array.from({ length: 256 }, (_, i) => i);
    for (let i = 255; i > 0; i--) {
      const j = Math.floor(next() * (i + 1));
      [p[i], p[j]] = [p[j], p[i]];
    }
    this.perm = [...p, ...p];
  }
  value(x, y) {
    const xi = Math.floor(x), yi = Math.floor(y);
    const xf = x - xi, yf = y - yi;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const h = (i, j) => this.table[this.perm[(this.perm[i & 255] + j) & 511] & 255];
    const a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1);
    const top = a + (b - a) * u, bottom = c + (d - c) * u;
    return top + (bottom - top) * v;
  }
  fbm(x, y, octaves) {
    let sum = 0, amp = 0.5, freq = 1, norm = 0;
    for (let i = 0; i < octaves; i++) {
      sum += this.value(x * freq, y * freq) * amp;
      norm += amp;
      amp *= 0.5;
      freq *= 2;
    }
    return sum / norm;
  }
}

function pixels(size, fn) {
  const [c, ctx] = canvas(size);
  const img = ctx.createImageData(size, size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const [r, g, b] = fn(x, y);
      const i = (y * size + x) * 4;
      img.data[i] = r * 255;
      img.data[i + 1] = g * 255;
      img.data[i + 2] = b * 255;
      img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return c;
}

/** Long grain along x with warped rings and fine pores. */
export function wood(size, dark, light, rings, seed) {
  const n = new ValueNoise(seed);
  return pixels(size, (x, y) => {
    const warp = n.fbm(x * 0.004, y * 0.03, 4) * 30;
    const ring = 0.5 + 0.5 * Math.sin((y + warp) * rings);
    const streak = n.fbm(x * 0.002, y * 0.25, 3);
    const pores = n.value(x * 0.6, y * 3) * 0.12;
    const t = Math.min(Math.max(ring * 0.55 + streak * 0.45 - pores, 0), 1);
    return dark.map((d, i) => d + (light[i] - d) * t);
  });
}

export function plaster(size, base, amount, scale, seed) {
  const n = new ValueNoise(seed);
  return pixels(size, (x, y) => {
    const v = (n.fbm(x * scale, y * scale, 4) - 0.5) * 2 * amount + (n.value(x * 0.9, y * 0.9) - 0.5) * amount * 0.5;
    return base.map((c) => c + v);
  });
}

// --- Record ---------------------------------------------------------------

export const LABEL_RATIO = 0.36;
export const INNER_GROOVE = LABEL_RATIO * 1.12;
export const OUTER_GROOVE = 0.965;

/** The whole record in one square canvas (vinyl, grooves, label, spindle). */
export function record(size, artwork) {
  const [c, ctx] = canvas(size);
  const r = size / 2;
  const labelR = r * LABEL_RATIO;
  const gray = (w) => `rgb(${w * 255},${w * 255},${w * 255})`;
  const circle = (radius) => { ctx.beginPath(); ctx.arc(r, r, radius, 0, Math.PI * 2); };

  ctx.fillStyle = gray(0.055);
  circle(r); ctx.fill();

  // Grooves: faint rings with slightly varying brightness (deterministic).
  let seed = 7;
  const rand = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296);
  const step = Math.max(0.9, r / 220);
  ctx.lineWidth = step * 0.45;
  for (let g = r * OUTER_GROOVE; g > r * INNER_GROOVE; g -= step * (0.8 + 0.4 * rand())) {
    ctx.strokeStyle = gray(0.085 + 0.06 * rand());
    circle(g); ctx.stroke();
  }
  ctx.strokeStyle = gray(0.035);
  ctx.lineWidth = Math.max(1.2, r * 0.008);
  for (const f of [0.84, 0.73, 0.63, 0.52]) { circle(r * f); ctx.stroke(); }

  ctx.fillStyle = gray(0.06);
  ctx.beginPath();
  ctx.arc(r, r, r * INNER_GROOVE, 0, Math.PI * 2);
  ctx.arc(r, r, labelR, 0, Math.PI * 2, true);
  ctx.fill();

  ctx.strokeStyle = gray(0.22);
  ctx.lineWidth = 0.75;
  circle(r - 0.5); ctx.stroke();

  // Label: the album art, warmed slightly to sit in the room's light.
  ctx.save();
  circle(labelR); ctx.clip();
  if (artwork) {
    ctx.drawImage(artwork, r - labelR, r - labelR, labelR * 2, labelR * 2);
  } else {
    const g = ctx.createRadialGradient(r, r, 0, r, r, labelR);
    g.addColorStop(0, "rgb(184,41,31)");
    g.addColorStop(1, "rgb(115,18,15)");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, size, size);
  }
  ctx.globalCompositeOperation = "multiply";
  ctx.fillStyle = "rgb(255,219,184)";
  ctx.fillRect(0, 0, size, size);
  ctx.restore();

  ctx.strokeStyle = "rgba(0,0,0,0.45)";
  ctx.lineWidth = 1;
  circle(labelR); ctx.stroke();

  ctx.fillStyle = gray(0.78);
  circle(r * 0.022); ctx.fill();
  return c;
}

// --- Tiffany shade --------------------------------------------------------

/** Laid out crown (top of canvas) to rim (bottom), 16 columns around. */
export function stainedGlass() {
  const W = 1024, H = 512, columns = 16, col = W / columns;
  const [c, ctx] = canvas(W, H);
  const lead = "rgb(18,15,13)";
  const glass = ([r, g, b], f) => {
    const m = 0.94 + Math.random() * 0.08 + f * 0.06;
    return `rgb(${Math.min(r * m, 1) * 255},${Math.min(g * m, 1) * 255},${Math.min(b * m, 1) * 255})`;
  };
  const paleBlue = [0.8, 0.91, 0.94], lavender = [0.72, 0.67, 0.88], cream = [0.97, 0.9, 0.68];
  const yellow = [0.98, 0.8, 0.28], red = [0.82, 0.1, 0.1];

  const band = (f0, f1, color) => {
    for (let i = 0; i < columns; i++) {
      ctx.fillStyle = glass(color, f1);
      ctx.fillRect(i * col, f0 * H, col, (f1 - f0) * H);
    }
  };
  const hLead = (f, w = 4) => { ctx.fillStyle = lead; ctx.fillRect(0, f * H - w / 2, W, w); };
  const vLeads = (f0, f1, offset = 0) => {
    ctx.fillStyle = lead;
    for (let i = 0; i <= columns; i++) ctx.fillRect((i + offset) * col - 1.5, f0 * H, 3, (f1 - f0) * H);
  };
  const outline = (w) => { ctx.strokeStyle = lead; ctx.lineWidth = w; ctx.stroke(); };

  ctx.fillStyle = lead;
  ctx.fillRect(0, 0, W, 0.06 * H);
  band(0.06, 0.31, paleBlue); vLeads(0.06, 0.31);
  band(0.31, 0.56, paleBlue); vLeads(0.31, 0.56, 0.5);
  hLead(0.06); hLead(0.31);

  band(0.56, 0.66, cream);
  for (let i = 0; i < columns; i++) {
    const x = i * col;
    ctx.beginPath();
    ctx.moveTo(x, 0.56 * H);
    ctx.quadraticCurveTo(x + col / 2, 0.68 * H, x + col, 0.56 * H);
    ctx.closePath();
    ctx.fillStyle = glass(lavender, 0.6);
    ctx.fill();
    outline(3);
  }
  hLead(0.56);

  band(0.66, 0.77, cream); vLeads(0.66, 0.77);
  for (let i = 0; i < columns; i++) {
    const cx = (i + 0.5) * col, cy = 0.715 * H, r = 0.035 * H;
    ctx.beginPath();
    ctx.moveTo(cx, cy - r); ctx.lineTo(cx + r * 0.8, cy); ctx.lineTo(cx, cy + r); ctx.lineTo(cx - r * 0.8, cy);
    ctx.closePath();
    ctx.fillStyle = glass(yellow, 0.7);
    ctx.fill();
    outline(2.5);
  }
  hLead(0.66); hLead(0.77);

  ctx.fillStyle = "rgb(66,51,31)";
  ctx.fillRect(0, 0.77 * H, W, 0.09 * H);
  for (let i = 0; i < columns * 2; i++) {
    ctx.fillStyle = glass([cream[0] * 0.8, cream[1] * 0.75, cream[2] * 0.6], 0.8);
    ctx.fillRect(i * col / 2 + col * 0.08, 0.79 * H, col * 0.34, 0.05 * H);
  }
  for (let i = 0; i < columns; i += 2) {
    ctx.beginPath();
    ctx.arc((i + 1) * col, 0.815 * H, 0.03 * H, 0, Math.PI * 2);
    ctx.fillStyle = glass(red, 0.8);
    ctx.fill();
    outline(2);
  }
  hLead(0.86);

  for (let i = 0; i < columns * 2; i++) {
    const x = i * col / 2;
    const tri = (pts, color) => {
      ctx.beginPath();
      pts.forEach(([px, py], k) => (k ? ctx.lineTo(px, py) : ctx.moveTo(px, py)));
      ctx.closePath();
      ctx.fillStyle = glass(color, 1);
      ctx.fill();
      outline(2.5);
    };
    tri([[x - col / 4, 0.86 * H], [x, H], [x + col / 4, 0.86 * H]], cream);
    tri([[x, H], [x + col / 4, 0.86 * H], [x + col / 2, H]], paleBlue);
  }
  hLead(0.995, 6);
  return c;
}

// --- Turntable front ------------------------------------------------------

/** Face of a transport button: satin cap with a dark symbol. */
export function buttonFace(kind, pressed = false) {
  const size = 128;
  const [c, ctx] = canvas(size);
  const g = ctx.createRadialGradient(size * 0.4, size * 0.35, 4, size / 2, size / 2, size / 2);
  g.addColorStop(0, pressed ? "#a9a49a" : "#e6e1d6");
  g.addColorStop(1, pressed ? "#7f7a71" : "#b9b3a7");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, size, size);

  ctx.fillStyle = "rgba(38,34,30,0.9)";
  const cx = size / 2, cy = size / 2, s = size * 0.2;
  const triangle = (x, dir) => {
    ctx.beginPath();
    ctx.moveTo(x, cy - s * 0.8);
    ctx.lineTo(x + dir * s * 1.1, cy);
    ctx.lineTo(x, cy + s * 0.8);
    ctx.closePath();
    ctx.fill();
  };
  if (kind === "previous") { triangle(cx + s * 0.05, -1); triangle(cx + s * 1.1, -1); }
  if (kind === "next") { triangle(cx - s * 1.1, 1); triangle(cx - s * 0.05, 1); }
  if (kind === "play") triangle(cx - s * 0.45, 1);
  if (kind === "pause") {
    ctx.fillRect(cx - s * 0.7, cy - s * 0.8, s * 0.5, s * 1.6);
    ctx.fillRect(cx + s * 0.2, cy - s * 0.8, s * 0.5, s * 1.6);
  }
  return c;
}

/** Song title and artist, right-aligned, printed in cream on the wood. */
export function trackLabel(target, title, artist) {
  const ctx = target.getContext("2d");
  const { width: w, height: h } = target;
  ctx.clearRect(0, 0, w, h);
  if (!title) return;
  const fit = (text, font) => {
    ctx.font = font;
    if (ctx.measureText(text).width <= w - 4) return text;
    let t = text;
    while (t.length > 1 && ctx.measureText(t + "…").width > w - 4) t = t.slice(0, -1);
    return t.trimEnd() + "…";
  };
  ctx.textAlign = "right";
  ctx.textBaseline = "alphabetic";
  ctx.shadowColor = "rgba(0,0,0,0.5)";
  ctx.shadowBlur = 1;
  ctx.shadowOffsetY = 1;
  const titleFont = `600 ${Math.round(h * 0.36)}px -apple-system, "Helvetica Neue", Arial, sans-serif`;
  const artistFont = `400 ${Math.round(h * 0.31)}px -apple-system, "Helvetica Neue", Arial, sans-serif`;
  ctx.fillStyle = "rgba(237,219,189,0.92)";
  ctx.fillText(fit(title, titleFont), w - 2, h * 0.44);
  ctx.fillStyle = "rgba(237,219,189,0.7)";
  ctx.fillText(fit(artist, artistFont), w - 2, h * 0.9);
}
