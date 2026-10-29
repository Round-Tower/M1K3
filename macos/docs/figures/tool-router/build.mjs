// Fig 1 · The tool router as a sorting bench.
// Truth: macos/Sources/M1K3Chat/ToolNeedRouter.swift, ToolGroupRouter.swift and their *Weights.swift.
//   gate:  logistic over Apple's 512-d sentence vector, tools when P >= 0.322468998; no score -> tools (fails open)
//   head:  softmax over [none, device, knowledge, web, activity, script], dispatch when top >= 0.76337048,
//          never for web (egress) or script (actions), never on `none`; anything else abstains to Apple's pick / the agent
//   cost:  plain chat median 13.4 s vs 51.5 s with the palette (2026-09-26, Mini, 22 fixtures)
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ANATOMY = process.env.ANATOMY;
const k = await import(join(ANATOMY, "kit/iso-kit.mjs"));
const { kitScript } = await import(join(ANATOMY, "scripts/inline-kit.mjs"));

const HERE = dirname(fileURLToPath(import.meta.url));
const theme = process.argv.includes("--light") ? "light" : "dark";

const GATE = 0.322468998;
const FLOOR = 0.76337048;

const WIDTH = 640;
const HEIGHT = 420;

const PLATE = { x: -176, y: -74, w: 352, d: 148, r: 9 };
const PLATE_H = 12;
const FOOT_H = 5;

const TRACK = { x: -150, y: -9, w: 268, d: 18, r: 3 };
const TOKEN_R = 6.6;
const TOKEN_H = 4;
const INLET_X = -146;
const GATE_X = -100;
const END_X = 136;

const RAIL = { x: -132, y: -31, w: 252, d: 6, r: 1.2 };
const RAIL_H = 6;
const CAR = { w: 26, d: 16 };
const CAR_Y = -36;
const CAR_Z = RAIL_H;
const CAR_H = 7;
const BRACKET = { x: -6, y: -20, w: 12, d: 4, r: 0.8 };
const RAM_W = 9;
const RAM_Z = 1.2;
const RAM_H = 3.4;
const RAM_REST = 4.6;

const TRAY_Y = 27;
const TRAY_D = 26;
const TRAYS = [
  { name: "chat", x: -126, w: 52 },
  { name: "device", x: -58, w: 25 },
  { name: "knowledge", x: -28, w: 25 },
  { name: "activity", x: 2, w: 25 },
  { name: "web", x: 32, w: 25, shut: true },
  { name: "script", x: 62, w: 25, shut: true },
];
const END = { x: 122, y: -15, w: 40, d: 30, r: 3 };

const DIALS = [
  { at: [-100, -56], mark: GATE },
  { at: [42, -56], mark: FLOOR },
];
const DIAL_R = 19;
const DIAL_Z = 62;
const DIAL_H = 9;
const DIAL_TOP = DIAL_Z + DIAL_H;
// The dead quarter of each dial faces the viewer (azimuth 40°), so 0 sits lower left and 1 lower right.
const SWEEP_FROM = Math.atan2(Math.cos((40 * Math.PI) / 180), -Math.sin((40 * Math.PI) / 180)) + 0.25 * Math.PI;
const SWEEP = 1.5 * Math.PI;

const P = k.fitProjection(
  [...k.boxCorners(PLATE, -PLATE_H - FOOT_H, 0), ...DIALS.map((d) => [d.at[0], d.at[1] - DIAL_R, DIAL_TOP + 2]), [INLET_X - 12, 0, 44]],
  WIDTH,
  HEIGHT,
  { pad: 26, azimuth: 40 },
);

const at = (point) => k.iso(point, P);
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));
const trayCentre = (tray) => tray.x + tray.w / 2;

