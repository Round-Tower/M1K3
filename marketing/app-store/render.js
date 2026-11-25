#!/usr/bin/env node
// M1K3 — App Store screenshot renderer.
//   node render.js                 → every target, every locale
//   node render.js ios             → one target (ios | ipad | mac)
//   node render.js ios 03          → one target, one frame
//   node render.js mac en-US 08
//   node render.js ipad ru            → one target, one locale
//
// Env: M1K3_CHROME (browser binary; default the installed Google Chrome), M1K3_PY (python
// command for mask.py/flatten.py; default "uv run --quiet --with pillow python3" when uv is
// installed), M1K3_FONTREPORT (JSON of faces used per role).
//
// Output: out/<target>/<locale>/<frame-id>.png at exact Apple spec, RGB, no alpha, plus
// .plates.json (frame id → the plates it read) for verify.py's drift check.
// Requires: npm i (playwright + fonts), Google Chrome, uv (or python3 + Pillow).

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
const { execFileSync } = require("child_process");
const crypto = require("crypto");
const { TARGETS, BRAND, OUT, PLATES, ROOT } = require("./config.js");
const { lifeSVG } = require("./life.js");
const { PORTRAIT, LANDSCAPE, PLATE_MASKS } = require("./frames.js");
const {
  LOCALES,
  COPY,
  TYPE,
  MAC_OVERRIDES,
  IPAD_OVERRIDES,
} = require("./strings.js");

// ─── brand bits ───────────────────────────────────────────────────────────
// The pixel M (assets/app-icon / macos/tools/icons/brand). 5×5 grid, 13 cells.
const M_CELLS = [
  [0, 0],
  [0, 4],
  [1, 0],
  [1, 1],
  [1, 3],
  [1, 4],
  [2, 0],
  [2, 2],
  [2, 4],
  [3, 0],
  [3, 4],
  [4, 0],
  [4, 4],
];
const PIXEL_M = (() => {
  const s = 18,
    g = 2,
    r = 2.5;
  const rects = M_CELLS.map(
    ([row, col]) =>
      `<rect x="${col * (s + g)}" y="${row * (s + g)}" width="${s}" height="${s}" rx="${r}" fill="currentColor"/>`,
  ).join("");
  return `<svg viewBox="0 0 98 98" xmlns="http://www.w3.org/2000/svg">${rects}</svg>`;
})();

// Each face carries its subset's unicode-range (fontsource's own ranges), so a glyph
// outside it falls through to the next family instead of to Chrome's generic pick.
const fontFace = (fam, dir, file, weight, range) =>
  `@font-face{font-family:'${fam}';src:url('file://${path.join(dir, file)}') format('woff2');font-weight:${weight};unicode-range:${range}}`;
const LATIN =
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD";
const CYRILLIC = "U+0301,U+0400-045F,U+0490-0491,U+04B0-04B1,U+2116";

const FONTS_CSS = [
  ...[400, 500, 600, 700].flatMap((w) => [
    fontFace("Mono", BRAND.fonts.mono, `ibm-plex-mono-latin-${w}-normal.woff2`, w, LATIN),
    fontFace("Mono", BRAND.fonts.mono, `ibm-plex-mono-cyrillic-${w}-normal.woff2`, w, CYRILLIC),
  ]),
  // VT323 ships latin, latin-ext and vietnamese only: no Cyrillic, so ru titles use Plex Mono.
  fontFace("Pixel", BRAND.fonts.pixel, "vt323-latin-400-normal.woff2", 400, LATIN),
  ...[400, 500, 600].flatMap((w) => [
    fontFace("Sans", BRAND.fonts.sans, `inter-latin-${w}-normal.woff2`, w, LATIN),
    fontFace("Sans", BRAND.fonts.sans, `inter-cyrillic-${w}-normal.woff2`, w, CYRILLIC),
  ]),
].join("\n");

