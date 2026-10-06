import { chromium } from 'playwright'; import fs from 'node:fs';
const OUT = new URL('../../assets/', import.meta.url).pathname; fs.mkdirSync(OUT + '/frames', { recursive: true }); fs.mkdirSync(OUT + '/braille', { recursive: true }); fs.mkdirSync(OUT + '/svg', { recursive: true });
const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 256, height: 256 } });
page.on('pageerror', e => console.log('[err]', e.message));
await page.goto('http://127.0.0.1:8765/bake.html'); await page.waitForFunction(() => window.ready, null, { timeout: 60000 });
// Per-frame PNGs, braille cell rows at two sizes, and an 80x40 strip (max 24 frames) for the Svg tier.
await page.evaluate(() => {
  window.post = async (look) => {
    const strips = await window.bake(look);
    const out = {};
    for (const [clip, d] of Object.entries(strips)) {
      const im = new Image(); im.src = 'data:image/png;base64,' + d.png; await im.decode();
      const frames = [], braille = { band: [], pane: [] };
      const bit = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];
      const toBraille = (w, h, cols, rows, thresholdLum) => {
        const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d', { willReadFrequently: true });
        return (i) => { g.clearRect(0, 0, w, h); g.drawImage(im, i * 192, 0, 192, 96, 0, 0, w, h); const px = g.getImageData(0, 0, w, h).data; const lines = [];
          for (let r = 0; r < rows; r++) { let line = ''; for (let col = 0; col < cols; col++) { let bits = 0; for (let dy = 0; dy < 4; dy++) for (let dx = 0; dx < 2; dx++) { const k = ((r * 4 + dy) * w + (col * 2 + dx)) * 4; const lum = (px[k] + px[k + 1] + px[k + 2]) / 3; if (px[k + 3] > 110 && lum > thresholdLum) bits |= bit[dy][dx]; } line += bits ? String.fromCharCode(0x2800 + bits) : ' '; } lines.push(line); } return lines; };
      };
      const band = toBraille(48, 24, 24, 6, look === 'phosphor' ? 70 : 40), pane = toBraille(96, 48, 48, 12, look === 'phosphor' ? 70 : 40);
      const fc = document.createElement('canvas'); fc.width = 192; fc.height = 96; const fg = fc.getContext('2d');
      for (let i = 0; i < d.frames; i++) { fg.clearRect(0, 0, 192, 96); fg.drawImage(im, i * 192, 0, 192, 96, 0, 0, 192, 96); frames.push(fc.toDataURL('image/png').split(',')[1]); braille.band.push(band(i)); braille.pane.push(pane(i)); }
      const step = Math.ceil(d.frames / 24), n = Math.ceil(d.frames / step), sc = document.createElement('canvas'); sc.width = 80 * n; sc.height = 40; const sg = sc.getContext('2d');
      for (let i = 0; i < n; i++) sg.drawImage(im, i * step * 192, 0, 192, 96, i * 80, 0, 80, 40);
      out[clip] = { frames: d.frames, duration: d.duration, pngs: frames, braille, svgStrip: { frames: n, png: sc.toDataURL('image/png').split(',')[1] } };
    }
    return out;
  };
});
const manifest = { frameWidth: 192, frameHeight: 96, looks: {} };
for (const look of ['fox', 'phosphor']) {
  const out = await page.evaluate(l => window.post(l), look);
  manifest.looks[look] = {};
  for (const [clip, d] of Object.entries(out)) {
    d.pngs.forEach((b64, i) => fs.writeFileSync(`${OUT}/frames/${look}-${clip}-${String(i).padStart(2, '0')}.png`, Buffer.from(b64, 'base64')));
    fs.writeFileSync(`${OUT}/braille/${look}-${clip}.json`, JSON.stringify({ frames: d.frames, duration: d.duration, band: d.braille.band, pane: d.braille.pane }));
    fs.writeFileSync(`${OUT}/svg/${look}-${clip}.png`, Buffer.from(d.svgStrip.png, 'base64'));
    manifest.looks[look][clip] = { frames: d.frames, duration: d.duration, svgFrames: d.svgStrip.frames };
    console.log(look, clip, d.frames, 'frames');
  }
}
fs.writeFileSync(OUT + '/manifest.json', JSON.stringify(manifest, null, 2));
await browser.close();