function plate() {
  const out = [`<path class="iso-halo" d="${k.haloOf(PLATE, -PLATE_H - FOOT_H, PLATE_H, P)}"/>`];
  for (const [x, y] of byDepth(k.corners(PLATE, 24))) {
    out.push(S(k.cylinder(x, y, 7.4, -PLATE_H - FOOT_H, 1.6, P, 28), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 5.6, -PLATE_H - FOOT_H + 1.6, FOOT_H - 1.6, P, 28), { tone: "mid" }));
  }
  out.push(S(k.slabOf(PLATE, -PLATE_H, PLATE_H, P, 8, 1.6), { tone: "mid", inner: L(k.sideSeam(PLATE, -5, P, 8), { tone: "faint" }) }));
  out.push(L(k.planOutline(k.insetPlan(PLATE, 5), 0, P), { tone: "lo" }));
  const screws = k.corners(PLATE, 10);
  out.push(L(screws.map(([x, y]) => k.ring(x, y, 2.2, 0, P, 16)).join(""), { tone: "lo" }));
  out.push(D(screws.map(([x, y]) => at([x, y, 0])), { size: 0.5 }));

  // Ruler strip along the front edge: track position, 4 units a tick.
  const strip = { x: -150, y: PLATE.y + PLATE.d - 15, w: 300, d: 7, r: 1 };
  out.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 4, 5, strip.y + 0.8, 0.6, [2, 3.6], P);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  out.push(D([at([strip.x + 2, strip.y + 3.5, 0.6]), at([strip.x + strip.w - 2, strip.y + 3.5, 0.6])], { size: 0.45 }));

  // Label plate, back right: the one engraved word.
  const label = { x: 112, y: -66, w: 46, d: 22, r: 1.5 };
  out.push(S(k.slabOf(label, 0, 0.8, P, 4), { tone: "lo", crease: "none" }));
  out.push(L(k.planOutline(k.insetPlan(label, 1.6), 0.8, P, 4), { tone: "faint" }));
  out.push(k.faceTextSvg(k.topMatrix([label.x + 6, label.y + 9], 0.8, P, "x"), "M1K3", { size: 4.2, tone: "mid" }));
  for (const [dy, len] of [[13.5, 30], [16.5, 22], [19, 26]]) {
    out.push(L(k.lineOnTop([label.x + 6, label.y + dy], [label.x + 6 + len, label.y + dy], 0.8, P), { tone: "lo", free: true }));
  }
  out.push(D([at([label.x + label.w - 4, label.y + 4, 0.8]), at([label.x + label.w - 4, label.y + label.d - 4, 0.8])], { size: 0.45 }));
  return out.join("");
}

function track() {
  const out = [];
  out.push(S(k.slabOf(TRACK, 0, 0.5, P, 4), { tone: "lo", crease: "none", flat: true }));
  out.push(L(k.planOutline(k.insetPlan(TRACK, 2.4), 0.5, P, 4), { tone: "faint" }));
  // Station marks across the track: the gate and every tray mouth.
  for (const x of [GATE_X, ...TRAYS.slice(1).map(trayCentre)]) {
    out.push(L(k.lineOnTop([x, TRACK.y], [x, TRACK.y + TRACK.d], 0.5, P), { tone: "faint" }));
  }
  // Spur grooves from the track to every open tray.
  for (const tray of TRAYS.filter((t) => !t.shut)) {
    const cx = trayCentre(tray);
    for (const dx of [-TOKEN_R - 1, TOKEN_R + 1]) out.push(L(k.lineOnTop([cx + dx, TRACK.y + TRACK.d], [cx + dx, TRAY_Y], 0.02, P), { tone: "faint" }));
  }
  return out.join("");
}