// Everything below is in "design px": portrait designed at 1320 wide, landscape
// at 2880 wide. `u` scales it to the real canvas.
const TITLE = process.env.M1K3_TITLE || "pixel";
const CSS = (W, H, u, orient, T) => `
${FONTS_CSS}
*{margin:0;padding:0;box-sizing:border-box}
:root{--u:${u}px;--ink:${BRAND.ink};--bright:${BRAND.inkBright};--dim:${BRAND.inkDim};--faint:${BRAND.inkFaint};--line:${BRAND.line};
  --sh1:${T.h1};--ssub:${T.sub};--lh:${T.lh}}
html,body{width:${W}px;height:${H}px;overflow:hidden;background:${BRAND.bg}}
body{font-family:'Sans',sans-serif;color:var(--ink);-webkit-font-smoothing:antialiased}
.stage{position:relative;width:${W}px;height:${H}px;overflow:hidden;background:${BRAND.bg}}
dim{color:var(--dim)}

/* ── atmosphere: the phosphor floor grid from the site hero ─────────────── */
.floor{position:absolute;left:-40%;right:-40%;bottom:0;height:${orient === "portrait" ? "38%" : "46%"};
  transform-origin:50% 100%;transform:perspective(calc(1100*var(--u))) rotateX(58deg);
  background:
    repeating-linear-gradient(0deg, rgba(232,232,232,.22) 0 2px, transparent 2px calc(72*var(--u))),
    repeating-linear-gradient(90deg, rgba(232,232,232,.14) 0 1px, transparent 1px calc(64*var(--u)));
  -webkit-mask-image:linear-gradient(0deg, rgba(0,0,0,.9) 0%, rgba(0,0,0,.35) 45%, transparent 100%);
  mask-image:linear-gradient(0deg, rgba(0,0,0,.9) 0%, rgba(0,0,0,.35) 45%, transparent 100%)}
.haze{position:absolute;inset:0;background:radial-gradient(ellipse 70% 40% at 50% 100%, rgba(255,255,255,.05), transparent 70%)}
.grain{position:absolute;inset:0;opacity:.22;mix-blend-mode:overlay;
  background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3'/></filter><rect width='180' height='180' filter='url(%23n)' opacity='.55'/></svg>")}
.crt{position:absolute;inset:0;z-index:20;pointer-events:none;
  background:repeating-linear-gradient(0deg, rgba(0,0,0,.22) 0 calc(2*var(--u)), transparent calc(2*var(--u)) calc(5*var(--u)));
  opacity:.55}
.crt::after{content:"";position:absolute;inset:0;box-shadow:inset 0 0 calc(300*var(--u)) rgba(0,0,0,.45)}
.vignette{position:absolute;inset:0;box-shadow:inset 0 0 calc(420*var(--u)) calc(100*var(--u)) rgba(0,0,0,.55);pointer-events:none}

/* ── atmosphere v2 (2026-09-23): Conway's Game of Life, the app's Settings field ── */
.life{position:absolute;inset:0;z-index:0}
.life-haze{position:absolute;inset:0;z-index:1;pointer-events:none;
  background:radial-gradient(ellipse 60% 55% at 72% 50%, rgba(255,255,255,.035), transparent 70%)}
/* A lift: the moment that matters, pulled out of the capture at a size you can read. */
.lift{position:absolute;z-index:8;overflow:hidden;background:#1c1c1e;border-radius:calc(28*var(--u));
  border:calc(2*var(--u)) solid rgba(255,255,255,.24);
  box-shadow:0 calc(60*var(--u)) calc(160*var(--u)) rgba(0,0,0,.92), 0 0 calc(90*var(--u)) rgba(255,255,255,.07)}
.lift img{position:absolute;max-width:none;display:block}
.lift .lift-tag{position:absolute;z-index:2;right:calc(22*var(--u));top:calc(18*var(--u));font-family:'Mono',monospace;font-weight:500;
  font-size:calc(24*var(--u));letter-spacing:.08em;text-transform:uppercase;color:rgba(232,232,232,.72)}

/* ── type ───────────────────────────────────────────────────────────────── */
.eyebrow{display:flex;align-items:center;gap:calc(18*var(--u))}
.eyebrow .m{width:calc(38*var(--u));height:calc(38*var(--u));color:var(--bright);
  filter:drop-shadow(0 0 calc(10*var(--u)) rgba(255,255,255,.55))}
/* Upper-cased in JS (caps()), not CSS: text-transform turned iPhone into "IPHONE". */
.eyebrow span{font-family:'Pixel',monospace;font-size:calc(46*var(--u)*var(--ssub));letter-spacing:.08em;
  color:var(--ink);opacity:.82}
h1{font-family:'Mono',monospace;font-weight:700;font-size:calc(118*var(--u)*var(--sh1));line-height:var(--lh);
  letter-spacing:-.045em;color:var(--bright);margin-top:calc(30*var(--u));
  text-shadow:0 0 calc(2*var(--u)) #fff, 0 0 calc(22*var(--u)) rgba(255,255,255,.28)}
h1.hero{font-size:calc(126*var(--u)*var(--sh1))}
h1 dim{text-shadow:none}
.sub{margin-top:calc(34*var(--u));font-family:'Sans',sans-serif;font-weight:400;font-size:calc(42*var(--u)*var(--ssub));
  line-height:1.36;letter-spacing:-.008em;color:rgba(232,232,232,.74);max-width:calc(1128*var(--u))}
.corner{font-family:'Mono',monospace;font-weight:400;font-size:calc(32*var(--u)*var(--ssub));letter-spacing:.02em;
  color:rgba(232,232,232,.66)} /* QA r2: 26u at .46 vanished on the stat frames */
.corner::before{content:"// ";color:var(--faint)}
.chips{display:flex;flex-wrap:wrap;gap:calc(14*var(--u));margin-top:calc(34*var(--u))}
.chip{font-family:'Mono',monospace;font-weight:500;font-size:calc(27*var(--u)*var(--ssub));letter-spacing:.02em;
  color:var(--ink);border:1px solid rgba(232,232,232,.22);border-radius:calc(8*var(--u));
  padding:calc(12*var(--u)) calc(20*var(--u));background:rgba(255,255,255,.03)}
.big{font-family:'Pixel',monospace;font-size:calc(520*var(--u)*var(--sh1));line-height:.82;color:var(--bright);display:inline-block;transform:scaleX(1.6);transform-origin:0 50%;margin-right:calc(150*var(--u));
  text-shadow:0 0 calc(4*var(--u)) #fff, 0 0 calc(60*var(--u)) rgba(255,255,255,.45);letter-spacing:-.02em}
.bigunit{font-family:'Mono',monospace;font-weight:500;font-size:calc(46*var(--u)*var(--ssub));line-height:1.2;color:var(--ink);flex:1;min-width:0;text-wrap:balance}
.tag{position:absolute;left:calc(28*var(--u));top:calc(28*var(--u));z-index:3;font-family:'Mono',monospace;font-weight:500;
  font-size:calc(26*var(--u));letter-spacing:.04em;color:var(--ink);background:rgba(5,5,5,.72);
  border:1px solid rgba(232,232,232,.22);border-radius:calc(8*var(--u));padding:calc(10*var(--u)) calc(18*var(--u));
  backdrop-filter:blur(calc(10*var(--u)))}
.tile-label{position:absolute;left:0;right:0;bottom:0;z-index:3;padding:calc(90*var(--u)) calc(28*var(--u)) calc(24*var(--u));
  font-family:'Mono',monospace;font-size:calc(28*var(--u));letter-spacing:.04em;color:var(--ink);
  background:linear-gradient(0deg, rgba(5,5,5,.9), transparent)}

/* ── panels (the real app pixels) ───────────────────────────────────────── */
.panel{position:absolute;overflow:hidden;background:#000;
  border:calc(2*var(--u)) solid rgba(232,232,232,.16);
  box-shadow:0 0 calc(90*var(--u)) rgba(255,255,255,.07), 0 calc(40*var(--u)) calc(140*var(--u)) rgba(0,0,0,.85)}
.panel img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:50% 0%;display:block}
.panel.phone{border-radius:calc(112*var(--u))}
.panel.pad{border-radius:calc(64*var(--u))}
.panel.win{border-radius:calc(28*var(--u))}
.panel.tile{border-radius:calc(28*var(--u))}
.panel.tile img{object-position:50% 50%}


/* ── device chrome: 3D-ish renders of current Apple hardware ───────────── */
/* Layers: .device (perspective + shadow) > .rail (titanium/aluminium) > .bezel (black) > .screen (real pixels) */
.device{position:absolute;transform-style:preserve-3d}
.device .rail{position:relative;width:100%;height:100%;
  background:linear-gradient(160deg,#e6e6e6 0%,#9a9a9a 18%,#5f5f5f 42%,#8c8c8c 60%,#c9c9c9 82%,#6a6a6a 100%);
  box-shadow:0 calc(70*var(--u)) calc(180*var(--u)) rgba(0,0,0,.92), 0 calc(10*var(--u)) calc(30*var(--u)) rgba(0,0,0,.7),
    inset 0 0 0 calc(1*var(--u)) rgba(255,255,255,.35), inset 0 0 0 calc(3*var(--u)) rgba(0,0,0,.35)}
.device .bezel{position:absolute;background:#070707;
  box-shadow:inset 0 0 0 calc(1*var(--u)) rgba(255,255,255,.06), inset 0 0 calc(24*var(--u)) rgba(0,0,0,.9)}
.device .screen{position:absolute;overflow:hidden;background:#000}
.device .screen img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:50% 0%;display:block}
.device .sheen{position:absolute;inset:0;z-index:4;pointer-events:none;
  background:linear-gradient(112deg, rgba(255,255,255,.13) 0%, rgba(255,255,255,.05) 18%, transparent 36%, transparent 70%, rgba(255,255,255,.035) 100%)}
.device .edge{position:absolute;inset:0;z-index:5;pointer-events:none;
  box-shadow:inset calc(2*var(--u)) calc(2*var(--u)) calc(4*var(--u)) rgba(255,255,255,.28), inset calc(-2*var(--u)) calc(-2*var(--u)) calc(4*var(--u)) rgba(0,0,0,.6)}
.device .btn{position:absolute;background:linear-gradient(90deg,#3a3a3a,#9d9d9d 40%,#5a5a5a);border-radius:calc(3*var(--u));
  box-shadow:0 calc(2*var(--u)) calc(4*var(--u)) rgba(0,0,0,.7)}
/* iPhone 17 Pro-class: titanium rail, 5-lens-free flat front, Dynamic Island */
.device.phone{aspect-ratio:1320/2868;transform:perspective(calc(5200*var(--u))) rotateY(-7deg) rotateX(3.5deg);transform-origin:50% 0%}
.device.phone .rail{border-radius:calc(176*var(--u))}
.device.phone .bezel{inset:calc(12*var(--u));border-radius:calc(164*var(--u))}
.device.phone .screen{inset:calc(30*var(--u));border-radius:calc(146*var(--u))}
.device.phone .sheen,.device.phone .edge{border-radius:calc(176*var(--u))}
.device.phone .island{position:absolute;z-index:6;left:50%;top:calc(58*var(--u));transform:translateX(-50%);
  width:calc(318*var(--u));height:calc(92*var(--u));border-radius:calc(46*var(--u));background:#000;
  box-shadow:0 0 0 calc(1*var(--u)) rgba(255,255,255,.05)}
.device.phone .island::after{content:"";position:absolute;right:calc(26*var(--u));top:50%;width:calc(40*var(--u));height:calc(40*var(--u));
  margin-top:calc(-20*var(--u));border-radius:50%;background:radial-gradient(circle at 40% 35%,#1d2430,#05070a 65%);box-shadow:inset 0 0 calc(4*var(--u)) rgba(255,255,255,.12)}
.device.phone .btn.act{left:calc(-6*var(--u));top:calc(380*var(--u));width:calc(6*var(--u));height:calc(74*var(--u))}
.device.phone .btn.vu{left:calc(-6*var(--u));top:calc(520*var(--u));width:calc(6*var(--u));height:calc(150*var(--u))}
.device.phone .btn.vd{left:calc(-6*var(--u));top:calc(700*var(--u));width:calc(6*var(--u));height:calc(150*var(--u))}
.device.phone .btn.pwr{right:calc(-6*var(--u));top:calc(600*var(--u));width:calc(6*var(--u));height:calc(230*var(--u))}
.device.phone .btn.cam{right:calc(-5*var(--u));top:calc(1000*var(--u));width:calc(5*var(--u));height:calc(110*var(--u))}
/* iPad Pro 13": thin aluminium rail, thin bezel, landscape-centre camera on the long edge */
.device.pad{aspect-ratio:2064/2752;transform:perspective(calc(5200*var(--u))) rotateY(-6deg) rotateX(3deg);transform-origin:50% 0%}
.device.pad .rail{border-radius:calc(78*var(--u));background:linear-gradient(160deg,#dedede,#8e8e8e 30%,#b9b9b9 60%,#6f6f6f)}
.device.pad .bezel{inset:calc(8*var(--u));border-radius:calc(72*var(--u))}
.device.pad .screen{inset:calc(44*var(--u));border-radius:calc(46*var(--u))}
.device.pad .sheen,.device.pad .edge{border-radius:calc(78*var(--u))}
.device.pad .cam{position:absolute;z-index:6;top:calc(22*var(--u));left:50%;width:calc(14*var(--u));height:calc(14*var(--u));margin-left:calc(-7*var(--u));
  border-radius:50%;background:radial-gradient(circle at 40% 35%,#1d2430,#05070a 65%)}
/* iPhone Duo, open: titanium rail, the inner screen's ~0.70 shape, front camera top right */
.device.fold{aspect-ratio:2007/2853;transform:perspective(calc(5200*var(--u))) rotateY(-6deg) rotateX(3deg);transform-origin:50% 0%}
.device.fold .rail{border-radius:calc(96*var(--u))}
.device.fold .bezel{inset:calc(10*var(--u));border-radius:calc(88*var(--u))}
.device.fold .screen{inset:calc(28*var(--u));border-radius:calc(70*var(--u))}
.device.fold .sheen,.device.fold .edge{border-radius:calc(96*var(--u))}
.device.fold .cam{position:absolute;z-index:6;top:calc(52*var(--u));right:calc(60*var(--u));width:calc(26*var(--u));height:calc(26*var(--u));
  border-radius:50%;background:radial-gradient(circle at 40% 35%,#1d2430,#05070a 65%)}
/* iPhone Duo, folded: the outer screen, same rail, camera in the right-edge strip */
.device.foldout{aspect-ratio:1398/2034;transform:perspective(calc(5200*var(--u))) rotateY(-6deg) rotateX(3deg);transform-origin:50% 0%}
.device.foldout .rail{border-radius:calc(120*var(--u))}
.device.foldout .bezel{inset:calc(10*var(--u));border-radius:calc(112*var(--u))}
.device.foldout .screen{inset:calc(28*var(--u));border-radius:calc(94*var(--u))}
.device.foldout .sheen,.device.foldout .edge{border-radius:calc(120*var(--u))}
.device.foldout .cam{position:absolute;z-index:6;top:calc(70*var(--u));right:calc(58*var(--u));width:calc(30*var(--u));height:calc(30*var(--u));
  border-radius:50%;background:radial-gradient(circle at 40% 35%,#1d2430,#05070a 65%)}
/* iPhone Duo, unfolded and held landscape: the inner screen as the simulator draws it (2853×2007) */
.device.foldwide{aspect-ratio:2853/2007}
.device.foldwide .rail{border-radius:calc(96*var(--u))}
.device.foldwide .bezel{inset:calc(10*var(--u));border-radius:calc(88*var(--u))}
.device.foldwide .screen{inset:calc(28*var(--u));border-radius:calc(70*var(--u))}
.device.foldwide .sheen,.device.foldwide .edge{border-radius:calc(96*var(--u))}
.device.foldwide .cam{position:absolute;z-index:6;top:calc(52*var(--u));right:calc(60*var(--u));width:calc(26*var(--u));height:calc(26*var(--u));
  border-radius:50%;background:radial-gradient(circle at 40% 35%,#1d2430,#05070a 65%)}
/* MacBook Pro-class: black bezel with notch, aluminium lid, slim deck below */
.device.laptop{transform:perspective(calc(6000*var(--u))) rotateY(-5deg) rotateX(2deg);transform-origin:50% 60%}
.device.laptop .lid{position:relative;width:100%;aspect-ratio:2880/1800;padding:calc(34*var(--u));
  background:linear-gradient(160deg,#dcdcdc,#8f8f8f 35%,#b5b5b5 65%,#707070);border-radius:calc(44*var(--u)) calc(44*var(--u)) calc(10*var(--u)) calc(10*var(--u));
  box-shadow:0 calc(80*var(--u)) calc(200*var(--u)) rgba(0,0,0,.92), inset 0 0 0 calc(1*var(--u)) rgba(255,255,255,.35)}
.device.laptop .bezel{position:absolute;inset:calc(10*var(--u));border-radius:calc(36*var(--u)) calc(36*var(--u)) calc(4*var(--u)) calc(4*var(--u))}
.device.laptop .screen{inset:calc(30*var(--u));border-radius:calc(14*var(--u)) calc(14*var(--u)) calc(2*var(--u)) calc(2*var(--u))}
.device.laptop .screen img{transform-origin:0 0}
.device.laptop .notch{position:absolute;z-index:6;left:50%;top:calc(10*var(--u));transform:translateX(-50%);
  width:calc(300*var(--u));height:calc(36*var(--u));background:#070707;border-radius:0 0 calc(14*var(--u)) calc(14*var(--u))}
.device.laptop .deck{position:relative;width:104%;left:-2%;height:calc(40*var(--u));
  background:linear-gradient(180deg,#c4c4c4,#8a8a8a 50%,#5a5a5a);border-radius:0 0 calc(30*var(--u)) calc(30*var(--u));
  box-shadow:0 calc(30*var(--u)) calc(80*var(--u)) rgba(0,0,0,.8), inset 0 calc(1*var(--u)) 0 rgba(255,255,255,.5)}
.device.laptop .deck::after{content:"";position:absolute;left:50%;top:0;width:calc(360*var(--u));height:calc(14*var(--u));margin-left:calc(-180*var(--u));
  background:linear-gradient(180deg,#6a6a6a,#9a9a9a);border-radius:0 0 calc(10*var(--u)) calc(10*var(--u))}
.device.laptop .sheen,.device.laptop .edge{border-radius:calc(44*var(--u)) calc(44*var(--u)) calc(10*var(--u)) calc(10*var(--u))}
.device .tag{z-index:7;top:calc(170*var(--u))}
.device.official .bezel-img{position:absolute;inset:0;width:100%;height:100%;z-index:6;pointer-events:none}
.device.official .screen{inset:var(--bezel-inset,0)}

/* ── portrait layouts ───────────────────────────────────────────────────── */
.p-head{position:absolute;left:calc(96*var(--u));right:calc(96*var(--u));top:calc(150*var(--u));z-index:5}
.p-head .corner{margin-top:calc(40*var(--u))}
.p-body{position:absolute;left:calc(96*var(--u));right:calc(96*var(--u));bottom:0;z-index:4}

/* ── landscape layouts ──────────────────────────────────────────────────── */
.scrim-bl{position:absolute;inset:0;z-index:2;background:
  linear-gradient(100deg, rgba(5,5,5,.94) 0%, rgba(5,5,5,.78) 26%, rgba(5,5,5,.22) 52%, rgba(5,5,5,0) 70%),
  linear-gradient(0deg, rgba(5,5,5,.9) 0%, rgba(5,5,5,.32) 30%, rgba(5,5,5,0) 55%)}
.l-block{position:absolute;left:calc(150*var(--u));bottom:calc(150*var(--u));max-width:calc(1500*var(--u));z-index:5}
.l-block h1{font-size:calc(150*var(--u)*var(--sh1))}
.l-block h1.hero{font-size:calc(168*var(--u)*var(--sh1))}
.l-block .sub{font-size:calc(44*var(--u)*var(--ssub));max-width:calc(1300*var(--u))}
.l-corner{position:absolute;right:calc(120*var(--u));bottom:calc(110*var(--u));z-index:6}
.l-col{position:absolute;left:calc(150*var(--u));top:0;bottom:0;width:calc(1080*var(--u));display:flex;flex-direction:column;justify-content:center;z-index:5}
.l-col h1{font-size:calc(112*var(--u)*var(--sh1))}
.l-col .sub{font-size:calc(42*var(--u)*var(--ssub));max-width:calc(1000*var(--u))}
.l-col .corner{margin-top:calc(44*var(--u))}
/* readability pass (2026-09-23): the sub line is the explanation — make it legible at thumbnail size */
.sub{color:rgba(240,240,240,.88)}
.l-col .sub,.l-block .sub{font-size:calc(54*var(--u)*var(--ssub));line-height:1.3;max-width:calc(1040*var(--u))}
.p-head .sub{font-size:calc(50*var(--u)*var(--ssub))}
/* no one-word last lines ("…Searched on the / phone.") */
.sub,.corner{text-wrap:pretty}
.nw{white-space:nowrap}
${
  TITLE === "pixel"
    ? `
