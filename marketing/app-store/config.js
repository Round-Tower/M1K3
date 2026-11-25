// M1K3 — App Store screenshot system: canvas + brand tokens.
// One system, three targets. Everything scales off `unit` so a frame designed
// at 1320 wide lays out identically at 2064 or 2880.

const path = require("path");

const ROOT = __dirname;

const TARGETS = {
  // Apple spec sizes (developer.apple.com → App Store Connect → screenshot specifications).
  // iPhone 6.9": 1320×2868 (17 Pro Max / 16 Pro Max). Also accepted: 1290×2796, 1260×2736.
  ios:  { w: 1320, h: 2868, orient: "portrait",  dir: "ios",  label: "iPhone 6.9\"" },
  // iPad 13": 2064×2752 (also 2048×2732).
  ipad: { w: 2064, h: 2752, orient: "portrait",  dir: "ipad", label: "iPad 13\"" },
  // Mac: 2880×1800 (also 2560×1600, 1440×900, 1280×800). 16:10.
  mac:  { w: 2880, h: 1800, orient: "landscape", dir: "mac",  label: "Mac" },
  // iPhone Duo (Apple's foldable, 2026-10-23): inner 2007×2853, outer 1398×2034. Both screens are ~0.70
  // wide, iPad-shaped, so they take the iPad's layout geometry (`like`) and the iPhone's copy (it IS an
  // iPhone; the iPad overrides say "iPad"). Submitting either earns the "optimized for iPhone Duo" badge.
  // Kev, 2026-11-03: the Duo sets are `simple` (render.js simple()): the whole screen in a Duo frame,
  // the iPhone's frames and copy. The inner screen is landscape-native (2853×2007; Apple takes either).
  duo:         { w: 2853, h: 2007, orient: "landscape", frames: "portrait", dir: "duo", label: "iPhone Duo (inner)", like: "ios", shape: "foldwide", simple: true },
  "duo-outer": { w: 1398, h: 2034, orient: "portrait", dir: "duo-outer", label: "iPhone Duo (outer)", like: "ios", shape: "foldout", simple: true },
};

// Native capture sizes we expect in plates/<target>/ (what the device itself produces).
// Any size works — plates are object-fit: cover inside the panel — but these are the
// ones that need no scaling in the "edge" (full-bleed) layout.
const PLATE_NATIVE = {
  ios:  { w: 1320, h: 2868 },
  ipad: { w: 2064, h: 2752 },
  mac:  { w: 2880, h: 1800 },
  duo:  { w: 2853, h: 2007 },
  "duo-outer": { w: 1398, h: 2034 },
};

const BRAND = {
  bg: "#050505",             // site --bg
  ink: "#e8e8e8",
  inkBright: "#ffffff",
  inkDim: "#8a8a8a",         // "Nothing leaves." grey
  inkFaint: "#4a4a4a",
  line: "rgba(232,232,232,0.10)",
  glow: "0 0 2px #fff, 0 0 12px rgba(255,255,255,0.35)",
  fonts: {
    mono:  path.join(ROOT, "node_modules/@fontsource/ibm-plex-mono/files"),
    pixel: path.join(ROOT, "node_modules/@fontsource/vt323/files"),
    sans:  path.join(ROOT, "node_modules/@fontsource/inter/files"),
  },
};

const OUT = path.join(ROOT, "out");
const PLATES = path.join(ROOT, "plates");

module.exports = { TARGETS, PLATE_NATIVE, BRAND, OUT, PLATES, ROOT };