function inlet() {
  const out = [];
  const base = { x: INLET_X - 14, y: -16, w: 22, d: 32, r: 2 };
  out.push(S(k.slabOf(base, 0, 6, P, 4, 0.6), { tone: "mid" }));
  const tube = [INLET_X - 4, 0];
  out.push(S(k.cylinder(tube[0], tube[1], 9.2, 6, 3, P, 40), { tone: "mid" }));
  out.push(S(k.cylinder(tube[0], tube[1], 8, 9, 30, P, 40), { tone: "hi", crease: "none", inner: L([18, 27].map((z) => k.sideArc(tube[0], tube[1], 8, z, P, 24)).join(""), { tone: "faint" }) }));
  out.push(S(k.cylinder(tube[0], tube[1], 9.4, 39, 3, P, 40, 0.6), { tone: "mid" }));
  out.push(L(k.ring(tube[0], tube[1], 7, 42, P, 40), { tone: "lo" }));
  // A stack of waiting turns seen in the mouth.
  out.push(S(k.cylinder(tube[0], tube[1], TOKEN_R, 42, 0.01, P, 32), { tone: "lo", crease: "none", flat: true }));
  out.push(D([at([base.x + 3, base.y + 3, 6]), at([base.x + 3, base.y + base.d - 3, 6]), at([base.x + base.w - 3, base.y + 3, 6])], { size: 0.45 }));
  return out.join("");
}

function rail() {
  const out = [];
  out.push(S(k.slabOf(RAIL, 0, RAIL_H, P, 3, 0.5), { tone: "mid", inner: L(k.sideSeam(RAIL, 2.4, P, 3), { tone: "faint" }) }));
  const ticks = k.topTicks(RAIL.x + 6, RAIL.x + RAIL.w - 6, 6, 5, RAIL.y + 0.6, RAIL_H, [1.4, 2.6], P);
  out.push(L(ticks.minor, { tone: "faint" }), L(ticks.major, { tone: "lo" }));
  for (const x of [RAIL.x - 6, RAIL.x + RAIL.w]) {
    out.push(S(k.slabOf({ x, y: RAIL.y - 4, w: 6, d: RAIL.d + 8, r: 1.2 }, 0, RAIL_H + 4, P, 3, 0.5), { tone: "mid" }));
    out.push(D([at([x + 3, RAIL.y - 1.5, RAIL_H + 4]), at([x + 3, RAIL.y + RAIL.d + 1.5, RAIL_H + 4])], { size: 0.45 }));
  }
  return out.join("");
}

// The carriage is built at x = 0 and moved along the rail.
function carriage() {
  const out = [];
  const body = { x: -CAR.w / 2, y: CAR_Y, w: CAR.w, d: CAR.d, r: 2.4 };
  out.push(`<path class="iso-halo" d="${k.haloOf(k.insetPlan(body, 2), CAR_Z, 0.1, P)}" style="filter:blur(3px)"/>`);
  for (const x of [-CAR.w / 2 + 2, CAR.w / 2 - 7]) out.push(S(k.slabOf({ x, y: CAR_Y + 2, w: 5, d: CAR.d - 4, r: 1 }, CAR_Z - 1.4, 1.4, P, 2), { tone: "lo" }));
  out.push(S(k.slabOf(body, CAR_Z, CAR_H, P, 4, 0.6), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(body, 2.6), CAR_Z + CAR_H, P, 4), { tone: "faint" }));
  out.push(D([[-9, CAR_Y + 3], [9, CAR_Y + 3], [-9, CAR_Y + CAR.d - 3], [9, CAR_Y + CAR.d - 3]].map(([x, y]) => at([x, y, CAR_Z + CAR_H])), { size: 0.45 }));
  // Drop bracket on the front face carries the ram down to the track.
  out.push(S(k.slabOf(BRACKET, RAM_Z - 0.4, CAR_Z + CAR_H - RAM_Z, P, 2, 0.4), { tone: "mid" }));
  out.push(D([at([0, BRACKET.y + 2, CAR_Z + CAR_H])], { size: 0.45 }));
  // Knurled feed knob on top.
  out.push(S(k.cylinder(0, CAR_Y + 7, 4.2, CAR_Z + CAR_H, 3.4, P, 28), { tone: "mid" }));
  out.push(L(k.knurl(0, CAR_Y + 7, 4.2, CAR_Z + CAR_H, CAR_Z + CAR_H + 3.4, 26, P), { tone: "lo" }));
  out.push(L(k.lineOnTop([0, CAR_Y + 7], [0, CAR_Y + 3.4], CAR_Z + CAR_H + 3.4, P), { tone: "hi" }));
  return out.join("");
}

