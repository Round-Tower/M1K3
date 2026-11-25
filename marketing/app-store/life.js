// M1K3 — Conway's Game of Life for the store frames' backgrounds.
// The same field the app draws behind Settings (M1K3ScreensaverCore/LifeField.swift):
// B3/S23 on a torus, SplitMix64-seeded, cells carry an age (newborns glow
// brightest), and a stale field (dark, still, or period-2) reseeds a small patch.
// Deterministic per seed, so a frame renders the same field every run.

const MAX_AGE = 60;
const STALE = 24;

function splitmix(seed) {
  let s = BigInt.asUintN(64, BigInt(seed === 0 ? 0x9e3779b97f4a7c15n : seed));
  return () => {
    s = BigInt.asUintN(64, s + 0x9e3779b97f4a7c15n);
    let z = s;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94d049bb133111ebn);
    z ^= z >> 31n;
    return Number(z >> 11n) / 2 ** 53;
  };
}

class LifeField {
  constructor(cols, rows, density, seed) {
    this.cols = Math.max(1, cols);
    this.rows = Math.max(1, rows);
    this.rand = splitmix(seed);
    this.ages = new Uint8Array(this.cols * this.rows);
    for (let i = 0; i < this.ages.length; i++) if (this.rand() < density) this.ages[i] = 1;
    this.recent = [];
    this.stale = 0;
  }
  idx(c, r) {
    const cc = ((c % this.cols) + this.cols) % this.cols;
    const rr = ((r % this.rows) + this.rows) % this.rows;
    return rr * this.cols + cc;
  }
  step() {
    const next = new Uint8Array(this.ages.length);
    for (let r = 0; r < this.rows; r++)
      for (let c = 0; c < this.cols; c++) {
        let n = 0;
        for (let dr = -1; dr <= 1; dr++)
          for (let dc = -1; dc <= 1; dc++) if ((dr || dc) && this.ages[this.idx(c + dc, r + dr)]) n++;
        const i = r * this.cols + c;
        const a = this.ages[i];
        next[i] = a ? (n === 2 || n === 3 ? Math.min(a + 1, MAX_AGE) : 0) : n === 3 ? 1 : 0;
      }
    this.ages = next;
  }
  signature() {
    let h = 0;
    for (let i = 0; i < this.ages.length; i++) if (this.ages[i]) h = (Math.imul(h, 31) + i) | 0;
    return h;
  }
  advance() {
    this.step();
    const sig = this.signature();
    const pop = this.ages.reduce((n, a) => n + (a ? 1 : 0), 0);
    this.stale = pop === 0 || this.recent.includes(sig) ? this.stale + 1 : 0;
    this.recent.push(sig);
    if (this.recent.length > 2) this.recent.shift();
    if (this.stale >= STALE) {
      const w = Math.max(3, Math.min(this.cols, 8)), h = Math.max(3, Math.min(this.rows, 8));
      const oc = Math.floor(this.rand() * this.cols), or = Math.floor(this.rand() * this.rows);
      for (let dr = 0; dr < h; dr++) for (let dc = 0; dc < w; dc++) if (this.rand() < 0.38) this.ages[this.idx(oc + dc, or + dr)] = 1;
      this.stale = 0;
      this.recent = [];
    }
  }
}

// Opacity by age: the app's LifeBackdrop curve, lifted a touch for print.
const glow = (age) => (age === 0 ? 0.05 : 0.62 - 0.36 * Math.min((age - 1) / 12, 1));

// An SVG of the field sized to the canvas. `clear` is an ellipse (in canvas px)
// where the field fades out so the type stays readable over it. `keepout` is a list of
// measured text boxes {x0, y0, x1, y1, fade, floor} (canvas px): a cell inside one drops to
// `floor` and ramps back over `fade` px outside it, so no lit cell sits under a glyph
// whatever the copy's length (2026-10-22 QA: the fixed ellipse ended above 3-line iPad subs).
function keepFactor(x, y, keepout) {
  let f = 1;
  for (const k of keepout || []) {
    const dx = Math.max(k.x0 - x, 0, x - k.x1), dy = Math.max(k.y0 - y, 0, y - k.y1);
    const d = Math.sqrt(dx * dx + dy * dy);
    f = Math.min(f, Math.max(k.floor ?? 0.04, Math.min(1, d / k.fade)));
  }
  return f;
}
function lifeSVG(W, H, { pitch, seed, density = 0.2, generations = 90, clear, keepout, color = "232,232,232" }) {
  const cols = Math.ceil(W / pitch), rows = Math.ceil(H / pitch);
  const f = new LifeField(cols, rows, density, seed);
  for (let g = 0; g < generations; g++) f.advance();
  const inset = Math.max(1.5, pitch * 0.16), side = pitch - inset * 2, rx = side * 0.28;
  const rects = [];
  for (let r = 0; r < rows; r++)
    for (let c = 0; c < cols; c++) {
      const a = f.ages[r * cols + c];
      const x = c * pitch + inset, y = r * pitch + inset;
      let o = glow(a);
      if (clear) {
        const dx = (x - clear.cx) / clear.rx, dy = (y - clear.cy) / clear.ry;
        const d = Math.sqrt(dx * dx + dy * dy);
        const inner = clear.inner ?? 0.55;
        o *= Math.min(1, Math.max(clear.floor ?? 0.18, (d - inner) / 0.5));
      }
      if (keepout) o *= keepFactor(x + side / 2, y + side / 2, keepout);
      if (o < 0.012) continue;
      // No glow inside the clear zone: a blurred newborn reads brighter than its opacity.
      const newborn = a > 0 && a <= 2 && o > 0.25;
      rects.push(
        `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${side.toFixed(1)}" height="${side.toFixed(1)}" rx="${rx.toFixed(1)}" fill="rgba(${color},${o.toFixed(3)})"${newborn ? ' filter="url(#lg)"' : ""}/>`,
      );
    }
  return `<svg class="life" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
<defs><filter id="lg" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="${(pitch * 0.18).toFixed(1)}" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
${rects.join("")}</svg>`;
}

module.exports = { LifeField, lifeSVG };
