#!/usr/bin/env node
// Writes labelled stand-in plates so the set can be reviewed before real
// captures exist. Never ship a frame that still shows one of these — they say
// PLACEHOLDER in 200px letters for exactly that reason.
//   node placeholders.js            → every target
//   node placeholders.js ios        → one target
//   node placeholders.js ios --force  (overwrite real plates — you don't want this)

const { chromium } = require("playwright");
// Browser: M1K3_CHROME (a binary path) wins; else the installed Google Chrome (channel
// "chrome", no download); else Playwright's own Chromium (`npm run setup:browser`).
// 2026-11-24: the bundled chromium-1148 download hung unpacking for 4 h on macOS 27;
// system Chrome rendered the Mac set in 14 s.
const LAUNCH = process.env.M1K3_CHROME
  ? { executablePath: process.env.M1K3_CHROME }
  : require("fs").existsSync("/Applications/Google Chrome.app")
    ? { channel: "chrome" }
    : {};
const fs = require("fs");
const path = require("path");
const { TARGETS, PLATE_NATIVE, BRAND, PLATES } = require("./config.js");
const { PORTRAIT, LANDSCAPE, PLATE_BRIEF } = require("./frames.js");

const force = process.argv.includes("--force");
const targets = process.argv[2] && TARGETS[process.argv[2]] ? [process.argv[2]] : Object.keys(TARGETS);

(async () => {
  const browser = await chromium.launch(LAUNCH);
  for (const target of targets) {
    const { w, h } = PLATE_NATIVE[target];
    const frames = TARGETS[target].orient === "portrait" ? PORTRAIT : LANDSCAPE;
    // A duo frame names its own-target plate as `phone` (its `mac` plate lives in plates/mac).
    const names = [...new Set(frames.flatMap(f => f.plates || [f.plate || f.phone]))];
    const dir = path.join(PLATES, target);
    fs.mkdirSync(dir, { recursive: true });
    const page = await browser.newPage({ viewport: { width: w, height: h } });
    for (const name of names) {
      const out = path.join(dir, `${name}.png`);
      if (fs.existsSync(out) && !force) { console.log(`· keep ${target}/${name}.png (exists)`); continue; }
      const u = Math.min(w, h) / 1320;
      const tmp = out + ".html";
      fs.writeFileSync(tmp, `<!doctype html><html><head><meta charset="utf-8"><style>
        @font-face{font-family:'Mono';src:url('file://${path.join(BRAND.fonts.mono, "ibm-plex-mono-latin-500-normal.woff2")}')}
        @font-face{font-family:'Pixel';src:url('file://${path.join(BRAND.fonts.pixel, "vt323-latin-400-normal.woff2")}')}
        *{margin:0;box-sizing:border-box}
        body{width:${w}px;height:${h}px;overflow:hidden;background:#0a0a0a;color:#8a8a8a;font-family:'Mono',monospace;
          background-image:repeating-linear-gradient(0deg,rgba(232,232,232,.06) 0 1px,transparent 1px ${64*u}px),
                           repeating-linear-gradient(90deg,rgba(232,232,232,.06) 0 1px,transparent 1px ${64*u}px)}
        .c{position:absolute;inset:0;display:flex;flex-direction:column;justify-content:center;align-items:center;text-align:center;padding:${120*u}px}
        .k{font-family:'Pixel',monospace;font-size:${200*u}px;color:#3a3a3a;letter-spacing:.06em;line-height:1}
        .n{font-size:${64*u}px;color:#e8e8e8;margin-top:${40*u}px}
        .b{font-size:${30*u}px;line-height:1.5;max-width:${1000*u}px;margin-top:${40*u}px}
        .p{font-size:${28*u}px;color:#5a5a5a;margin-top:${60*u}px}
        .bar{position:absolute;left:0;right:0;top:0;height:${140*u}px;background:rgba(255,255,255,.04)}
      </style></head><body><div class="bar"></div><div class="c">
        <div class="k">PLACEHOLDER</div>
        <div class="n">${name}</div>
        <div class="b">${PLATE_BRIEF[name] || ""}</div>
        <div class="p">replace with a real capture → plates/${target}/${name}.png · ${w}×${h} expected</div>
      </div></body></html>`);
      await page.goto(`file://${tmp}`);
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: out, type: "png" });
      fs.unlinkSync(tmp);
      console.log(`✓ ${target}/${name}.png  ${w}×${h}`);
    }
    await page.close();
  }
  await browser.close();
})();