const ramPaths = (reach) => k.slabOf({ x: -RAM_W / 2, y: BRACKET.y + BRACKET.d, w: RAM_W, d: reach, r: 1 }, RAM_Z, RAM_H, P, 2, 0.3);

function tray(t) {
  const out = [];
  const plan = { x: t.x, y: TRAY_Y, w: t.w, d: TRAY_D, r: 2 };
  out.push(S(k.slabOf(plan, 0, 0.4, P, 4), { tone: "lo", crease: "none", flat: true }));
  // Rim on the far sides and front; the mouth faces the track.
  out.push(S(k.slabOf({ x: t.x - 2, y: TRAY_Y + 2, w: 2, d: TRAY_D - 2, r: 0.6 }, 0, 2.6, P, 2), { tone: "mid" }));
  out.push(S(k.slabOf({ x: t.x + t.w, y: TRAY_Y + 2, w: 2, d: TRAY_D - 2, r: 0.6 }, 0, 2.6, P, 2), { tone: "mid" }));
  out.push(S(k.slabOf({ x: t.x - 2, y: TRAY_Y + TRAY_D, w: t.w + 4, d: 2.4, r: 0.8 }, 0, 2.6, P, 2, 0.3), { tone: "mid" }));
  if (t.shut) {
    // Shutter: a lid across the mouth with a thumb screw. Web is egress and script is an action; the head never drops a turn here.
    const lid = { x: t.x - 1, y: TRAY_Y - 1, w: t.w + 2, d: TRAY_D + 1, r: 1.4 };
    out.push(S(k.slabOf(lid, 2.6, 1.6, P, 3, 0.4), { tone: "lo" }));
    out.push(L(k.planOutline(k.insetPlan(lid, 2.4), 4.2, P, 3), { tone: "faint" }));
    out.push(S(k.cylinder(trayCentre(t), TRAY_Y + 8, 2.8, 4.2, 2.6, P, 20), { tone: "mid" }));
    out.push(L(k.knurl(trayCentre(t), TRAY_Y + 8, 2.8, 4.2, 6.8, 16, P), { tone: "lo" }));
  } else {
    out.push(D([at([trayCentre(t), TRAY_Y + TRAY_D - 3.4, 0.4])], { size: 0.5, tone: "lo" }));
  }
  return out.join("");
}

function endTray() {
  const out = [];
  out.push(S(k.slabOf(END, 0, 0.4, P, 4), { tone: "lo", crease: "none", flat: true }));
  out.push(S(k.slabOf({ x: END.x + END.w, y: END.y, w: 2.4, d: END.d, r: 0.8 }, 0, 4, P, 2, 0.3), { tone: "mid" }));
  out.push(S(k.slabOf({ x: END.x + 4, y: END.y - 2.4, w: END.w - 4, d: 2.4, r: 0.6 }, 0, 2.6, P, 2), { tone: "mid" }));
  out.push(S(k.slabOf({ x: END.x + 4, y: END.y + END.d, w: END.w - 4, d: 2.4, r: 0.6 }, 0, 2.6, P, 2), { tone: "mid" }));
  return out.join("");
}