/* ── coherency pass: titles in VT323 like m1k3.app (h1.headline), eyebrows in Plex Mono like .label ── */
.eyebrow span{font-family:'Mono',monospace;font-weight:500;font-size:calc(30*var(--u)*var(--ssub));letter-spacing:.18em;opacity:.7}
h1,.l-block h1,.l-col h1{font-family:'Pixel',monospace;font-weight:400;line-height:calc(.84*var(--lh));letter-spacing:.01em;
  text-shadow:0 0 calc(2*var(--u)) #fff, 0 0 calc(18*var(--u)) rgba(255,255,255,.4)}
h1{font-size:calc(160*var(--u)*var(--sh1));margin-top:calc(22*var(--u))}
h1.hero{font-size:calc(166*var(--u)*var(--sh1))}
.l-block h1{font-size:calc(210*var(--u)*var(--sh1))} .l-block h1.hero{font-size:calc(236*var(--u)*var(--sh1))}
.l-col h1{font-size:calc(160*var(--u)*var(--sh1))}
`
    : ``
}
/* ── v2 billboards (01-03 carry the search card): brighter dim line, readable eyebrow ── */
.bb h1 dim{color:#b0b0b0}
.bb .eyebrow span{font-size:calc(40*var(--u)*var(--ssub));opacity:.9}
.bb .l-col .eyebrow span{font-size:calc(34*var(--u)*var(--ssub))} /* the Mac column is 1080 wide: keep the duo eyebrow on one line */

/* ── per-locale faces (set by <html lang>). VT323 is Latin-only. ── */
html:lang(ru) :is(h1,.l-block h1,.l-col h1){font-family:'Mono',monospace;font-weight:700;letter-spacing:-.03em}
html:lang(ja){--cjk:'Hiragino Sans'}
html:lang(zh-Hans){--cjk:'PingFang SC'}
html:lang(ko){--cjk:'Apple SD Gothic Neo'}
html:lang(ar){--cjk:'Geeza Pro','Helvetica Neue'}
html:lang(ja) :is(h1,.l-block h1,.l-col h1){font-family:'Hiragino Sans',sans-serif;font-weight:600;letter-spacing:0;word-break:auto-phrase;font-feature-settings:"halt"} /* half-width 「」: no indent */
html:lang(zh-Hans) :is(h1,.l-block h1,.l-col h1){font-family:'PingFang SC',sans-serif;font-weight:600;letter-spacing:0}
html:lang(ko) :is(h1,.l-block h1,.l-col h1){font-family:'Apple SD Gothic Neo',sans-serif;font-weight:700;letter-spacing:0;word-break:keep-all}
html:lang(ar) :is(h1,.l-block h1,.l-col h1){font-family:'Geeza Pro','Helvetica Neue',sans-serif;font-weight:700;letter-spacing:0}
/* PingFang/Hiragino draw "-" near en-dash wide ("Wi–Fi"): set the token in a Latin face */
html:is(:lang(ja),:lang(zh-Hans),:lang(ko)) h1 .nw{font-family:'Helvetica Neue',sans-serif}
html:is(:lang(ja),:lang(zh-Hans),:lang(ko),:lang(ar)) :is(.eyebrow span,.corner,.bigunit,.tile-label,.tag,.duo-link){font-family:'Mono',var(--cjk),sans-serif}
html:is(:lang(ja),:lang(zh-Hans),:lang(ko),:lang(ar)) .sub{font-family:'Sans',var(--cjk),sans-serif}
html:is(:lang(ja),:lang(zh-Hans),:lang(ko)) .eyebrow span{letter-spacing:.06em}
/* break between words/phrases, never inside one (QA: "Wi-Fi로 / 만.", "自 / 宅", "コー / ド") */
html:lang(ja) :is(.sub,.bigunit,.corner,.eyebrow span,.tile-label){word-break:auto-phrase}
html:lang(ko) :is(.sub,.bigunit,.corner,.eyebrow span,.tile-label){word-break:keep-all}
/* CJK and Arabic glyphs read small at the Latin eyebrow size */
html:is(:lang(ja),:lang(zh-Hans),:lang(ko),:lang(ar)) .eyebrow span{font-size:calc(36*var(--u)*var(--ssub))}
html:is(:lang(ja),:lang(zh-Hans),:lang(ko),:lang(ar)) .bb .eyebrow span{font-size:calc(44*var(--u)*var(--ssub))}
html:is(:lang(ja),:lang(zh-Hans),:lang(ko),:lang(ar)) .bb .l-col .eyebrow span{font-size:calc(38*var(--u)*var(--ssub))}

/* ── RTL: dir sits on the caption blocks only, so device chrome and flex rows of art stay put ── */
[dir=rtl]{text-align:right}
[dir=rtl] .eyebrow span,[dir=rtl].tag,[dir=rtl].tile-label,[dir=rtl].duo-link{letter-spacing:0}
[dir=rtl] .big{transform-origin:100% 50%;margin-right:0;margin-left:calc(150*var(--u))}
.tag[dir=rtl]{left:auto;right:calc(28*var(--u))}
/* QA r3: on a device the right corner is the app's close button; the left is empty black */
.device .tag[dir=rtl]{left:calc(28*var(--u));right:auto}
/* right-aligned Mac columns end where the lifts begin (x≈1100): pull the edge in */
.l-col[dir=rtl]{width:calc(930*var(--u)) !important}

/* ── duo: Mac + phone/pad, joined by a dashed "your own Wi-Fi" pill ── */
.duo-link{position:absolute;z-index:7;font-family:'Mono',monospace;font-weight:500;font-size:calc(28*var(--u)*var(--ssub));
  letter-spacing:.12em;color:var(--ink);border:calc(2*var(--u)) dashed rgba(232,232,232,.4);white-space:nowrap;
  border-radius:calc(10*var(--u));padding:calc(12*var(--u)) calc(22*var(--u));background:rgba(5,5,5,.8)}
`;

// ─── HTML builders ────────────────────────────────────────────────────────
const esc = (s) => s; // copy is authored HTML (<br>, <dim>)
// `focus` (a CSS object-position) picks which part of a capture survives the
// screen's cover-crop — frames.js sets it; it was ignored until 2026-09-13.
// `focus` may instead be a crop [x, y, w] in plate pixels: that region, `w` wide, fills
// the screen (any device) from its top-left; the height follows the screen's aspect. It is
// how a frame keeps a band of the capture out of view (v2: the Mac's MCP agent picker).
// [x, y, w, h, fill] shows only that band, `w` wide, centred on the screen's height, with
// `fill` (the capture's own background) above and below — for a band whose neighbours
// must stay out (Brain at Home's OFF toggle and caveat paragraph, the DuckDuckGo row).
// The offset is a translate in % of the image's own size, so it holds at any screen
// aspect (2026-10-22 QA: the old fixed laptop aspect was 1752/1039.5 against a real
// 1820/1107.5, which pushed the crop ~36 plate px low and left a black band under it).
// { x, w, fill, bands: [[sy, sh, dy], ...] } stacks horizontal bands of the capture, `w` plate
// px wide from `x`, each drawn at `dy` plate px down the screen (scale = screen width / w), on
// `fill`. It is how a frame drops rows a capture can't show (QA round 2: the iPhone Settings
// list's "Version 1.0.0 (1)", a memory naming a firm, the Mac's caveat paragraph), the way a
// scrolled list would: every band is the app's own pixels at one scale, in their own order.
const pct = (n) => `${(n * 100).toFixed(3)}%`;
const img = (f, focus) => {
  if (focus && focus.bands) {
    const { w: pw, h: ph } = pngSize(f);
    const { x = 0, w: cw = pw, fill = "#000" } = focus;
    const bands = focus.bands
      // a 4th value fades the band's last `fade` plate rows to the fill (QA r3: the Inkfish's
      // tentacle tips run on under the Listening pill; a hard cut read as clipped)
      .map(([sy, sh, dy, fade]) => `<div style="position:absolute;left:0;right:0;top:0;margin-top:${pct(dy / cw)};aspect-ratio:${cw}/${sh};overflow:hidden${fade ? `;-webkit-mask-image:linear-gradient(180deg,#000 ${pct(1 - fade / sh)},transparent)` : ""}"><img src="file://${f}" style="inset:auto;left:0;top:0;object-fit:fill;width:${pct(pw / cw)};height:auto;transform:translate(${pct(-x / pw)},${pct(-sy / ph)})"></div>`)
      .join("");
    return `<div style="position:absolute;inset:0;background:${fill}"></div>${bands}`;
  }
  if (Array.isArray(focus)) {
    const { w: pw, h: ph } = pngSize(f);
    const [cx, cy, cw, ch, fill] = focus;
    const im = `<img src="file://${f}" style="inset:auto;left:0;top:0;object-fit:fill;width:${pct(pw / cw)};height:auto;transform:translate(${pct(-cx / pw)},${pct(-cy / ph)})">`;
    if (!ch) return im;
    return `<div style="position:absolute;inset:0;background:${fill || "#000"}"></div><div style="position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);aspect-ratio:${cw}/${ch};overflow:hidden">${im}</div>`;
  }
  return `<img src="file://${f}"${focus ? ` style="object-position:${focus}"` : ""}>`;
};
// A focus may be keyed by target ({ ios: ..., ipad: ... }): plate pixels differ per device.
const focusFor = (focus, target) =>
  focus && !Array.isArray(focus) && typeof focus === "object" ? (focus[target] ?? focus[like(target)]) : focus;
// A target that borrows another's layout geometry (the iPhone Duo's iPad-shaped screens), else itself.
function like(target) {
  return TARGETS[target]?.like || target;
}

// Draws `inner` with its own --u, k times the canvas's: device chrome is sized in absolute
// design px (the phone's rail assumes ~1128 wide, the laptop ~1900), so a smaller device
// is the same device at a smaller unit. x/y are design px in the parent box.
const scaled = (u, x, y, k, inner) =>
  `<div style="position:absolute;left:${(x * u).toFixed(1)}px;top:${(y * u).toFixed(1)}px;--u:${(u * k).toFixed(4)}px;z-index:3">${inner}</div>`;

// Eyebrows and the duo pill are set in caps, but Apple's product names keep their casing
// (QA: "MAC + IPHONE"). Only text outside tags and entities is upper-cased.
// "Mac" keeps its casing only in a product list ("Mac + iPhone"); in prose it caps with the
// line (QA r2: "ON THIS Mac" read as a casing bug).
const KEEP_CASE = /(iPhone|iPad|\bMac(?= \+ )|(?<=\+ )Mac\b|Wi-Fi|M1K3)/;
const caps = (html) =>
  html == null
    ? html
    : html
        .split(/(<[^>]+>|&[a-zA-Z#0-9]+;)/)
        // a tag-isolated token (ar-SA's <bdi>Mac</bdi>) keeps its casing whole
        .map((part, i) => (i % 2 || part === "Mac" ? part : part.split(KEEP_CASE).map((t, j) => (j % 2 ? t : t.toUpperCase())).join("")))
        .join("");
// "Wi-Fi" never breaks at its hyphen (CJK lines break there freely). Text outside tags only.
const nowrapWiFi = (html) =>
  typeof html !== "string"
    ? html
    : html
        .split(/(<[^>]+>)/)
        .map((part, i) => (i % 2 ? part : part.replace(/Wi-Fi/g, '<span class="nw">Wi-Fi</span>')))
        .join("");
function prepCopy(c) {
  const out = { ...c };
  for (const k of ["h1", "sub", "corner", "bigUnit"]) out[k] = nowrapWiFi(out[k]);
  out.eyebrow = nowrapWiFi(caps(out.eyebrow));
  out.link = caps(out.link);
  return out;
}

// RTL goes on the caption blocks only (never <html>: that would mirror flex rows and device chrome).
const dirAttr = (T) => (T.dir ? ` dir="${T.dir}"` : "");
// A frame can set its headline size in design px (v2 billboards 01-03, the duo's .9).
const h1Style = (fr) => (fr.h1px ? ` style="font-size:calc(${fr.h1px}*var(--u)*var(--sh1))"` : "");

// A rendered device around a real capture. `bezels/<kind>.png` (Apple Design
// Resources product bezel, transparent screen) overrides the CSS chrome if present.
function device(kind, plate, style = "", extra = "", focus = "") {
  const bez = path.join(ROOT, "bezels", `${kind}.png`);
  if (fs.existsSync(bez)) {
    return `<div class="device ${kind} official" style="${style}"><div class="screen">${extra}${img(plate, focus)}</div><img class="bezel-img" src="file://${bez}"></div>`;
  }
  if (kind === "laptop") {
    // A Mac screen is the whole window, as the Mac draws it: no crop, band or zoom inside the
    // laptop (Kev, 2026-11-25: "cropping oddly, and stretched in places - don't look like they're
    // running on a real device"; 05 was zoomed 1.9×, 08 stitched from two bands). Compose the shot
    // in the app (ScreengrabHarness) instead; only an object-position may pick the cover's anchor.
    if (focus && typeof focus !== "string") throw new Error(`${plate}: a laptop screen shows the whole window; crop focus refused`);
    return `<div class="device laptop" style="${style}"><div class="lid"><div class="bezel"><div class="notch"></div><div class="screen">${extra}${img(plate, focus)}</div></div><div class="sheen"></div><div class="edge"></div></div><div class="deck"></div></div>`;
  }
  const parts =
    kind === "phone"
      ? `<div class="island"></div><div class="btn act"></div><div class="btn vu"></div><div class="btn vd"></div><div class="btn pwr"></div><div class="btn cam"></div>`
      : `<div class="cam"></div>`;
  return `<div class="device ${kind}" style="${style}"><div class="rail"><div class="bezel"></div><div class="screen">${extra}${img(plate, focus)}</div>${parts}<div class="sheen"></div><div class="edge"></div></div></div>`;
}

// PNG IHDR: width/height as big-endian uint32 at bytes 16/20.
function pngSize(f) {
  const b = Buffer.alloc(24);
  const fd = fs.openSync(f, "r");
  fs.readSync(fd, b, 0, 24, 0);
  fs.closeSync(fd);
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
}

// A lift: `crop` [x, y, w, h] in the plate's own pixels, drawn `w` design px wide at `at` [x, y].
function lift(target, L, fallbackPlate) {
  const f = platePath(target, L.plate || fallbackPlate);
  const { w: pw, h: ph } = pngSize(f);
  const [cx, cy, cw, ch] = L.crop;
  const s = L.w / cw;
  const h = ch * s;
  const rot = L.rot ? `transform:rotate(${L.rot}deg);` : "";
  // bare: no border or fill, rounded to `radius` plate px: a lifted pill whose own outline is the
  // edge (QA r3: a bordered box round a bordered pill read as a double frame).
  const bare = L.bare ? `border:none;background:#000;border-radius:calc(${((L.radius ?? ch / 2) * s).toFixed(1)}*var(--u));` : "";
  // anchor: the lift sits over its own source on the device (render-time, see anchorLifts),
  // so the moment shows once, large, instead of twice. at is then only the fallback.
  const anc = L.anchor
    ? ` data-anchor='${JSON.stringify({ crop: L.crop, pw, ph, ...(L.anchor === true ? {} : L.anchor) })}'`
    : "";
  const at = L.at || [0, 0];
  return `<div class="lift"${anc} style="left:calc(${at[0]}*var(--u));top:calc(${at[1]}*var(--u));width:calc(${L.w}*var(--u));height:calc(${h.toFixed(1)}*var(--u));${rot}${bare}">
    ${L.tag ? `<div class="lift-tag">${L.tag}</div>` : ""}
    <img src="file://${f}" style="width:calc(${(pw * s).toFixed(1)}*var(--u));height:calc(${(ph * s).toFixed(1)}*var(--u));left:calc(${(-cx * s).toFixed(1)}*var(--u));top:calc(${(-cy * s).toFixed(1)}*var(--u))"></div>`;
}

// Lifts are an array (every target) or keyed by target ({ ipad: [...] }) — plate pixels differ per device.
const liftsFor = (fr, target) =>
  Array.isArray(fr.lifts) ? fr.lifts : (fr.lifts && (fr.lifts[target] || fr.lifts[like(target)])) || [];

// A stable per-frame seed, so each frame has its own field and re-renders identically.
const seedFor = (id) => [...id].reduce((h, ch) => (Math.imul(h, 131) + ch.charCodeAt(0)) >>> 0, 0x4d314b33);

function lifeLayer(W, H, u, id, clear, keepout) {
  return lifeSVG(W, H, { pitch: 34 * u, seed: seedFor(id), density: 0.2, generations: 90, clear, keepout }) + `<div class="life-haze"></div>`;
}
const portraitClear = (fr, W, H) => ({ cx: W * 0.4, cy: H * (fr.layout === "stat" ? 0.24 : 0.16), rx: W * 0.7, ry: H * (fr.layout === "stat" ? 0.3 : 0.22), floor: 0.04, inner: 0.85 });

// Plates with a PLATE_MASKS entry render from a retouched copy in out/.plates (mask.py).
const MASKED = path.join(OUT, ".plates");
// The plates the frame being drawn reads ("mac/chat.png"), for out/<target>/<locale>/.plates.json:
// verify.py fails a frame whose plate changed since its crop was last checked by eye (2026-11-24:
// the 1.6 Settings panes moved under two hand-tuned Mac crops and "spec OK" passed both).
let USED = null;
// A plate's hash as this render draws it: `raw` = the capture's bytes, `look` = bytes + its
// PLATE_MASKS retouch, so a mask edit alone is drift too. verify.py stamps `look` on approve and
// compares the file now with `raw` (a plate recaptured after the render needs a re-render).
function plateHashes(id) {
  const [target, file] = id.split("/");
  const bytes = fs.readFileSync(path.join(PLATES, target, file));
  const h = (...parts) => { const d = crypto.createHash("sha256"); parts.forEach((p) => d.update(p)); return d.digest("hex").slice(0, 16); };
  const mask = JSON.stringify(PLATE_MASKS[target]?.[file.replace(/\.png$/, "")] ?? null);
  return { raw: h(bytes), look: h(bytes, mask) };
}
function platePath(target, name) {
  if (USED) USED.add(`${target}/${name}.png`);
  if (PLATE_MASKS[target]?.[name]) return path.join(MASKED, target, `${name}.png`);
  const f = path.join(PLATES, target, `${name}.png`);
  if (!fs.existsSync(f))
    throw new Error(
      `missing plate ${target}/${name}.png — run \`node placeholders.js\` or drop a real capture in plates/${target}/`,
    );
  return f;
}

function head(c, fr, T) {
  const chips = c.chips
    ? `<div class="chips">${c.chips.map((x) => `<span class="chip">${x}</span>`).join("")}</div>`
    : "";
  return `<div class="p-head"${dirAttr(T)}>
    <div class="eyebrow"><span>${c.eyebrow}</span></div>
    <h1 class="${fr.hero ? "hero" : ""}"${h1Style(fr)}>${c.h1}</h1>
    ${c.sub ? `<p class="sub">${c.sub}</p>` : ""}${chips}
    ${c.corner ? `<div class="corner">${c.corner}</div>` : ""}
  </div>`;
}

function portrait(target, fr, c, T, W, H, u) {
  const shape = TARGETS[target].shape || (target === "ipad" ? "pad" : "phone");
  // The field clears behind the type block (top) and runs full behind the device.
  const atmosphere = lifeLayer(W, H, u, fr.id, portraitClear(fr, W, H));
  let body = "";
  switch (fr.layout) {
    case "top":
      body = `<div class="p-body" style="top:var(--panel-top)">${device(shape, platePath(target, fr.plate), "left:0;width:100%", "", focusFor(fr.focus, target))}</div>`;
      break;
    case "top-pair": {
      // Each device is the full-size device drawn at k (scaled()), not a 60%-wide box: the
      // bezel/screen insets are absolute design px, so a narrowed box got a screen narrower
      // than the capture's aspect and object-fit:cover sliced the status-bar clock ("..32").
      // The tag is zoomed back up by 1/k so it reads at the designed size.
      const [a, b] = fr.plates;
      const k = 744 / 1128; // 60% of the 1240-wide body, over the 1128-wide base device
      const tag = (t) => `<div class="tag"${dirAttr(T)} style="zoom:${(1 / k).toFixed(4)}">${t}</div>`;
      const pf = focusFor(fr.pairFocus, target) || [];
      // pairNudge: { back: [dx, dy], front: [dx, dy] } in design px, per target.
      const nudge = fr.pairNudge?.[target] || fr.pairNudge?.[like(target)];
      const nb = nudge?.back || [0, 0], nf = nudge?.front || [0, 0];
      const dev = (p, rot, t, f) =>
        device(shape, platePath(target, p), `left:0;top:0;width:calc(1128*var(--u));transform:perspective(calc(5200*var(--u))) rotateY(${rot}deg) rotateX(3deg)`, tag(t), f);
      body = `<div class="p-body" style="top:var(--panel-top);left:calc(40*var(--u));right:calc(40*var(--u))">
        ${scaled(u, nb[0], nb[1], k, dev(a, 9, c.labelA, pf[0]))}
        ${scaled(u, 1240 - 744 + nf[0], 340 + nf[1], k, dev(b, -9, c.labelB, pf[1]))}
      </div>`;
      break;
    }
    case "duo": {
      // The Mac (always the Mac plate) behind, the phone/pad in front, the Wi-Fi pill between.
      // Geometry is design px inside .p-body (left:0;right:0); the iPad canvas is only ~1760
      // design px tall, so its pair sits higher and smaller (DUO_PORTRAIT).
      const g = DUO_PORTRAIT[target] || DUO_PORTRAIT[like(target)];
      const mac = device("laptop", platePath("mac", fr.mac), `left:0;top:0;width:calc(1900*var(--u));transform:perspective(calc(6000*var(--u))) rotateY(10deg) rotateX(4deg)`, "", fr.macFocus);
      const small = device(shape, platePath(target, fr.phone), `left:0;top:0;width:calc(1128*var(--u))`, "", focusFor(fr.phoneFocus, target));
      body = `<div class="p-body" style="top:var(--panel-top);left:0;right:0;height:calc(1700*var(--u))">
        ${scaled(u, g.mac[0], g.mac[1], g.mac[2] / 1900, mac)}
        ${scaled(u, g.dev[0], g.dev[1], g.dev[2] / 1128, small)}
        ${c.link ? `<div class="duo-link"${dirAttr(T)} style="left:calc(${g.link[0]}*var(--u));top:calc(${g.link[1]}*var(--u))">${c.link}</div>` : ""}
      </div>`;
      break;
    }
    case "top-grid": {
      const tiles = fr.plates
        .map((p, i) => {
          // RTL reads the grid from the top right (QA r3: ar-SA met the Gecko before the Fox).
          const col = T.dir === "rtl" ? 1 - (i % 2) : i % 2,
            row = Math.floor(i / 2);
          // tilePlateFocus: { <target>: { <plate>: focus } } overrides tileFocus for one creature.
          const tf = (fr.tilePlateFocus?.[target] || fr.tilePlateFocus?.[like(target)])?.[p] || focusFor(fr.tileFocus, target);
          // Rows split whatever is left under the type block (2026-10-22 QA: fixed 740u rows
          // ran off the ~1760u iPad canvas and lost two labels, and left a quarter of the
          // iPhone canvas empty). The body ends 80u above the canvas bottom.
          return `<div class="panel tile" style="left:${col * 51.5}%;width:48.5%;top:calc(${row} * (50% + 10*var(--u)));height:calc(50% - 10*var(--u))">
          <div class="tile-label"${dirAttr(T)}>${c.tiles[i]}</div>${img(platePath(target, p), tf)}</div>`;
        })
        .join("");
      body = `<div class="p-body" style="top:var(--panel-top);bottom:calc(80*var(--u))">${tiles}</div>`;
      break;
    }
    case "stat":
      body = `<div class="p-body" style="top:var(--panel-top)">${device(shape, platePath(target, fr.plate), "left:0;width:100%", "", focusFor(fr.focus, target))}</div>`;
      break;
    default:
      throw new Error(`unknown portrait layout ${fr.layout}`);
  }
  const statHead =
    fr.layout === "stat"
      ? `<div class="p-head"${dirAttr(T)}>
      <div class="eyebrow"><span>${c.eyebrow}</span></div>
      <div style="display:flex;align-items:center;gap:calc(48*var(--u));margin-top:calc(20*var(--u))">
        <div class="big">${c.big}</div><div class="bigunit">${c.bigUnit}</div></div>
      <h1 style="font-size:calc(${TITLE === "pixel" ? 136 : 92}*var(--u)*var(--sh1))">${c.h1}</h1>
      <p class="sub">${c.sub}</p>
      <div class="corner">${c.corner}</div></div>`
      : head(c, fr, T);
  const lifts = liftsFor(fr, target).map((L) => lift(target, L, fr.plate || (fr.plates || [])[0])).join("");
  return `<div class="stage${fr.billboard ? " bb" : ""}">${atmosphere}${statHead}${body}${lifts}<div class="grain"></div><div class="crt"></div></div>`;
}

// Duo geometry, design px: [x, y, width] for the Mac and the phone/pad, [x, y] for the pill.
// Tuned by eye from the audit's start (2026-10-22): the laptop fully on canvas, the phone over
// its lower-right corner, the pill under the laptop beside the phone. iPad's canvas is 1760 design px tall, so the pair shrinks.
// 2026-10-22 QA round 1: the Mac screen showed only the Brain at Home header + label
// (a macFocus band, retired 2026-11-25: the whole pane now), so the phone/pad moves down over the laptop's lower-right
// corner instead of over screen text, and the pill sits in the gap between the two.
// QA r5 (1.2.1 brain-at-home plates): the pairing sheet is the top ~51% of the iPhone plate and
// ~28% of the iPad's, so at the old sizes (470 / 400 wide, wholly on canvas) the device read as a
// near-blank slab. It is now larger and runs off the canvas's right and bottom edges, the way the
// `top` layout bleeds: what shows is the sheet, its text whole (iPhone to plate x≈1070, iPad
// ≈1435), the cards' right ends past the edge. Still over the laptop's lower-right corner.
const DUO_PORTRAIT = {
  ios: { mac: [90, 0, 1170], dev: [560, 640, 800], link: [150, 850] }, // QA r2: laptop ≥30px off the left edge
  ipad: { mac: [60, 0, 980], dev: [600, 380, 900], link: [160, 690] },
};
const DUO_LANDSCAPE = { mac: [1240, 250, 1440], dev: [2330, 620, 420], link: [1700, 1290] };

function landscape(target, fr, c, T, W, H, u) {
  // The field clears behind the type column (left) and runs full behind the laptop.
  const atmosphere = lifeLayer(W, H, u, fr.id, { cx: W * 0.2, cy: H * 0.5, rx: W * 0.34, ry: H * 0.62, floor: 0.16 });
  const col = (extra = "") => `<div class="l-col"${dirAttr(T)}>
      <div class="eyebrow"><span>${c.eyebrow}</span></div>
      <h1${h1Style(fr)}>${c.h1}</h1>${c.sub ? `<p class="sub">${c.sub}</p>` : ""}
      ${c.chips ? `<div class="chips">${c.chips.map((x) => `<span class="chip">${x}</span>`).join("")}</div>` : ""}
      ${c.corner ? `<div class="corner">${c.corner}</div>` : ""}${extra}</div>`;
  let inner = "";
  switch (fr.layout) {
    case "edge":
    case "split":
      inner = `${atmosphere}${col()}${device("laptop", platePath(target, fr.plate), "left:calc(1250*var(--u));top:calc(390*var(--u));width:calc(1540*var(--u))", "", fr.focus)}`;
      break;
    case "grid": {
      const tiles = fr.plates
        .map((p, i) => {
          const cx = i % 2,
            r = Math.floor(i / 2);
          return `<div class="panel tile" style="left:calc(${1380 + cx * 730}*var(--u));top:calc(${447 + r * 468}*var(--u));width:calc(700*var(--u));height:calc(438*var(--u))">
          <div class="tile-label"${dirAttr(T)}>${c.tiles[i]}</div><img src="file://${platePath(target, p)}"></div>`;
        })
        .join("");
      inner = `${atmosphere}${col()}${tiles}`;
      break;
    }
    case "duo":
      // The laptop from the Mac plate, the phone from plates/ios (the Mac listing shows both).
      inner = `${atmosphere}${col()}
        ${scaled(u, DUO_LANDSCAPE.mac[0], DUO_LANDSCAPE.mac[1], DUO_LANDSCAPE.mac[2] / 1900, device("laptop", platePath(target, fr.mac), "left:0;top:0;width:calc(1900*var(--u))", "", fr.macFocus))}
        ${scaled(u, DUO_LANDSCAPE.dev[0], DUO_LANDSCAPE.dev[1], DUO_LANDSCAPE.dev[2] / 1128, device("phone", platePath("ios", fr.phone), "left:0;top:0;width:calc(1128*var(--u))", "", fr.phoneFocus))}
        ${c.link ? `<div class="duo-link"${dirAttr(T)} style="left:calc(${DUO_LANDSCAPE.link[0]}*var(--u));top:calc(${DUO_LANDSCAPE.link[1]}*var(--u))">${c.link}</div>` : ""}`;
      break;
    case "stat":
      inner = `${atmosphere}<div class="l-col"${dirAttr(T)} style="width:calc(1180*var(--u))">
        <div class="eyebrow"><span>${c.eyebrow}</span></div>
        <div style="display:flex;align-items:center;gap:calc(48*var(--u));margin-top:calc(10*var(--u))">
          <div class="big" style="font-size:calc(460*var(--u))">${c.big}</div><div class="bigunit">${c.bigUnit}</div></div>
        <h1 style="font-size:calc(${TITLE === "pixel" ? 140 : 96}*var(--u))">${c.h1}</h1><p class="sub">${c.sub}</p>
        <div class="corner">${c.corner}</div></div>
        ${device("laptop", platePath(target, fr.plate), "left:calc(1360*var(--u));top:calc(430*var(--u));width:calc(1430*var(--u))", "", fr.focus)}`;
      break;
    default:
      throw new Error(`unknown landscape layout ${fr.layout}`);
  }
  const lifts = liftsFor(fr, target).map((L) => lift(target, L, fr.plate || (fr.plates || [])[0])).join("");
  return `<div class="stage${fr.billboard ? " bb" : ""}">${inner}${lifts}<div class="grain"></div><div class="crt"></div></div>`;
}

// iPhone Duo (Kev, 2026-11-03: "simple whole screen"): the type block and the WHOLE capture in a Duo
// frame. No lifts, no crops, no pairs: the iPhone's frames and copy, one plate per frame. The
// iPhone/iPad sets crop and lift by plate pixel, measured per device over six QA rounds; a Duo
// plate is a different shape, so it shows the screen as the app drew it.
const SIMPLE_FALLBACK = { "ask-documents": "documents" };
function simplePlate(target, fr) {
  const want = fr.plate || fr.phone || (fr.plates || [])[0];
  const has = (n) => fs.existsSync(path.join(PLATES, target, `${n}.png`));
  return !has(want) && SIMPLE_FALLBACK[want] && has(SIMPLE_FALLBACK[want]) ? SIMPLE_FALLBACK[want] : want;
}
function simple(target, fr, c, T, W, H, u, orient) {
  const shape = TARGETS[target].shape;
  const dev = (style) => device(shape, platePath(target, simplePlate(target, fr)), style);
  const big = c.big
    ? `<div style="display:flex;align-items:center;gap:calc(40*var(--u));margin-top:calc(16*var(--u))"><div class="big">${c.big}</div><div class="bigunit">${c.bigUnit}</div></div>`
    : "";
  const type = (cls, style) => `<div class="${cls}"${dirAttr(T)} style="${style}">
    <div class="eyebrow"><span>${c.eyebrow}</span></div>${big}
    <h1${h1Style(fr)}>${c.h1}</h1>${c.sub ? `<p class="sub">${c.sub}</p>` : ""}</div>`;
  if (orient === "portrait") {
    const atmosphere = lifeLayer(W, H, u, fr.id, portraitClear(fr, W, H));
    // The type block sets its own height; the device takes what is left, whole, centred.
    return `<div class="stage">${atmosphere}
      <div style="position:absolute;inset:0;display:flex;flex-direction:column;padding:calc(150*var(--u)) calc(96*var(--u)) calc(80*var(--u));z-index:5">
        ${type("p-head", "position:relative;left:auto;right:auto;top:auto")}
        <div style="flex:1;position:relative;min-height:0;margin-top:calc(70*var(--u))">
          ${dev("top:0;bottom:0;left:50%;transform:translateX(-50%) perspective(calc(5200*var(--u))) rotateY(-5deg);transform-origin:50% 50%")}
        </div>
      </div><div class="grain"></div><div class="crt"></div></div>`;
  }
  const atmosphere = lifeLayer(W, H, u, fr.id, { cx: W * 0.2, cy: H * 0.5, rx: W * 0.34, ry: H * 0.62, floor: 0.16 });
  return `<div class="stage">${atmosphere}${type("l-col", "width:calc(1020*var(--u))")}
    <div style="position:absolute;left:calc(1250*var(--u));right:calc(110*var(--u));top:0;bottom:0;z-index:4">
      ${dev("left:0;width:100%;top:50%;transform:translateY(-50%) perspective(calc(6000*var(--u))) rotateY(-8deg);transform-origin:50% 50%")}
    </div><div class="grain"></div><div class="crt"></div></div>`;
}

// What each layout reads from the copy. A missing or empty field throws before anything
// renders: no "undefined" on a store frame, no silent English fallback.
const NEEDS = {
  top: ["eyebrow", "h1"],
  "top-pair": ["eyebrow", "h1", "labelA", "labelB"],
  "top-grid": ["eyebrow", "h1", "tiles"],
  grid: ["eyebrow", "h1", "tiles"],
  stat: ["eyebrow", "big", "bigUnit", "h1", "sub", "corner"],
  duo: ["eyebrow", "h1", "sub", "link"],
  edge: ["eyebrow", "h1"],
  split: ["eyebrow", "h1"],
};
const framesFor = (target) =>
  (TARGETS[target].orient === "portrait" || TARGETS[target].frames === "portrait" ? PORTRAIT : LANDSCAPE).filter(
    (fr) => !fr.targets || fr.targets.includes(target) || fr.targets.includes(like(target)),
  );
function copyFor(target, locale, fr) {
  if (!COPY[locale]) throw new Error(`strings.js: no COPY for ${locale}`);
  if (!TYPE[locale]) throw new Error(`strings.js: no TYPE for ${locale}`);
  let c = { ...COPY[locale][fr.id] };
  if (target === "mac" && MAC_OVERRIDES[locale]?.[fr.id])
    c = { ...c, ...MAC_OVERRIDES[locale][fr.id] };
  if (target === "ipad" && IPAD_OVERRIDES[locale]?.[fr.id])
    c = { ...c, ...IPAD_OVERRIDES[locale][fr.id] };
  return c;
}
function checkCopy(targets, locales) {
  const bad = [];
  for (const target of targets)
    for (const locale of locales)
      for (const fr of framesFor(target)) {
        let c;
        try {
          c = copyFor(target, locale, fr);
        } catch (e) {
          bad.push(e.message);
          continue;
        }
        if (!NEEDS[fr.layout]) bad.push(`${target}/${fr.id}: unknown layout "${fr.layout}"`);
        for (const k of NEEDS[fr.layout] || []) {
          const v = c[k];
          const empty = v == null || v === "" || (Array.isArray(v) && (v.length < (fr.plates || []).length || v.some((x) => !x)));
          if (empty) bad.push(`${target}/${locale}/${fr.id}: missing "${k}"`);
        }
        for (const [k, v] of Object.entries(c))
          if (/undefined/.test(JSON.stringify(v))) bad.push(`${target}/${locale}/${fr.id}: "${k}" contains "undefined"`);
      }
  if (bad.length) throw new Error(`copy check failed (${bad.length}):\n  ${bad.join("\n  ")}`);
}

// ─── main ─────────────────────────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);
  const targets =
    args[0] && TARGETS[args[0]] ? [args[0]] : Object.keys(TARGETS);
  const rest = args[0] && TARGETS[args[0]] ? args.slice(1) : args;
  const locales = rest.find((a) => LOCALES.includes(a))
    ? [rest.find((a) => LOCALES.includes(a))]
    : LOCALES;
  const only = rest.find((a) => /^\d\d[a-z]?$/.test(a));
  checkCopy(targets, locales);

  // mask.py + flatten.py need Pillow. Default: uv supplies it (no venv to make); M1K3_PY overrides.
  const hasUv = (() => { try { execFileSync("uv", ["--version"], { stdio: "ignore" }); return true; } catch { return false; } })();
  const [py, ...pyArgs] = (process.env.M1K3_PY || (hasUv ? "uv run --quiet --with pillow python3" : "python3")).split(/\s+/);
  // M1K3_FONTREPORT=<file.json> records the faces Chrome actually used per text role.
  const fontReport = process.env.M1K3_FONTREPORT ? {} : null;

  // Retouched plate copies (frames.js PLATE_MASKS → mask.py → out/.plates), every target:
  // a duo draws the Mac plate on iPhone/iPad and the iPhone plate on the Mac.
  const jobs = Object.entries(PLATE_MASKS).flatMap(([t, plates]) =>
    Object.entries(plates).map(([name, masks]) => ({ src: path.join(PLATES, t, `${name}.png`), dst: path.join(MASKED, t, `${name}.png`), masks })),
  );
  if (jobs.length) execFileSync(py, [...pyArgs, path.join(ROOT, "mask.py"), JSON.stringify(jobs)], { stdio: "inherit" });

  const browser = await chromium.launch(LAUNCH);
  for (const target of targets) {
    const { w: W, h: H, orient } = TARGETS[target];
    const u = orient === "portrait" ? W / 1320 : W / 2880;
    const frames = framesFor(target);
    for (const locale of locales) {
      const outDir = path.join(OUT, target, locale);
      fs.mkdirSync(outDir, { recursive: true });
      // A full render owns the folder: drop PNGs of frames that no longer exist (v1 ids),
      // so the set on disk is exactly the frame list (Apple's limit is 10).
      if (!only) {
        const keep = new Set(frames.map((fr) => `${fr.id}.png`));
        for (const f of fs.readdirSync(outDir))
          if (f.endsWith(".png") && !keep.has(f)) fs.unlinkSync(path.join(outDir, f));
      }
      const T = TYPE[locale];
      const page = await browser.newPage({
        viewport: { width: W, height: H },
        deviceScaleFactor: 1,
      });
      const cdp = fontReport ? await page.context().newCDPSession(page) : null;
      const written = [];
      const manifestFile = path.join(outDir, ".plates.json");
      const manifest = only && fs.existsSync(manifestFile) ? JSON.parse(fs.readFileSync(manifestFile, "utf8")) : {};
      // Gone until this locale finishes: a render that throws leaves no manifest (verify fails), never a stale one.
      fs.rmSync(manifestFile, { force: true });
      for (const fr of frames) {
        if (only && !fr.id.startsWith(only)) continue;
        USED = new Set();
        const c = prepCopy(copyFor(target, locale, fr));
        const html = TARGETS[target].simple
          ? simple(target, fr, c, T, W, H, u, orient)
          : orient === "portrait"
            ? portrait(target, fr, c, T, W, H, u)
            : landscape(target, fr, c, T, W, H, u);
        // Written to disk and opened as file:// so fonts + plates (also file://) load;
        // setContent() would be about:blank and Chromium blocks file:// from there.
        const tmp = path.join(outDir, `.${fr.id}.html`);
        fs.writeFileSync(
          tmp,
          `<!doctype html><html lang="${locale}"><head><meta charset="utf-8"><style>${CSS(W, H, u, orient, T)}</style></head><body>${html}</body></html>`,
        );
        await page.goto(`file://${tmp}`);
        await page.evaluate(() => document.fonts.ready);
        // Headline lines are set by hand (<br>); a line that wraps on its own adds a line the
        // copy never had (Plex Mono for ru is ~1.4× VT323's advance). Shrink that h1 in 2%
        // steps until it has exactly its authored lines, and say so in the log.
        // Headline fit, installed once per page so the lift-collision pass can re-run it.
        await page.evaluate(() => {
          window.__fit = () => {
            const out = [];
            for (const h of document.querySelectorAll("h1")) {
              const want = h.querySelectorAll("br").length + 1;
              const lines = () => {
                const lh = parseFloat(getComputedStyle(h).lineHeight) || parseFloat(getComputedStyle(h).fontSize) * 0.84;
                return Math.round(h.getBoundingClientRect().height / lh);
              };
              const size0 = parseFloat(getComputedStyle(h).fontSize);
              let size = size0;
              while (lines() > want && size > size0 * 0.5) {
                size *= 0.98;
                h.style.fontSize = `${size}px`;
              }
              if (size !== size0) out.push(`h1 ${size0.toFixed(0)}→${size.toFixed(0)}px`);
            }
            return out;
          };
        });
        const fit = await page.evaluate(() => window.__fit());
        if (fit.length) console.log(`  fit ${target}/${locale}/${fr.id}: ${fit.join(", ")}`);
        if (orient === "portrait") {
          // panel starts a fixed gap under the type block, wherever it ends.
          await page.evaluate(() => {
            const h = document
              .querySelector(".p-head")
              .getBoundingClientRect().bottom;
            const u = parseFloat(
              getComputedStyle(document.documentElement).getPropertyValue(
                "--u",
              ),
            );
            document
              .querySelectorAll(".p-body")
              .forEach((b) => (b.style.top = `${h + 88 * u}px`));
          });
        }
        await page.evaluate(() =>
          Promise.all(
            [...document.images].map((i) => i.decode().catch(() => {})),
          ),
        );
        await page.evaluate(anchorLifts);
        const moved = await page.evaluate(clearLifts);
        if (moved.length) console.log(`  lift-clear ${target}/${locale}/${fr.id}: ${moved.join(", ")}`);
        if (orient === "portrait") {
          // Regenerate the field with the measured type boxes as keep-outs (see life.js).
          const boxes = await page.evaluate(textBoxes);
          const pad = 16 * u;
          const keepout = boxes.map(([x0, y0, x1, y1]) => ({ x0: x0 - pad, y0: y0 - pad, x1: x1 + pad, y1: y1 + pad, fade: 70 * u, floor: 0.04 }));
          const svg = lifeSVG(W, H, { pitch: 34 * u, seed: seedFor(fr.id), density: 0.2, generations: 90, clear: portraitClear(fr, W, H), keepout });
          await page.evaluate((svg) => {
            document.querySelector("svg.life").outerHTML = svg;
          }, svg);
        }
        if (cdp) await recordFonts(cdp, fontReport, locale, `${target}/${fr.id}`);
        const out = path.join(outDir, `${fr.id}.png`);
        await page.screenshot({ path: out, type: "png" });
        written.push(out);
        manifest[fr.id] = Object.fromEntries([...USED].sort().map((id) => [id, plateHashes(id)]));
        USED = null;
        if (!process.env.M1K3_KEEPHTML) fs.unlinkSync(tmp);
        console.log(`✓ ${target}/${locale}/${fr.id}.png  ${W}×${H}`);
      }
      if (written.length)
        execFileSync(py, [...pyArgs, path.join(ROOT, "flatten.py"), ...written]);
      fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 1) + "\n");
      await page.close();
    }
  }
  await browser.close();
  if (fontReport) {
    fs.writeFileSync(process.env.M1K3_FONTREPORT, JSON.stringify(fontReport, null, 1));
    console.log(`fonts → ${process.env.M1K3_FONTREPORT}`);
  }
}

// ─── page-side passes (run inside Chromium via page.evaluate) ────────────────
// A lift with data-anchor is centred over its own crop as drawn on the first device screen
// (bounding box of the transformed image; the perspective tilt is a few degrees, and a
// lift is drawn larger than its source, so it still covers it). dx/dy nudge, minX/margin clamp.
function anchorLifts() {
  const W = innerWidth, H = innerHeight;
  const u = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--u"));
  const ims = document.querySelectorAll(".device .screen img");
  if (!ims.length) return;
  for (const L of document.querySelectorAll(".lift[data-anchor]")) {
    const a = JSON.parse(L.dataset.anchor);
    // a.img: which screen image to map through (a banded screen has one per band).
    const im = ims[a.img || 0];
    const [cx, cy, cw, ch] = a.crop;
    const r = im.getBoundingClientRect();
    const cs = getComputedStyle(im);
    const sw = im.offsetWidth, sh = im.offsetHeight;
    let map;
    if (cs.objectFit === "cover") {
      const s = Math.max(sw / a.pw, sh / a.ph);
      const [fx, fy] = cs.objectPosition.split(" ").map((v) => parseFloat(v) / 100);
      const ox = (sw - a.pw * s) * fx, oy = (sh - a.ph * s) * fy;
      map = (x, y) => [r.left + ((ox + x * s) * r.width) / sw, r.top + ((oy + y * s) * r.height) / sh];
    } else map = (x, y) => [r.left + (x * r.width) / a.pw, r.top + (y * r.height) / a.ph];
    const [x0, y0] = map(cx, cy), [x1, y1] = map(cx + cw, cy + ch);
    const w = L.offsetWidth, h = L.offsetHeight;
    const m = (a.margin ?? 40) * u;
    let left = (x0 + x1) / 2 - w / 2 + (a.dx || 0) * u;
    let top = (y0 + y1) / 2 - h / 2 + (a.dy || 0) * u;
    left = Math.min(Math.max(left, a.minX != null ? a.minX * u : m), W - m - w);
    top = Math.min(Math.max(top, 0), H - h - m); // QA r2: a lift flush on the canvas bottom read as clipped
    L.style.left = `${left}px`;
    L.style.top = `${top}px`;
  }
}
// Mac columns: no caption line may run under a lift (QA: de 06's sub lost its last "r.",
// ru 06's h1 lost its full stop). A colliding sub/corner gets a max-width that ends 40u
// before the lift; a colliding h1 steps down 3%; an RTL column (right-aligned) narrows.
function clearLifts() {
  const u = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--u"));
  const m = 40 * u;
  const lifts = [...document.querySelectorAll(".lift")].map((l) => l.getBoundingClientRect());
  const col = document.querySelector(".l-col");
  const log = [];
  if (!lifts.length || !col) return log;
  const hit = (el) => {
    const rg = document.createRange();
    rg.selectNodeContents(el);
    let best = null;
    for (const t of rg.getClientRects())
      for (const L of lifts)
        if (t.width > 0 && t.right > L.left - m && t.left < L.right && t.bottom > L.top - 10 * u && t.top < L.bottom)
          if (!best || L.left < best.left) best = L;
    return best;
  };
  const rtl = col.getAttribute("dir") === "rtl";
  for (let pass = 0; pass < 12; pass++) {
    let any = false;
    for (const el of col.querySelectorAll("h1, .sub, .corner")) {
      const L = hit(el);
      if (!L) continue;
      any = true;
      if (rtl) {
        const c = col.getBoundingClientRect();
        col.style.setProperty("width", `${L.left - m - c.left}px`, "important");
        log.push(`col→${((L.left - m - c.left) / u).toFixed(0)}u`);
        window.__fit();
      } else if (el.tagName === "H1") {
        const fs = parseFloat(getComputedStyle(el).fontSize) * 0.97;
        el.style.fontSize = `${fs}px`;
        log.push(`h1→${(fs / u).toFixed(0)}u`);
      } else {
        const mw = L.left - m - el.getBoundingClientRect().left;
        el.style.maxWidth = `${mw}px`;
        log.push(`${el.className}→${(mw / u).toFixed(0)}u`);
      }
    }
    if (!any) break;
  }
  return [...new Set(log)];
}
// Every line box of type in the portrait head, in canvas px (for the Life keep-outs).
function textBoxes() {
  const out = [];
  for (const el of document.querySelectorAll(".p-head :is(.eyebrow span, h1, .sub, .corner, .bigunit, .big, .chip)")) {
    const rg = document.createRange();
    rg.selectNodeContents(el);
    for (const r of rg.getClientRects()) if (r.width > 0) out.push([r.left, r.top, r.right, r.bottom]);
    if (el.classList.contains("big")) {
      const r = el.getBoundingClientRect();
      out.push([r.left, r.top, r.right, r.bottom]);
    }
  }
  return out;
}

// Which platform fonts rendered each text role (CSS.getPlatformFontsForNode, per text node).
// A role drawing from a face we didn't ask for is a glyph fallback.
const ROLES = { h1: "h1", eyebrow: ".eyebrow span", sub: ".sub", corner: ".corner", bigunit: ".bigunit", big: ".big", tag: ".tag", tile: ".tile-label", link: ".duo-link" };
async function recordFonts(cdp, report, locale, frame) {
  await cdp.send("DOM.enable");
  await cdp.send("CSS.enable");
  const { root } = await cdp.send("DOM.getDocument", { depth: -1 });
  const loc = (report[locale] ||= {});
  for (const [role, sel] of Object.entries(ROLES)) {
    const { nodeIds } = await cdp.send("DOM.querySelectorAll", { nodeId: root.nodeId, selector: `${sel}, ${sel} *` });
    for (const nodeId of nodeIds) {
      const { fonts } = await cdp.send("CSS.getPlatformFontsForNode", { nodeId });
      for (const f of fonts) {
        const key = `${role}: ${f.familyName}${f.isCustomFont ? " (web)" : ""}`;
        const e = (loc[key] ||= { glyphs: 0, frames: [] });
        e.glyphs += f.glyphCount;
        if (!e.frames.includes(frame)) e.frames.push(frame);
      }
    }
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