function dial(d) {
  const out = [];
  const [x, y] = d.at;
  out.push(`<path class="iso-halo" d="${k.haloOf({ x: x - 9, y: y - 9, w: 18, d: 18, r: 9 }, 0, 0.1, P)}" style="filter:blur(3px)"/>`);
  out.push(S(k.cylinder(x, y, 7, 0, 3, P, 28), { tone: "lo" }));
  out.push(S(k.cylinder(x, y, 5, 3, 4, P, 28), { tone: "mid" }));
  out.push(S(k.cylinder(x, y, 2.9, 7, DIAL_Z - 7, P, 20), { tone: "mid", crease: "none", inner: L([24, 44].map((z) => k.sideArc(x, y, 2.9, z, P, 12)).join(""), { tone: "faint" }) }));
  out.push(S(k.cylinder(x, y, DIAL_R, DIAL_Z, DIAL_H, P, 64, 0.8), { tone: "hi", crease: "lo" }));
  out.push(L(k.knurl(x, y, DIAL_R, DIAL_TOP - 3.2, DIAL_TOP, 80, P, 0.3), { tone: "lo" }));
  out.push(L(k.sideArc(x, y, DIAL_R, DIAL_TOP - 3.2, P, 40), { tone: "faint" }));
  out.push(L(k.ring(x, y, DIAL_R - 2.2, DIAL_TOP, P, 64), { tone: "lo" }));
  const ticks = k.radialTicks(x, y, DIAL_R - 2.2, 50, 5, DIAL_TOP, [1.3, 2.8], P, SWEEP_FROM, SWEEP);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  // The pass mark: a long heavy tick at the threshold, rooted on the bezel ring.
  const a = SWEEP_FROM + d.mark * SWEEP;
  out.push(`<path class="iso-line" data-tone="hi" d="${k.lineOnTop([x + Math.sin(a) * (DIAL_R - 8.6), y - Math.cos(a) * (DIAL_R - 8.6)], [x + Math.sin(a) * (DIAL_R - 2.2), y - Math.cos(a) * (DIAL_R - 2.2)], DIAL_TOP, P)}" style="stroke-width:1.2"/>`);
  out.push(D([at([x + Math.sin(a) * (DIAL_R - 8.6), y - Math.cos(a) * (DIAL_R - 8.6), DIAL_TOP])], { size: 0.8, tone: "hi" }));
  // Crown on the +x side and the hub.
  out.push(S(k.slabOf({ x: x + DIAL_R - 1, y: y - 2.4, w: 4.4, d: 4.8, r: 1.2 }, DIAL_Z + 2, 4.6, P, 3), { tone: "mid" }));
  out.push(S(k.slabOf({ x: x + DIAL_R + 3, y: y - 3.2, w: 2.6, d: 6.4, r: 1.2 }, DIAL_Z + 1.2, 6.2, P, 3), { tone: "mid" }));
  out.push(L(k.ring(x, y, 1.6, DIAL_TOP, P, 16), { tone: "mid" }));
  return out.join("");
}

const needleAt = (cx, cy, value) => {
  const a = SWEEP_FROM + Math.min(1, Math.max(0, value)) * SWEEP;
  return k.lineOnTop([cx - Math.sin(a) * 3.4, cy + Math.cos(a) * 3.4], [cx + Math.sin(a) * (DIAL_R - 4), cy - Math.cos(a) * (DIAL_R - 4)], DIAL_TOP + 0.2, P);
};

function token() {
  return `<path class="iso-halo" d="${k.haloOf({ x: -TOKEN_R, y: -TOKEN_R, w: 2 * TOKEN_R, d: 2 * TOKEN_R, r: TOKEN_R }, 0, 0.1, P)}" style="filter:blur(2px)"/>` +
    S(k.cylinder(0, 0, TOKEN_R, 0.5, TOKEN_H, P, 40, 0.5), { tone: "hi", lit: true }) +
    L(k.ring(0, 0, TOKEN_R - 2.2, 0.5 + TOKEN_H, P, 32), { tone: "lo" });
}

// Turns to replay. The words are real asks; the scores are illustrative, set either side of the shipping thresholds.
const TURNS = [
  { ask: "What's Australia's capital?", p: 0.18, group: null },
  { ask: "What's on my calendar tomorrow?", p: 0.94, group: "device", q: 0.91 },
  { ask: "Find my kitchen-quote notes", p: 0.88, group: "knowledge", q: 0.86 },
  { ask: "Latest Artemis launch news", p: 0.97, group: "web", q: 0.93 },
  { ask: "What did I work on yesterday?", p: 0.83, group: "activity", q: 0.81 },
  { ask: "What's 17 × 23?", p: 0.55, group: "device", q: 0.62 },
  { ask: "🦊🦊🦊", p: null, group: null },
];

function routeOf(turn) {
  if (turn.p !== null && turn.p < GATE) return { x: GATE_X, tray: "chat", verdict: "plain chat" };
  if (turn.p === null) return { x: END_X, tray: null, verdict: "no score · fails open → Apple" };
  const shut = TRAYS.find((t) => t.name === turn.group)?.shut;
  if (turn.q < FLOOR) return { x: END_X, tray: null, verdict: `${turn.group} ${turn.q.toFixed(2)} < floor → Apple` };
  if (shut) return { x: END_X, tray: null, verdict: `${turn.group} stays shut → Apple` };
  return { x: trayCentre(TRAYS.find((t) => t.name === turn.group)), tray: turn.group, verdict: `dispatch ${turn.group}` };
}
const ROUTES = TURNS.map(routeOf);

const svg = k.figureSvg({
  width: WIDTH,
  height: HEIGHT,
  label:
    "A sorting bench for chat turns. A turn drops from an inlet tube onto a track. At the first station a dial reads the gate's probability that the turn needs a tool; below its pass mark a ram pushes the turn into the plain-chat tray. Otherwise a second dial reads the group head's confidence, and only above its floor is the turn pushed into the device, knowledge or activity tray. The web and script trays are shuttered. Everything else rolls to the end tray, Apple's pick or the agent.",
  body: [
    plate(),
    track(),
    ...DIALS.map(dial),
    ...DIALS.map((d, i) => `<path data-part="needle${i}" class="iso-line" data-tone="lit" data-free="start" d="${needleAt(d.at[0], d.at[1], 0)}" style="stroke-width:1.1"/>`),
    rail(),
    `<g data-part="carriage" transform="${k.translateAlong(P, [INLET_X + 20, 0, 0])}">${carriage()}<g data-part="ram">${S(ramPaths(RAM_REST), { tone: "mid" })}</g></g>`,
    ...TRAYS.map(tray),
    endTray(),
    inlet(),
    `<g data-part="token" transform="${k.translateAlong(P, [INLET_X, 0, 0])}" style="opacity:0">${token()}</g>`,
  ],
});

const live = `
const P = ${JSON.stringify(P)};
const TURNS = ${JSON.stringify(TURNS)};
const ROUTES = ${JSON.stringify(ROUTES)};
const DIALS = ${JSON.stringify(DIALS)};
const GATE = ${GATE}, FLOOR = ${FLOOR};
const INLET_X = ${INLET_X}, GATE_X = ${GATE_X}, END_X = ${END_X}, TRAY_Y = ${TRAY_Y}, TOKEN_R = ${TOKEN_R};
const DIAL_R = ${DIAL_R}, DIAL_TOP = ${DIAL_TOP}, SWEEP_FROM = ${SWEEP_FROM}, SWEEP = ${SWEEP};
const RAM_W = ${RAM_W}, RAM_Z = ${RAM_Z}, RAM_H = ${RAM_H}, RAM_REST = ${RAM_REST}, RAM_FROM = ${BRACKET.y + BRACKET.d};
const stage = document.querySelector(".iso-stage");
const svg = stage.querySelector("svg");
const part = (name) => svg.querySelector('[data-part="' + name + '"]');
const tokenEl = part("token"), carriageEl = part("carriage"), ramEl = part("ram");
const needles = [part("needle0"), part("needle1")];
const readout = document.querySelector("[data-readout]");
const still = matchMedia("(prefers-reduced-motion: reduce)");
const needleAt = ${needleAt.toString().replace("k.lineOnTop", "lineOnTop")};
const ramPaths = ${ramPaths.toString().replace("k.slabOf", "slabOf")};
const BRACKET = ${JSON.stringify(BRACKET)};

// One turn is a list of timed poses; every part follows its pose with exponential easing.
function poses(index) {
  const turn = TURNS[index], route = ROUTES[index];
  const pin = (turn.p ?? 1);
  const gateNeedle = turn.p ?? 0;
  const list = [];
  list.push({ t: 0.5, x: INLET_X, y: 0, car: INLET_X + 20, ram: RAM_REST, n: [0, 0], o: 1, say: "“" + turn.ask + "”" });
  list.push({ t: 1.1, x: GATE_X, y: 0, car: GATE_X, ram: RAM_REST, n: [gateNeedle, 0], o: 1, say: turn.p === null ? "no vector · gate fails open" : "P(tool) " + turn.p.toFixed(2) + (turn.p < GATE ? " < " : " ≥ ") + GATE.toFixed(3) });
  if (route.tray === "chat") {
    list.push({ t: 1.4, x: GATE_X, y: TRAY_Y + 12, car: GATE_X, ram: TRAY_Y + 12 - TOKEN_R - RAM_FROM, n: [gateNeedle, 0], o: 1, say: "plain chat · 13.4 s, not 51.5 s" });
  } else {
    const q = turn.q ?? 0;
    const headX = ${DIALS[1].at[0]};
    list.push({ t: 1.2, x: headX, y: 0, car: headX, ram: RAM_REST, n: [gateNeedle, q], o: 1, say: turn.group ? turn.group + " " + q.toFixed(2) + (q < FLOOR ? " < " : " ≥ ") + FLOOR.toFixed(3) : "head abstains" });
    if (route.tray) {
      list.push({ t: 0.9, x: route.x, y: 0, car: route.x, ram: RAM_REST, n: [gateNeedle, q], o: 1, say: turn.group + " " + q.toFixed(2) + " ≥ " + FLOOR.toFixed(3) });
      list.push({ t: 1.4, x: route.x, y: TRAY_Y + 12, car: route.x, ram: TRAY_Y + 12 - TOKEN_R - RAM_FROM, n: [gateNeedle, q], o: 1, say: "dispatch " + turn.group + " · no model" });
    } else {
      list.push({ t: 1.6, x: END_X, y: 0, car: ${RAIL.x + RAIL.w - CAR.w / 2}, ram: RAM_REST, n: [gateNeedle, q], o: 1, say: route.verdict });
    }
  }
  const last = list[list.length - 1];
  list.push({ ...last, t: 1.6 });
  list.push({ ...last, t: 0.5, ram: RAM_REST, o: 0, n: [0, 0] });
  return list;
}

let index = 0, list = poses(0), step = 0, clock = 0;
const now = { x: INLET_X, y: 0, car: INLET_X + 20, ram: RAM_REST, n: [0, 0], o: 0 };
let frame = 0, last = 0, visible = false, held = false, lastRam = -1, lastSay = "";
const follow = (a, b, dt, s, calm) => calm ? b : a + (b - a) * (1 - Math.exp(-dt / s));

function draw() {
  tokenEl.setAttribute("transform", translateAlong(P, [now.x, now.y, 0]));
  tokenEl.style.opacity = now.o.toFixed(3);
  carriageEl.setAttribute("transform", translateAlong(P, [now.car, 0, 0]));
  const reach = Math.round(now.ram * 4) / 4;
  if (reach !== lastRam) { ramEl.innerHTML = solidSvg(ramPaths(reach), { tone: "mid" }); lastRam = reach; }
  needles.forEach((el, i) => el.setAttribute("d", needleAt(DIALS[i].at[0], DIALS[i].at[1], now.n[i])));
  const say = list[step].say;
  if (say !== lastSay) { readout.textContent = say; lastSay = say; stage.setAttribute("aria-valuetext", say); }
}

function tick(ms) {
  const dt = last ? Math.min((ms - last) / 1000, 1 / 30) : 1 / 60;
  last = ms;
  const calm = still.matches;
  const pose = list[step];
  // The ram pushes the turn: the token leaves the track only once the ram is behind it.
  now.car = follow(now.car, pose.car, dt, 0.22, calm);
  now.x = follow(now.x, pose.x, dt, 0.22, calm);
  now.ram = follow(now.ram, pose.ram, dt, 0.18, calm);
  const pushed = RAM_FROM + now.ram + TOKEN_R;
  now.y = pose.y > 0 ? Math.max(0, Math.min(pose.y, pushed)) : follow(now.y, pose.y, dt, 0.2, calm);
  now.n = now.n.map((v, i) => follow(v, pose.n[i], dt, 0.32, calm));
  now.o = follow(now.o, pose.o, dt, 0.12, calm);
  draw();
  if (!held && !calm) {
    clock += dt;
    if (clock >= pose.t) { clock = 0; step++; if (step >= list.length) { index = (index + 1) % TURNS.length; list = poses(index); step = 0; } }
  }
  frame = visible ? requestAnimationFrame(tick) : 0;
}
const run = () => { if (!frame && visible) { last = 0; frame = requestAnimationFrame(tick); } };
const jump = (to) => {
  index = (to + TURNS.length) % TURNS.length; list = poses(index); clock = 0;
  if (still.matches) { step = list.length - 3; Object.assign(now, { ...list[step], n: [...list[step].n] }); now.o = 1; draw(); } else step = 0;
  run();
};
new IntersectionObserver((entries) => { visible = entries[entries.length - 1].isIntersecting; if (visible) run(); }, { rootMargin: "120px 0px" }).observe(stage);
stage.addEventListener("click", () => jump(index + 1));
stage.addEventListener("pointerenter", () => { held = false; });
stage.addEventListener("keydown", (event) => {
  if (event.key === "ArrowRight" || event.key === "ArrowDown" || event.key === " " || event.key === "Enter") { event.preventDefault(); jump(index + 1); }
  if (event.key === "ArrowLeft" || event.key === "ArrowUp") { event.preventDefault(); jump(index - 1); }
});
if (still.matches) jump(0);
draw();
`;

const body = k.plateHtml({
  fig: "Fig 1",
  title: "M1K3's tool router",
  hint: "Click or press → for the next turn",
  readout: "“" + TURNS[0].ask + "”",
  keys: [
    { mark: "lit", label: "The turn, and the two needles that read it" },
    { mark: "raised", label: "Trays, left to right: plain chat, then device, knowledge, activity; web and script are shuttered" },
    { mark: "edge", label: "Heavy ticks: the gate's 0.322 and the head's 0.763, the shipping weights" },
  ],
  caption:
    "Every chat turn is embedded once (Apple's sentence vector, ~5 ms) and read by two tiny heads, no model in the loop. The gate (left dial) sends anything under 0.322 straight to plain chat: on Mini that took a median 13.4 s instead of 51.5 s with the tool palette, and scored better. A turn it can't score fails open to the tools. The group head (right dial) dispatches a local read only above 0.763, picked for 95% precision, and never a web search or an action; every other turn rolls on to Apple's pick or the agent, which is only slower, never wrong. The asks are real; their scores are illustrative.",
  body: `<div class="iso-stage" tabindex="0" role="slider" aria-label="Tool router: arrow keys step through example turns" aria-valuemin="1" aria-valuemax="${TURNS.length}" aria-valuenow="1">${svg}</div>`,
});

const file = theme === "light" ? "tool-router-light.html" : "tool-router.html";
writeFileSync(join(HERE, file), k.pageHtml({ title: "M1K3 tool router", theme, body, script: kitScript() + live, width: 680 }));
console.log("wrote", file);
