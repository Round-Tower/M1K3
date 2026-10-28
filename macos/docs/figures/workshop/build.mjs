// Fig 2 · M1K3's workshop: the whole concept as one machine. "M1K3 is a mechanic after all" (Kev, 2026-08-03).
// Truth, by station (paths under macos/):
//   brain     MLX on this machine; offline by default (Sources/M1K3LanguageModel/BrainCatalogue.swift)
//   weights   pinned revision + digests committed to the repo, checked before MLX sees a byte (Sources/M1K3MLX/WeightIntegrity.swift)
//   Cool Head thermal/power pressure caps effort, never swaps the brain: full = base iterations, eased <= 3, minimal <= 1
//             (Sources/M1K3LanguageModel/CoolHeadPolicy.swift)
//   soul      the CRT rolling band is the heartbeat; the villain persona is a protected species (docs/DESIGN_DOCTRINE.md)
//   memory    a finished slice distils to "FACT(<kind>): ..." lines (MemoryDistiller.swift); EmbeddingGemma 2 dedupe at 0.95
//   egress    web search on by default and disclosed per turn (EgressDisclosure.swift); Private Cloud asked once (PrivateCloudArming.swift,
//             ADR 0010); MCP on 127.0.0.1:4242 behind an access token (#270)
//   evals     a challenger wins on paired per-question results, wired like the app: MoE Big round 3, gemma-4-12B 122/135 vs
//             gemma-4-26B-A4B 115/135, +3/-8 fixtures, ties dropped, p .23 (docs/evals/2026-10-24-moe-big/README.md)
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ANATOMY = process.env.ANATOMY;
const k = await import(join(ANATOMY, "kit/iso-kit.mjs"));
const G = await import(join(ANATOMY, "kit/lathe.mjs"));
const T = await import(join(ANATOMY, "kit/tube.mjs"));
const { kitScript } = await import(join(ANATOMY, "scripts/inline-kit.mjs"));

const HERE = dirname(fileURLToPath(import.meta.url));
const theme = process.argv.includes("--light") ? "light" : "dark";

const WIDTH = 760;
const HEIGHT = 560;
const AZ = 40;

const BENCH = { x: -240, y: -120, w: 480, d: 240, r: 10 };
const BENCH_H = 14;
const FOOT_H = 6;
const WALL = { x: -232, y: -118, w: 464, d: 8, r: 1.5 };
const WALL_H = 100;
const WY = WALL.y + WALL.d; // the wall's front face

const P = k.fitProjection(
  [...k.boxCorners(BENCH, -BENCH_H - FOOT_H, 0), ...k.boxCorners(WALL, 0, WALL_H + 4), [-118, -58, 104]],
  WIDTH,
  HEIGHT,
  { pad: 24, azimuth: AZ },
);

const at = (p) => k.iso(p, P);
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));
const poly = (points) => "M" + points.map((p) => at(p).map((v) => v.toFixed(1)).join(" ")).join("L") + "Z";
// A flat shape painted on a vertical face (y = const), in the kit's inks.
const facePoly = (points, { fill = "paper", stroke = "mid", width = 0.6, opacity, part } = {}) =>
  `<path${part ? ` data-part="${part}"` : ""} d="${poly(points)}" style="fill:var(--anatomy-${fill});stroke:${stroke ? `var(--anatomy-${stroke})` : "none"};stroke-width:${width};stroke-linejoin:round${opacity !== undefined ? `;opacity:${opacity}` : ""}"/>`;
const rectY = (y, x0, x1, z0, z1) => [[x0, y, z0], [x1, y, z0], [x1, y, z1], [x0, y, z1]];
const circleY = (y, cx, cz, r, n = 20) => Array.from({ length: n }, (_, i) => { const a = (i / n) * Math.PI * 2; return [cx + Math.sin(a) * r, y, cz + Math.cos(a) * r]; });
const screw = (p) => D([at(p)], { size: 0.5 });

// ───────────────────────── bench and wall

function bench() {
  const out = [`<path class="iso-halo" d="${k.haloOf(BENCH, -BENCH_H - FOOT_H, BENCH_H, P)}"/>`];
  for (const [x, y] of byDepth(k.corners(BENCH, 26))) {
    out.push(S(k.cylinder(x, y, 8, -BENCH_H - FOOT_H, 1.8, P, 28), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 6, -BENCH_H - FOOT_H + 1.8, FOOT_H - 1.8, P, 28), { tone: "mid" }));
  }
  out.push(S(k.slabOf(BENCH, -BENCH_H, BENCH_H, P, 8, 1.6), { tone: "mid", inner: L(k.sideSeam(BENCH, -6, P, 8), { tone: "faint" }) }));
  out.push(L(k.planOutline(k.insetPlan(BENCH, 5), 0, P), { tone: "lo" }));
  const screws = k.corners(BENCH, 10);
  out.push(L(screws.map(([x, y]) => k.ring(x, y, 2.2, 0, P, 16)).join(""), { tone: "lo" }));
  out.push(D(screws.map(([x, y]) => at([x, y, 0])), { size: 0.5 }));
  const strip = { x: -200, y: BENCH.y + BENCH.d - 15, w: 400, d: 7, r: 1 };
  out.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 4, 5, strip.y + 0.8, 0.6, [2, 3.6], P);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  // Label plate, front middle: the one engraved word.
  const label = { x: -22, y: 62, w: 48, d: 22, r: 1.5 };
  out.push(S(k.slabOf(label, 0, 0.8, P, 4), { tone: "lo", crease: "none" }));
  out.push(L(k.planOutline(k.insetPlan(label, 1.6), 0.8, P, 4), { tone: "faint" }));
  out.push(k.faceTextSvg(k.topMatrix([label.x + 6, label.y + 9], 0.8, P, "x"), "M1K3", { size: 4.4, tone: "mid" }));
  for (const [dy, len] of [[13.5, 32], [16.5, 22], [19, 27]]) out.push(L(k.lineOnTop([label.x + 6, label.y + dy], [label.x + 6 + len, label.y + dy], 0.8, P), { tone: "lo", free: true }));
  out.push(D([at([label.x + label.w - 4, label.y + 4, 0.8]), at([label.x + label.w - 4, label.y + label.d - 4, 0.8])], { size: 0.45 }));
  return out.join("");
}

const BOARD = { x0: -222, x1: -64, z0: 22, z1: 92 };
const PANEL = { x0: 40, x1: 222, z0: 14, z1: 92 };

function wall() {
  const out = [];
  out.push(S(k.slabOf(WALL, 0, WALL_H, P, 4, 0.8), { tone: "mid", inner: L(k.sideSeam(WALL, 8, P, 4), { tone: "faint" }) }));
  // Skirting rail along the foot of the wall.
  out.push(S(k.slabOf({ x: WALL.x, y: WY, w: WALL.w, d: 3, r: 0.6 }, 0, 6, P, 2, 0.3), { tone: "lo" }));
  // Uprights where the wall is bolted to the bench.
  for (const x of [-232 + 2, -40, 18, 230 - 6]) {
    out.push(S(k.slabOf({ x, y: WY, w: 4, d: 2.6, r: 0.6 }, 6, WALL_H - 10, P, 2), { tone: "mid" }));
    out.push(screw([x + 2, WY + 2.6, 20]), screw([x + 2, WY + 2.6, WALL_H - 10]));
  }
  return out.join("");
}

// ───────────────────────── tools: a shadow board, one tool out on the job

function tool(kind, cx, top, ghost) {
  const y = WY + 3.2;
  const style = ghost ? { fill: "page", stroke: "faint", width: 0.5 } : { fill: "paper", stroke: "mid" };
  const shade = { fill: "lo", stroke: null, opacity: 0.55 };
  const shapes = [];
  if (kind === "spanner") {
    shapes.push(rectY(y, cx - 2.4, cx + 2.4, top - 46, top - 8));
    shapes.push([...circleY(y, cx, top - 7, 6.4, 18)]);
    shapes.push(rectY(y, cx - 3.2, cx + 3.2, top - 50, top - 44));
  } else if (kind === "driver") {
    shapes.push(rectY(y, cx - 1, cx + 1, top - 30, top - 2));
    shapes.push(rectY(y, cx - 3.6, cx + 3.6, top - 50, top - 30));
  } else if (kind === "hammer") {
    shapes.push(rectY(y, cx - 2, cx + 2, top - 50, top - 6));
    shapes.push(rectY(y, cx - 10, cx + 8, top - 8, top));
  } else if (kind === "pliers") {
    shapes.push([[cx - 4, y, top - 50], [cx - 1, y, top - 50], [cx + 1, y, top - 18], [cx - 2, y, top - 18]]);
    shapes.push([[cx + 1, y, top - 50], [cx + 4, y, top - 50], [cx + 2, y, top - 18], [cx - 1, y, top - 18]]);
    shapes.push(circleY(y, cx, top - 16, 3.6, 14));
    shapes.push([[cx - 2.6, y, top - 14], [cx + 2.6, y, top - 14], [cx + 1, y, top], [cx - 1, y, top]]);
  }
  const out = [];
  if (!ghost) for (const s of shapes) out.push(facePoly(s.map(([x, , z]) => [x + 0.9, y - 0.1, z - 0.9]), shade));
  for (const s of shapes) out.push(facePoly(s, style));
  if (!ghost) out.push(D([at([cx, y + 0.2, top - 4])], { size: 0.55, tone: "hi" }));
  return out.join("");
}

function toolBoard() {
  const out = [];
  const plan = { x: BOARD.x0, y: WY, w: BOARD.x1 - BOARD.x0, d: 3, r: 1 };
  out.push(S(k.slabOf(plan, BOARD.z0, BOARD.z1 - BOARD.z0, P, 3, 0.5), { tone: "mid" }));
  // Pegboard holes, a grid on the face.
  const holes = [];
  for (let x = BOARD.x0 + 6; x <= BOARD.x1 - 6; x += 8) for (let z = BOARD.z0 + 5; z <= BOARD.z1 - 5; z += 8) holes.push(at([x, WY + 3, z]));
  out.push(D(holes, { size: 0.6, tone: "lo" }));
  for (const [x, z] of [[BOARD.x0 + 3, BOARD.z0 + 3], [BOARD.x1 - 3, BOARD.z0 + 3], [BOARD.x0 + 3, BOARD.z1 - 3], [BOARD.x1 - 3, BOARD.z1 - 3]]) out.push(screw([x, WY + 3, z]));
  const hung = [["spanner", -206], ["spanner", -188], ["driver", -170], ["hammer", -148], ["pliers", -124], ["spanner", -106], ["driver", -88]];
  hung.forEach(([kind, x], i) => out.push(tool(kind, x, BOARD.z1 - 8, i === 5)));
  return out.join("");
}

// ───────────────────────── egress panel: everything that can leave, on one wall

const SLOT = { x0: 56, x1: 106, z: 60 };
const HATCH = { x0: 122, x1: 168, z0: 26, z1: 78 };
const PORT = { x: 196, z: 56 };

function egress() {
  const out = [];
  const plan = { x: PANEL.x0, y: WY, w: PANEL.x1 - PANEL.x0, d: 2.4, r: 1 };
  out.push(S(k.slabOf(plan, PANEL.z0, PANEL.z1 - PANEL.z0, P, 3, 0.5), { tone: "mid" }));
  const y = WY + 2.4;
  for (const [x, z] of [[PANEL.x0 + 4, PANEL.z0 + 4], [PANEL.x1 - 4, PANEL.z0 + 4], [PANEL.x0 + 4, PANEL.z1 - 4], [PANEL.x1 - 4, PANEL.z1 - 4]]) out.push(screw([x, y, z]));

  // Web: a letter slot with a hinged flap and a counter above it.
  out.push(`<g data-station="web">`);
  out.push(facePoly(rectY(y, SLOT.x0, SLOT.x1, SLOT.z - 4, SLOT.z + 4), { fill: "page", stroke: "lo" }));
  out.push(`<g data-part="flap">${facePoly(rectY(y + 0.4, SLOT.x0 - 2, SLOT.x1 + 2, SLOT.z - 6, SLOT.z + 5), { fill: "paper", stroke: "mid" })}${L(k.segment([SLOT.x0 - 2, y + 0.5, SLOT.z + 3], [SLOT.x1 + 2, y + 0.5, SLOT.z + 3], P), { tone: "faint" })}</g>`);
  out.push(S(k.slabOf({ x: SLOT.x0 + 8, y, w: 34, d: 4, r: 0.8 }, SLOT.z + 12, 11, P, 2, 0.3), { tone: "mid" }));
  out.push(facePoly(rectY(y + 4, SLOT.x0 + 11, SLOT.x0 + 39, SLOT.z + 14, SLOT.z + 21), { fill: "page", stroke: "lo", width: 0.5 }));
  out.push(`<g data-part="counter">${k.faceTextSvg(k.sideMatrix([SLOT.x0 + 12.4, y + 4], SLOT.z + 15.2, P, "left"), "0 0 0 3", { size: 5, tone: "hi" })}</g>`);

  out.push(`</g><g data-station="hatch">`);
  // Private Cloud: a hatch with a key switch. Asked once; shut unless you pick it.
  out.push(S(k.slabOf({ x: HATCH.x0, y, w: HATCH.x1 - HATCH.x0, d: 2, r: 1 }, HATCH.z0, HATCH.z1 - HATCH.z0, P, 3, 0.4), { tone: "hi", crease: "lo" }));
  for (const z of [HATCH.z0 + 8, HATCH.z1 - 8]) out.push(S(k.slabOf({ x: HATCH.x0 - 3, y: y, w: 6, d: 3, r: 1 }, z - 3, 6, P, 2), { tone: "mid" }));
  out.push(facePoly(rectY(y + 2, HATCH.x0 + 5, HATCH.x1 - 5, HATCH.z0 + 5, HATCH.z1 - 5), { fill: "paper", stroke: "faint" }));
  const lock = [HATCH.x1 - 10, HATCH.z0 + 26];
  out.push(facePoly(circleY(y + 2.2, lock[0], lock[1], 4.4, 24), { fill: "paper", stroke: "mid" }));
  // The keyway: a slot in the lock face, free at both ends like a pointer.
  out.push(`<g data-part="key">${L(k.segment([lock[0], y + 2.6, lock[1] - 3], [lock[0], y + 2.6, lock[1] + 3], P), { tone: "hi", free: true })}</g>`);
  out.push(D([at([lock[0], y + 2.4, lock[1] + 7]), at([lock[0] + 5.4, y + 2.4, lock[1] + 5])], { size: 0.55, tone: "lo" }));

  out.push(`</g><g data-station="mcp">`);
  // MCP: a socket for 127.0.0.1:4242 with its token on a tag.
  out.push(S(k.slabOf({ x: PORT.x - 10, y, w: 20, d: 3, r: 1.2 }, PORT.z - 14, 28, P, 3, 0.4), { tone: "mid" }));
  out.push(facePoly(circleY(y + 3, PORT.x, PORT.z + 2, 5.6, 24), { fill: "page", stroke: "lo" }));
  out.push(D([[-2.2, 2.4], [2.2, 2.4], [0, -0.4]].map(([dx, dz]) => at([PORT.x + dx, y + 3.1, PORT.z + 2 + dz])), { size: 0.7, tone: "mid" }));
  out.push(k.faceTextSvg(k.sideMatrix([PORT.x - 6.4, y + 3], PORT.z - 7, P, "left"), "4242", { size: 3.6, tone: "lo" }));
  out.push(`</g><g data-station="cable">`);
  // Unplugged: the network cable coiled on its hook. The brain needs nothing from it.
  const hook = [PORT.x, PORT.z + 26];
  out.push(S(k.slabOf({ x: hook[0] - 1.6, y, w: 3.2, d: 5, r: 0.8 }, hook[1] - 1.6, 3.2, P, 2), { tone: "mid" }));
  const coil = [];
  for (let i = 0; i <= 64; i++) { const a = (i / 64) * Math.PI * 2 * 3; coil.push([hook[0] + Math.sin(a) * (6 + i * 0.02), y + 4 + Math.cos(a) * 1.6, hook[1] - 7 - Math.cos(a) * 6.4]); }
  out.push(L("M" + coil.map((p) => at(p).map((v) => v.toFixed(1)).join(" ")).join("L"), { tone: "mid" }));
  const tail = [coil[coil.length - 1], [hook[0] + 7, y + 6, hook[1] - 18], [hook[0] + 9, y + 7, hook[1] - 26]];
  out.push(L("M" + tail.map((p) => at(p).map((v) => v.toFixed(1)).join(" ")).join("L"), { tone: "mid" }));
  out.push(`<g data-part="plug">${S(k.slabOf({ x: hook[0] + 6.4, y: y + 5.4, w: 5, d: 3.2, r: 0.8 }, hook[1] - 33, 7, P, 2, 0.3), { tone: "hi" })}</g></g>`);
  return out.join("");
}

// ───────────────────────── brain: the engine, its weights and its governor

const ENG = { x: -178, y: -92, w: 92, d: 58, r: 4 };
const ENG_Z = 8;
const ENG_H = 40;
const HEAD = { x: ENG.x + 6, y: ENG.y + 6, w: ENG.w - 12, d: ENG.d - 14, r: 3 };
const HEAD_TOP = ENG_Z + ENG_H + 10;
const CART = { x: -152, w: 34, z: 20, h: 14 };
const CART_IN = ENG.y + ENG.d - 30; // inserted: its back face 30 deep in the block
const CART_OUT = 30; // how far it sits out before the check
const GOV = { x: -110, y: -64 };
const GOV_TOP = HEAD_TOP + 44;
const FLY = { x: ENG.x + ENG.w, y: -62, z: 30, r: 17 };

function engine() {
  const out = [`<path class="iso-halo" d="${k.haloOf(ENG, 0, ENG_H, P)}"/>`];
  out.push(S(k.slabOf({ x: ENG.x - 6, y: ENG.y - 4, w: ENG.w + 10, d: ENG.d + 8, r: 2 }, 0, ENG_Z, P, 3, 0.6), { tone: "lo" }));
  for (const [x, y] of [[ENG.x - 2, ENG.y + 2], [ENG.x - 2, ENG.y + ENG.d], [ENG.x + ENG.w, ENG.y + 2], [ENG.x + ENG.w, ENG.y + ENG.d]]) out.push(screw([x, y, ENG_Z]));
  // Two seams and a band of cooling fins, each wrapping the visible corners.
  const fins = [];
  for (let z = ENG_Z + 30; z <= ENG_Z + ENG_H - 2; z += 2.4) fins.push(k.sideSeam(ENG, z, P, 4));
  out.push(S(k.slabOf(ENG, ENG_Z, ENG_H, P, 4, 1.0), { tone: "mid", inner: L([ENG_Z + 12, ENG_Z + 26].map((z) => k.sideSeam(ENG, z, P, 4)).join(""), { tone: "faint" }) + L(fins.join(""), { tone: "lo" }) }));
  out.push(S(k.slabOf(HEAD, ENG_Z + ENG_H, 10, P, 3, 0.8), { tone: "mid" }));
  // Four plug towers: one per core of thought.
  for (const x of [-160, -144, -128]) {
    out.push(S(k.cylinder(x, HEAD.y + 14, 3.6, HEAD_TOP, 4, P, 20), { tone: "mid" }));
    out.push(S(k.cylinder(x, HEAD.y + 14, 2, HEAD_TOP + 4, 4, P, 16), { tone: "hi" }));
  }
  out.push(L(k.planOutline(k.insetPlan(HEAD, 2.6), HEAD_TOP, P, 3), { tone: "faint" }));
  // The slot the weights go into, on the front face, with its digest comb above it.
  const slot = rectY(ENG.y + ENG.d, CART.x - 2, CART.x + CART.w + 2, CART.z - 2, CART.z + CART.h + 2);
  out.push(facePoly(slot, { fill: "page", stroke: "lo" }));
  for (let i = 0; i < 7; i++) {
    const x = CART.x + 3 + i * 4.6;
    out.push(S(k.slabOf({ x: x - 0.9, y: ENG.y + ENG.d, w: 1.8, d: 2.4, r: 0.4 }, CART.z + CART.h + 3, 3 + (i * 37 % 5), P, 2), { tone: "mid", crease: "none" }));
  }
  // Flywheel on the +x face: the brain turning over.
  const F = G.frameOf([FLY.x, FLY.y, FLY.z], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  out.push(S(G.disc(0, 2, 6, F, P), { tone: "mid" }));
  out.push(S(G.disc(2, 7, FLY.r, F, P), { tone: "hi", crease: "lo" }));
  out.push(L(G.circleOf(F, 7, FLY.r - 3, P, 64), { tone: "lo" }));
  out.push(`<path data-part="spokes" class="iso-line" data-tone="mid" d=""/>`);
  out.push(S(G.disc(7, 9, 4, F, P), { tone: "mid" }));
  return out.join("");
}

// The weights cartridge: only what sits out of the slot is drawn, so it is rebuilt as it slides in.
const FRONT = ENG.y + ENG.d;
function cartridge(out_, lit, { slabOf, lineOnTop, solidSvg: S, lineSvg: L, P, CART, FRONT }) {
  const out = [];
  if (out_ > 0.3) {
    out.push(S(slabOf({ x: CART.x, y: FRONT, w: CART.w, d: out_, r: 0.6 }, CART.z, CART.h, P, 2, 0.5), { tone: "hi", lit }));
    // Its key: the digest cut into the top edge, matching the comb on the block.
    out.push(L([0, 1, 2, 3, 4, 5, 6].map((i) => lineOnTop([CART.x + 3 + i * 4.6, FRONT + 0.2], [CART.x + 3 + i * 4.6, FRONT + out_ - 1], CART.z + CART.h, P)).join(""), { tone: "lo" }));
  }
  out.push(S(slabOf({ x: CART.x + CART.w / 2 - 5, y: FRONT + out_, w: 10, d: 3, r: 1 }, CART.z + 4, 6, P, 2), { tone: lit ? "hi" : "mid", lit }));
  return out.join("");
}

const BALL_R = 4.2;
function governorStatic() {
  const out = [];
  out.push(S(k.slabOf({ x: GOV.x - 8, y: GOV.y - 8, w: 16, d: 16, r: 2 }, HEAD_TOP, 4, P, 3, 0.5), { tone: "mid" }));
  out.push(S(k.cylinder(GOV.x, GOV.y, 2.2, HEAD_TOP + 4, GOV_TOP - HEAD_TOP - 4, P, 20), { tone: "mid", crease: "none", inner: L(k.sideArc(GOV.x, GOV.y, 2.2, GOV_TOP - 12, P, 12), { tone: "faint" }) }));
  out.push(S(k.cylinder(GOV.x, GOV.y, 4.6, GOV_TOP, 3, P, 24, 0.4), { tone: "mid" }));
  return out.join("");
}
const cartridgeSvg = (o, lit) => cartridge(o, lit, { ...k, P, CART, FRONT });
const ballSvg = S(G.sphereOf([0, 0, 0], BALL_R, P), { tone: "hi" });

// The thermometer beside the engine: Cool Head reads it.
const THERMO = { x: -64, y: -104, z0: 4, z1: 74 };
function thermometer() {
  const out = [];
  out.push(S(k.slabOf({ x: THERMO.x - 7, y: THERMO.y - 7, w: 14, d: 14, r: 2 }, 0, 4, P, 3, 0.5), { tone: "lo" }));
  out.push(S(k.cylinder(THERMO.x, THERMO.y, 4.2, THERMO.z0, 6, P, 24), { tone: "mid" }));
  out.push(S(k.cylinder(THERMO.x, THERMO.y, 2.6, THERMO.z0 + 6, THERMO.z1 - THERMO.z0 - 6, P, 20), { tone: "hi", crease: "none" }));
  out.push(S(k.cylinder(THERMO.x, THERMO.y, 3.2, THERMO.z1, 2.4, P, 20), { tone: "mid" }));
  // Three bands: full, eased (serious), minimal (critical).
  const band = (z) => L(k.sideArc(THERMO.x, THERMO.y, 2.6, z, P, 12), { tone: "lo" });
  out.push(band(34), band(52), band(64));
  out.push(`<path data-part="mercury" class="iso-line" data-tone="mid" d="" style="stroke-width:1.6"/>`);
  return out.join("");
}

// ───────────────────────── soul: the CRT face and its rolling band

const CRT = { x: -46, y: -100, w: 70, d: 50, r: 4 };
const CRT_Z = 10;
const CRT_H = 56;
const SCR = { y0: CRT.y + 7, y1: CRT.y + CRT.d - 7, z0: CRT_Z + 9, z1: CRT_Z + 47 };
const FX = CRT.x + CRT.w; // the screen's face
// The pixel face, faintly villainous: brows down at the middle, eyes, a grin.
const FACE = [
  ".##.......##.",
  "..##.....##..",
  ".............",
  "..##.....##..",
  "..##.....##..",
  ".............",
  ".............",
  "..#.......#..",
  "...#######...",
];
const PIX = 2.6;

function crt() {
  const out = [`<path class="iso-halo" d="${k.haloOf(CRT, 0, CRT_H, P)}"/>`];
  out.push(S(k.slabOf({ x: CRT.x + 10, y: CRT.y + 8, w: CRT.w - 20, d: CRT.d - 16, r: 3 }, 0, CRT_Z, P, 3, 0.5), { tone: "lo" }));
  out.push(S(k.slabOf(CRT, CRT_Z, CRT_H, P, 4, 1.0), { tone: "mid", inner: L(k.sideSeam(CRT, CRT_Z + 4, P, 4), { tone: "faint" }) }));
  // Vents on the +y face: closed slots.
  const vy = CRT.y + CRT.d;
  for (let i = 0; i < 7; i++) {
    const x0 = CRT.x + 12 + i * 6;
    out.push(facePoly([[x0, vy, CRT_Z + 30], [x0 + 2.6, vy, CRT_Z + 30], [x0 + 2.6, vy, CRT_Z + 48], [x0, vy, CRT_Z + 48]], { fill: "page", stroke: "lo", width: 0.5 }));
  }
  const rect = (x, y0, y1, z0, z1) => [[x, y0, z0], [x, y1, z0], [x, y1, z1], [x, y0, z1]];
  out.push(facePoly(rect(FX, SCR.y0 - 4, SCR.y1 + 4, SCR.z0 - 4, SCR.z1 + 4), { fill: "paper", stroke: "lo" }));
  out.push(`<clipPath id="glass"><path d="${poly(rect(FX + 0.2, SCR.y0, SCR.y1, SCR.z0, SCR.z1))}"/></clipPath>`);
  out.push(facePoly(rect(FX + 0.2, SCR.y0, SCR.y1, SCR.z0, SCR.z1), { fill: "page", stroke: "mid" }));
  const cols = FACE[0].length;
  const right = (SCR.y0 + SCR.y1) / 2 + (cols * PIX) / 2; // screen-left is +y on this face
  const top = (SCR.z0 + SCR.z1) / 2 + (FACE.length * PIX) / 2;
  const lit = [];
  FACE.forEach((row, r) => [...row].forEach((c, col) => { if (c === "#") lit.push({ r, col }); }));
  out.push(`<g clip-path="url(#glass)"><g data-part="face">${lit.map(({ r, col }) => facePoly(rect(FX + 0.3, right - (col + 1) * PIX + 0.3, right - col * PIX - 0.3, top - (r + 1) * PIX + 0.3, top - r * PIX - 0.3), { fill: "lit", stroke: null, part: r === 3 || r === 4 ? "eye" : undefined })).join("")}</g><path data-part="band" d="" style="fill:var(--anatomy-lit);opacity:.14"/></g>`);
  // Knobs and the power lamp under the screen.
  for (const y of [SCR.y0 + 8, SCR.y0 + 1]) out.push(facePolyX(FX + 0.2, Array.from({ length: 16 }, (_, i) => { const a = (i / 16) * Math.PI * 2; return [y + Math.sin(a) * 2.2, CRT_Z + 4.6 + Math.cos(a) * 2.2]; }), { fill: "paper", stroke: "mid" }));
  out.push(D([at([FX + 0.3, SCR.y1 - 2, CRT_Z + 4.6])], { size: 0.8, tone: "hi" }));
  return out.join("");
}
function facePolyX(x, yz, style) { return facePoly(yz.map(([y, z]) => [x, y, z]), style); }

// ───────────────────────── memory: the still and the card cabinet

const BOIL = { x: -196, y: 40, r: 17, z0: 6, z1: 46 };
const COND = { x0: -150, x1: -96, y: 44, z: 54, r: 7 };
const CAB = { x: -112, y: 18, w: 82, d: 64, r: 3 };
const CAB_H = 34;
const FUNNEL = { x: -92, y: 44 };
const DRAWERS = [0, 1, 2].flatMap((c) => [0, 1].map((r) => ({ c, r })));
const DIAL_M = { x: -46, y: 34, r: 9 };

function still() {
  const out = [`<path class="iso-halo" d="${k.haloOf({ x: BOIL.x - 20, y: BOIL.y - 20, w: 40, d: 40, r: 20 }, 0, 40, P)}"/>`];
  // Burner ring and legs.
  out.push(S(k.cylinder(BOIL.x, BOIL.y, 20, 0, 3, P, 48), { tone: "lo" }));
  out.push(L(k.ring(BOIL.x, BOIL.y, 14, 3, P, 40), { tone: "faint" }));
  out.push(D(Array.from({ length: 12 }, (_, i) => { const a = (i / 12) * Math.PI * 2; return at([BOIL.x + Math.sin(a) * 14, BOIL.y + Math.cos(a) * 14, 3]); }), { size: 0.5, tone: "lo" }));
  const F = G.frameOf([BOIL.x, BOIL.y, BOIL.z0], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
  const pot = [[0, 0], [0, BOIL.r], [BOIL.z1 - BOIL.z0 - 8, BOIL.r, 1], [BOIL.z1 - BOIL.z0 - 2, BOIL.r - 5, 1], [BOIL.z1 - BOIL.z0, 4]];
  out.push(S(G.solidOf(pot, F, P), { tone: "hi" }));
  out.push(L(G.arcOf(F, 10, BOIL.r, P), { tone: "faint" }));
  out.push(D(G.dotsOf(F, 6, BOIL.r, 18, P, { fade: [0.04, 0.42] }), { size: 0.5, tone: "mid" }));
  // Swan neck to the condenser.
  const neck = G.fillet([[BOIL.x, BOIL.y, BOIL.z1 - 2], [BOIL.x, BOIL.y, COND.z + 12], [COND.x0 - 10, COND.y, COND.z + 12], [COND.x0 - 10, COND.y, COND.z], [COND.x0, COND.y, COND.z]], 7, 7);
  for (const piece of T.tubePieces(neck, 2.2, P, { maxLength: 400 })) out.push(T.tubeSvg(piece, { tone: "hi" }));
  return out.join("");
}

function condenser() {
  const out = [];
  // Its stand, left of the cabinet.
  out.push(S(k.cylinder(COND.x0 + 8, COND.y, 5, 0, 3, P, 24), { tone: "lo" }));
  out.push(S(k.cylinder(COND.x0 + 8, COND.y, 1.8, 3, COND.z - COND.r - 3, P, 16), { tone: "mid", crease: "none" }));
  const F = G.frameOf([COND.x0, COND.y, COND.z], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  const len = COND.x1 - COND.x0;
  out.push(S(G.disc(0, 3, COND.r + 1.4, F, P), { tone: "mid" }));
  out.push(S(G.disc(3, len - 6, COND.r, F, P), { tone: "hi", inner: L([12, 22, 32, 42].map((s) => G.arcOf(F, s, COND.r, P)).join(""), { tone: "faint" }) }));
  out.push(S(G.disc(len - 6, len - 3, COND.r + 1.4, F, P), { tone: "mid" }));
  // The spout, bent down over the funnel.
  const spout = G.fillet([[COND.x1 - 3, COND.y, COND.z], [FUNNEL.x, FUNNEL.y, COND.z], [FUNNEL.x, FUNNEL.y, COND.z - 10]], 4, 6);
  for (const piece of T.tubePieces(spout, 1.4, P, { maxLength: 400 })) out.push(T.tubeSvg(piece, { tone: "mid" }));
  return out.join("");
}

function cabinet() {
  const out = [`<path class="iso-halo" d="${k.haloOf(CAB, 0, CAB_H, P)}"/>`];
  out.push(S(k.slabOf(CAB, 0, CAB_H, P, 4, 1.0), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(CAB, 3), CAB_H, P, 4), { tone: "faint" }));
  // The funnel on top.
  const F = G.frameOf([FUNNEL.x, FUNNEL.y, CAB_H], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
  out.push(S(G.lathe([[0, 0], [0, 2.4], [3, 2.4], [8, 7.4, 1], [9, 7.6], [9, 0]], F, P), { tone: "hi" }));
  out.push(L(G.circleOf(F, 9, 6.4, P, 40), { tone: "lo" }));
  // The dedupe gauge: a new fact closer than 0.95 to an old one merges.
  out.push(S(k.cylinder(DIAL_M.x, DIAL_M.y, DIAL_M.r, CAB_H, 4, P, 48, 0.5), { tone: "hi", crease: "lo" }));
  out.push(L(k.ring(DIAL_M.x, DIAL_M.y, DIAL_M.r - 1.4, CAB_H + 4, P, 48), { tone: "lo" }));
  const t = k.radialTicks(DIAL_M.x, DIAL_M.y, DIAL_M.r - 1.4, 20, 5, CAB_H + 4, [0.9, 1.8], P, SWEEP_FROM, SWEEP);
  out.push(L(t.minor, { tone: "lo" }), L(t.major, { tone: "mid" }));
  out.push(mark(DIAL_M.x, DIAL_M.y, DIAL_M.r - 1.4, DIAL_M.r - 5.4, CAB_H + 4, 0.95));
  out.push(`<path data-part="simNeedle" class="iso-line" data-tone="lit" data-free="start" d="" style="stroke-width:1"/>`);
  return out.join("");
}

function drawer({ c, r }) {
  const w = (CAB.w - 10) / 3;
  const x = CAB.x + 4 + c * (w + 1);
  const z = 4 + r * 15;
  const plan = { x, y: CAB.y + CAB.d - 40, w: w - 1, d: 40, r: 1 };
  const out = [];
  out.push(S(k.slabOf(plan, z, 13, P, 2, 0.4), { tone: "mid" }));
  const fy = plan.y + plan.d;
  out.push(facePoly(rectY(fy, x + 5, x + w - 6, z + 7, z + 11), { fill: "page", stroke: "lo", width: 0.5 }));
  out.push(S(k.slabOf({ x: x + w / 2 - 4, y: fy, w: 7, d: 2.2, r: 1 }, z + 2.6, 2.6, P, 2), { tone: "hi", crease: "none" }));
  return out.join("");
}

// ───────────────────────── evaluation: the twin dyno and its pegboard

const DYNO = { x: 44, y: 14, w: 176, d: 94, r: 4 };
const ARMS = [
  { name: "champion", x: 70 },
  { name: "challenger", x: 166 },
];
const READER = { x: 118, y: 22, w: 26, d: 28 };
const PEG = { x0: 62, step: 13.6, yChamp: 82, yChal: 96 };
// MoE Big round 3: fixtures whose pass count over three repeats differed, ties dropped. +3 challenger / -8 champion.
const PAIRS = ["champ", "champ", "chal", "champ", "champ", "chal", "champ", "champ", "champ", "chal", "champ"];

function dyno() {
  const out = [`<path class="iso-halo" d="${k.haloOf(DYNO, 0, 6, P)}"/>`];
  out.push(S(k.slabOf(DYNO, 0, 6, P, 4, 0.8), { tone: "lo" }));
  out.push(L(k.planOutline(k.insetPlan(DYNO, 4), 6, P, 4), { tone: "faint" }));
  // The shared question reader: one tape, both arms, wired alike.
  const reader = { x: READER.x, y: READER.y, w: READER.w, d: READER.d, r: 2 };
  out.push(S(k.slabOf(reader, 6, 16, P, 3, 0.6), { tone: "mid" }));
  out.push(S(k.cylinder(READER.x + READER.w / 2, READER.y + 12, 10, 22, 4, P, 40, 0.5), { tone: "hi", crease: "lo" }));
  out.push(L(k.ring(READER.x + READER.w / 2, READER.y + 12, 3, 26, P, 20), { tone: "lo" }));
  out.push(`<path data-part="reel" class="iso-line" data-tone="mid" d=""/>`);
  // Tape out of the reader toward the pegboard.
  out.push(S(k.slabOf({ x: READER.x + 5, y: READER.y + READER.d, w: READER.w - 10, d: 22, r: 0.4 }, 6, 0.4, P, 2), { tone: "hi", crease: "none", flat: true }));
  out.push(L([0, 1, 2, 3].map((i) => k.ring(READER.x + 9 + i * 2.6, READER.y + READER.d + 8, 0.6, 6.4, P, 8)).join(""), { tone: "lo" }));
  // Drive rods from the reader to each arm.
  for (const arm of ARMS) {
    const from = arm.x < READER.x ? arm.x + 18 : READER.x + READER.w;
    const to = arm.x < READER.x ? READER.x : arm.x - 18;
    out.push(S(k.slabOf({ x: from, y: READER.y + 12, w: to - from, d: 3, r: 1.2 }, 12, 3, P, 2), { tone: "mid", crease: "none" }));
  }
  return out.join("");
}

function arm(a, i) {
  const out = [];
  const plan = { x: a.x - 18, y: 20, w: 36, d: 34, r: 3 };
  const fins = [];
  for (let z = 22; z <= 30; z += 2.2) fins.push(k.sideSeam(plan, z, P, 3));
  out.push(S(k.slabOf(plan, 6, 26, P, 3, 0.8), { tone: i ? "hi" : "mid", crease: "lo", inner: L(k.sideSeam(plan, 18, P, 3), { tone: "faint" }) + L(fins.join(""), { tone: "lo" }) }));
  // Each arm's score dial, face up.
  out.push(S(k.cylinder(a.x, 36, 10, 32, 4, P, 48, 0.5), { tone: "hi", crease: "lo" }));
  out.push(L(k.ring(a.x, 36, 8.4, 36, P, 48), { tone: "lo" }));
  const t = k.radialTicks(a.x, 36, 8.4, 20, 5, 36, [0.9, 1.8], P, SWEEP_FROM, SWEEP);
  out.push(L(t.minor, { tone: "lo" }), L(t.major, { tone: "mid" }));
  out.push(`<path data-part="score${i}" class="iso-line" data-tone="lit" data-free="start" d="" style="stroke-width:1"/>`);
  return out.join("");
}

function pegboard() {
  const out = [];
  const plan = { x: PEG.x0 - 10, y: PEG.yChamp - 7, w: PAIRS.length * PEG.step + 8, d: 28, r: 2 };
  out.push(S(k.slabOf(plan, 6, 4, P, 3, 0.5), { tone: "mid" }));
  out.push(L(k.lineOnTop([plan.x, (PEG.yChamp + PEG.yChal) / 2], [plan.x + plan.w, (PEG.yChamp + PEG.yChal) / 2], 10, P), { tone: "faint" }));
  PAIRS.forEach((_, i) => {
    const x = PEG.x0 + i * PEG.step;
    for (const y of [PEG.yChamp, PEG.yChal]) out.push(L(k.ring(x, y, 2, 10, P, 16), { tone: "lo" }));
  });
  return out.join("");
}
const pegSvg = S(k.cylinder(0, 0, 1.8, 0, 6, P, 16), { tone: "hi", lit: true }) + L(k.ring(0, 0, 0.8, 6, P, 10), { tone: "lo" });

// ───────────────────────── dial helpers shared by every gauge

const SWEEP_FROM = Math.atan2(Math.cos((AZ * Math.PI) / 180), -Math.sin((AZ * Math.PI) / 180)) + 0.25 * Math.PI;
const SWEEP = 1.5 * Math.PI;
function mark(x, y, r0, r1, z, value) {
  const a = SWEEP_FROM + value * SWEEP;
  return `<path class="iso-line" data-tone="hi" d="${k.lineOnTop([x + Math.sin(a) * r1, y - Math.cos(a) * r1], [x + Math.sin(a) * r0, y - Math.cos(a) * r0], z, P)}" style="stroke-width:1.1"/>` + D([at([x + Math.sin(a) * r1, y - Math.cos(a) * r1, z])], { size: 0.7, tone: "hi" });
}

// ───────────────────────── assembly, back to front

const svg = k.figureSvg({
  width: WIDTH,
  height: HEIGHT,
  label:
    "M1K3's workshop on one bench. On the back wall: a shadow board of tools with one out on the job, and an egress panel holding a web letter slot with a counter, a Private Cloud hatch on a key switch, and an MCP socket numbered 4242, with the network cable coiled on its hook. Back left, an engine (the brain) with a weights cartridge that only goes in when its cut matches the comb, a flywheel, and a centrifugal governor (Cool Head) beside a thermometer. Back middle, a CRT showing M1K3's pixel face with a rolling band, the heartbeat. Front left, a still distils a conversation into a drop that falls into a card cabinet, past a dedupe gauge marked at 0.95. Front right, a twin dyno runs a champion and a challenger off one question tape and records each question's winner on a pegboard.",
  body: [
    bench(),
    wall(),
    `<g data-station="tools">${toolBoard()}</g>`,
    `<g data-station="egress">${egress()}</g>`,
    `<g data-station="engine">${engine()}</g>`,
    `<g data-part="cart">${cartridgeSvg(0, false)}</g>`,
    `<g data-station="thermo">${thermometer()}</g>`,
    `<g data-station="governor">${governorStatic()}<path data-part="arms" class="iso-line" data-tone="mid" d="" style="stroke-width:0.9"/><g data-part="ballA">${ballSvg}</g><g data-part="ballB">${ballSvg}</g><g data-part="sleeve">${S(k.cylinder(GOV.x, GOV.y, 3.4, 0, 3, P, 20), { tone: "hi" })}</g></g>`,
    `<g data-station="crt">${crt()}</g>`,
    `<g data-station="still">${still()}</g>`,
    `<g data-station="cabinet">${cabinet()}</g>`,
    `<g data-station="still">${condenser()}</g>`,
    `<g data-part="drop" style="opacity:0">${S(G.sphereOf([0, 0, 0], 1.8, P), { tone: "hi", lit: true })}</g>`,
    `<g data-station="cabinet">${DRAWERS.slice().sort((a, b) => a.r - b.r).map((d) => `<g data-part="drawer${d.c}${d.r}">${drawer(d)}</g>`).join("")}</g>`,
    `<g data-station="dyno">${dyno()}${ARMS.map(arm).join("")}</g>`,
    `<g data-station="pegboard">${pegboard()}</g>`,
    ...PAIRS.map((who, i) => `<g data-part="peg${i}" data-x="${PEG.x0 + i * PEG.step}" data-y="${who === "chal" ? PEG.yChal : PEG.yChamp}" style="opacity:0">${pegSvg}</g>`),
  ],
});

// ───────────────────────── live

const STEPS = [
  { key: "offline", say: "offline · no cable · just you and the machine" },
  { key: "brain", say: "brain · no digest match, no weights" },
  { key: "cool", say: "Cool Head · hot, the loop drops to 3 steps, then 1 · same brain" },
  { key: "soul", say: "soul · the rolling band is the heartbeat" },
  { key: "memory", say: "memory · chats distil to facts · 0.95 merges" },
  { key: "egress", say: "egress · one wall: web, Private Cloud, MCP" },
  { key: "eval", say: "evals · paired per question · 12B holds, +3/−8" },
];

const live = `
const P = ${JSON.stringify(P)};
const STEPS = ${JSON.stringify(STEPS)};
const GOV = ${JSON.stringify(GOV)}, GOV_TOP = ${GOV_TOP}, BALL_R = ${BALL_R};
const FLY = ${JSON.stringify(FLY)};
const THERMO = ${JSON.stringify(THERMO)};
const CRT_FX = ${CRT.x + CRT.w + 0.4}, SCR = ${JSON.stringify(SCR)};
const CART_OUT = ${CART_OUT}, CART = ${JSON.stringify(CART)}, FRONT = ${FRONT};
const KIT = { slabOf, lineOnTop, solidSvg, lineSvg, P, CART, FRONT };
const cartridge = ${cartridge.toString()};
let cartDrawn = -1, cartLit = null;
const FUNNEL = ${JSON.stringify(FUNNEL)}, COND_Z = ${COND.z}, CAB_H = ${CAB_H};
const DIAL_M = ${JSON.stringify(DIAL_M)};
const READER = ${JSON.stringify(READER)};
const ARMS = ${JSON.stringify(ARMS)};
const PAIRS = ${JSON.stringify(PAIRS)};
const SWEEP_FROM = ${SWEEP_FROM}, SWEEP = ${SWEEP};
const stage = document.querySelector(".iso-stage");
const svg = stage.querySelector("svg");
const $ = (name) => svg.querySelector('[data-part="' + name + '"]');
const readout = document.querySelector("[data-readout]");
const still = matchMedia("(prefers-reduced-motion: reduce)");
const el = { arms: $("arms"), a: $("ballA"), b: $("ballB"), sleeve: $("sleeve"), spokes: $("spokes"), mercury: $("mercury"), band: $("band"), cart: $("cart"), drop: $("drop"), sim: $("simNeedle"), reel: $("reel"), flap: $("flap"), counter: $("counter").querySelector("text"), plug: $("plug"), key: $("key"), eyes: [...svg.querySelectorAll('[data-part="eye"]')] };
const scores = [$("score0"), $("score1")];
const pegs = PAIRS.map((_, i) => $("peg" + i));
const drawer = $("drawer11");
const path = (pts) => "M" + pts.map((p) => iso(p, P).map((v) => v.toFixed(1)).join(" ")).join("L");
const dialNeedle = (cx, cy, r, z, v) => { const a = SWEEP_FROM + Math.min(1, Math.max(0, v)) * SWEEP; return lineOnTop([cx - Math.sin(a) * 2, cy + Math.cos(a) * 2], [cx + Math.sin(a) * r, cy - Math.cos(a) * r], z + 0.2, P); };
const ease = (a, b, dt, s, calm) => calm ? b : a + (b - a) * (1 - Math.exp(-dt / s));
const lit = (node, on) => node.querySelectorAll(".iso-solid").forEach((s) => on ? s.setAttribute("data-lit", "") : s.removeAttribute("data-lit"));

// State the parts ease toward; each tour step sets its own targets.
const now = { spin: 0, rate: 1.2, lift: 0.25, heat: 0.2, cart: CART_OUT, drop: -1, sim: 0, drawer: 0, flap: 0, pegs: 0, s0: 0, s1: 0, plug: 0, key: 0, reel: 0, band: 0, count: 3 };
const want = { ...now };
let step = 0, clock = 0, held = false, frame = 0, last = 0, visible = false;

function enter(i) {
  step = (i + STEPS.length) % STEPS.length; clock = 0;
  const key = STEPS[step].key;
  Object.assign(want, { rate: 1.2, lift: 0.25, heat: 0.2, cart: 0, sim: 0, drawer: 0, flap: 0, plug: 0, key: 0 });
  if (key === "brain") { now.cart = CART_OUT; want.cart = 0; }
  if (key === "cool") { want.heat = 0.2; }
  if (key === "memory") { now.drop = 0; now.sim = 0; }
  if (key === "eval") { now.pegs = 0; now.s0 = 0; now.s1 = 0; }
  if (key === "offline") want.plug = 1;
  [el.a, el.b, el.sleeve].forEach((n) => lit(n, key === "cool"));
  lit(el.plug, key === "offline");
  el.mercury.setAttribute("data-tone", key === "cool" ? "lit" : "mid");
  el.key.querySelector("path").setAttribute("data-tone", key === "egress" ? "lit" : "hi");
  readout.textContent = STEPS[step].say;
  stage.setAttribute("aria-valuenow", String(step + 1));
  stage.setAttribute("aria-valuetext", STEPS[step].say);
}

function script(dt) {
  const key = STEPS[step].key;
  if (key === "cool") {
    // Heat climbs through eased (serious) to minimal (critical); the governor lifts and the loop is capped.
    want.heat = Math.min(0.95, 0.2 + clock * 0.16);
    const level = want.heat > 0.8 ? 2 : want.heat > 0.55 ? 1 : 0;
    want.rate = [1.2, 2.4, 3.4][level]; want.lift = [0.25, 0.65, 0.95][level];
    readout.textContent = ["Cool Head · full · the agent loop runs its course", "Cool Head · serious · loop capped at 3 steps", "Cool Head · critical · 1 step, rest deferred"][level];
  }
  if (key === "memory") {
    if (now.drop >= 0 && now.drop < 1) now.drop = Math.min(1, now.drop + dt * 0.7);
    if (now.drop >= 1) { want.sim = 0.71; if (clock > 2.4) { want.drawer = 1; readout.textContent = "memory · 0.71 < 0.95 · filed as a new card"; } }
  }
  if (key === "egress") {
    const phase = clock % 3.2;
    want.flap = phase > 0.4 && phase < 1.4 ? 1 : 0;
    if (phase > 0.9 && phase < 0.9 + dt && clock < 3.2) now.count += 1;
    want.key = clock > 3.2 ? 1 : 0;
    if (clock > 3.2) readout.textContent = "Private Cloud · asked once · hatch stays shut";
  }
  if (key === "eval") {
    want.pegs = Math.min(PAIRS.length, Math.floor(clock / 0.45));
    want.s0 = Math.min(122 / 135, clock / 6 * (122 / 135)); want.s1 = Math.min(115 / 135, clock / 6 * (115 / 135));
    if (want.pegs >= PAIRS.length) readout.textContent = "12B 122/135 · 26B 115/135 · +3/−8 · 12B stays Big";
  }
}

function draw() {
  // Governor: two balls on arms, swung out by speed; the nearer one is drawn last.
  const reach = 6 + now.lift * 7, drop = 15 - now.lift * 7;
  const hub = [GOV.x, GOV.y, GOV_TOP - 2];
  const balls = [0, Math.PI].map((o) => { const a = now.spin + o; return [GOV.x + Math.sin(a) * reach, GOV.y + Math.cos(a) * reach, GOV_TOP - 2 - drop]; });
  el.arms.setAttribute("d", balls.map((b) => path([hub, b])).join(""));
  [el.a, el.b].forEach((n, i) => n.setAttribute("transform", translateAlong(P, balls[i])));
  const nearA = depthOf(balls[0], P) > depthOf(balls[1], P);
  el.sleeve.parentNode.insertBefore(nearA ? el.b : el.a, el.sleeve); el.sleeve.after(nearA ? el.a : el.b);
  el.sleeve.setAttribute("transform", translateAlong(P, [0, 0, GOV_TOP - 12 - (1 - now.lift) * 10]));
  // Flywheel spokes on the +x face.
  el.spokes.setAttribute("d", [0, 1, 2, 3, 4].map((i) => { const a = now.spin * 0.6 + (i / 5) * Math.PI * 2; return path([[FLY.x + 7, FLY.y + Math.sin(a) * 4, FLY.z + Math.cos(a) * 4], [FLY.x + 7, FLY.y + Math.sin(a) * (FLY.r - 3), FLY.z + Math.cos(a) * (FLY.r - 3)]]); }).join(""));
  // Thermometer column.
  const top = THERMO.z0 + 8 + now.heat * (THERMO.z1 - THERMO.z0 - 12);
  el.mercury.setAttribute("d", path([[THERMO.x + 1.4, THERMO.y + 2.2, THERMO.z0 + 6], [THERMO.x + 1.4, THERMO.y + 2.2, top]]));
  // The heartbeat: a soft band rolling down the glass.
  const h = SCR.z1 - SCR.z0, z = SCR.z1 + 6 - ((now.band % 1) * (h + 12));
  el.band.setAttribute("d", path([[CRT_FX, SCR.y0, z], [CRT_FX, SCR.y1, z], [CRT_FX, SCR.y1, z - 6], [CRT_FX, SCR.y0, z - 6]]) + "Z");
  const blink = (now.band % 3.4) > 3.3;
  el.eyes.forEach((e, i) => e.style.opacity = blink ? "0.15" : "1");
  // Weights cartridge.
  const o = Math.round(now.cart * 2) / 2, on = STEPS[step].key === "brain";
  if (o !== cartDrawn || on !== cartLit) { el.cart.innerHTML = cartridge(o, on, KIT); cartDrawn = o; cartLit = on; }
  // Still: a drop from the spout to the funnel.
  if (now.drop >= 0 && now.drop < 1) { el.drop.style.opacity = "1"; el.drop.setAttribute("transform", translateAlong(P, [FUNNEL.x, FUNNEL.y, COND_Z - 10 - now.drop * (COND_Z - 10 - CAB_H - 6)])); }
  else el.drop.style.opacity = "0";
  el.sim.setAttribute("d", dialNeedle(DIAL_M.x, DIAL_M.y, DIAL_M.r - 2.6, CAB_H + 4, now.sim));
  drawer.setAttribute("transform", translateAlong(P, [0, now.drawer * 12, 0]));
  // Egress panel.
  el.flap.setAttribute("transform", translateAlong(P, [0, now.flap * 2, now.flap * 4]));
  const digits = String(now.count).padStart(4, "0").split("").join(" ");
  if (el.counter.textContent !== digits) el.counter.textContent = digits;
  el.key.setAttribute("transform", "rotate(" + (now.key * 90).toFixed(1) + " " + iso([${HATCH.x1 - 10}, ${WY + 2.6}, ${HATCH.z0 + 26}], P).join(" ") + ")");
  el.plug.setAttribute("transform", translateAlong(P, [Math.sin(now.spin * 0.8) * now.plug * 1.2, 0, 0]));
  // Dyno: reel spins, pegs drop in, score needles climb.
  el.reel.setAttribute("d", [0, 1, 2].map((i) => { const a = now.reel + (i / 3) * Math.PI * 2; const c = [READER.x + READER.w / 2, READER.y + 12]; return lineOnTop([c[0] + Math.sin(a) * 3, c[1] - Math.cos(a) * 3], [c[0] + Math.sin(a) * 8.6, c[1] - Math.cos(a) * 8.6], 26, P); }).join(""));
  pegs.forEach((peg, i) => { const shown = i < now.pegs; peg.style.opacity = shown ? "1" : "0"; peg.setAttribute("transform", translateAlong(P, [+peg.dataset.x, +peg.dataset.y, 10])); });
  scores.forEach((n, i) => n.setAttribute("d", dialNeedle(ARMS[i].x, 36, 7.4, 36, i ? now.s1 : now.s0)));
}

function tick(ms) {
  const dt = last ? Math.min((ms - last) / 1000, 1 / 30) : 1 / 60;
  last = ms;
  const calm = still.matches;
  clock += dt;
  script(dt);
  now.rate = ease(now.rate, want.rate, dt, 0.6, calm);
  if (!calm) { now.spin += now.rate * dt * 2.2; now.band += dt * 0.35; }
  if (STEPS[step].key === "eval" && !calm) now.reel += dt * 2.6;
  for (const key of ["lift", "heat", "cart", "sim", "drawer", "flap", "plug", "key", "s0", "s1"]) now[key] = ease(now[key], want[key], dt, key === "cart" ? 0.5 : 0.3, calm);
  now.pegs = want.pegs;
  draw();
  if (!held && !calm && clock > 7.5) enter(step + 1);
  frame = visible ? requestAnimationFrame(tick) : 0;
}
const run = () => { if (!frame && visible) { last = 0; frame = requestAnimationFrame(tick); } };
new IntersectionObserver((entries) => { visible = entries[entries.length - 1].isIntersecting; if (visible) run(); }, { rootMargin: "120px 0px" }).observe(stage);
stage.addEventListener("click", () => { enter(step + 1); run(); });
stage.addEventListener("keydown", (event) => {
  if (["ArrowRight", "ArrowDown", " ", "Enter"].includes(event.key)) { event.preventDefault(); enter(step + 1); run(); }
  if (["ArrowLeft", "ArrowUp"].includes(event.key)) { event.preventDefault(); enter(step - 1); run(); }
});
enter(0);
draw();
`;

const body = k.plateHtml({
  fig: "Fig 2",
  title: "M1K3's workshop",
  hint: "Click or press → for the next station",
  readout: STEPS[0].say,
  keys: [
    { mark: "lit", label: "What the current station is doing" },
    { mark: "raised", label: "Back: tools, the egress wall, the brain and its governor, the face. Front: memory, evals" },
    { mark: "edge", label: "Heavy ticks: the 0.95 dedupe floor and the score dials" },
  ],
  caption:
    "M1K3 is a mechanic, and this is his shop: one bench, one machine. The brain runs here, with no cable plugged in, and its weights only go in when their digest matches the one committed to the repo. Cool Head reads the heat and caps the agent loop (3 steps when serious, 1 when critical) instead of swapping the brain. The rolling band on the face is the heartbeat. Memory is distilled from finished chats into FACT lines and filed, unless one sits within 0.95 of a card already there. Everything that can leave goes through one wall: web searches are counted and disclosed, Private Cloud is a hatch you unlock once, and the MCP socket on 4242 needs its token. A challenger brain runs the same questions on the same rig, wired like the app, and wins question by question or not at all: the MoE Big audition ended 122/135 to 115/135, +3/−8, so gemma-4-12B stays Big. The 0.71 similarity is illustrative; every other number is from the repo.",
  body: `<div class="iso-stage" tabindex="0" role="slider" aria-label="M1K3's workshop: arrow keys step through the stations" aria-valuemin="1" aria-valuemax="${STEPS.length}" aria-valuenow="1">${svg}</div>`,
});

const file = theme === "light" ? "workshop-light.html" : "workshop.html";
writeFileSync(join(HERE, file), k.pageHtml({ title: "M1K3 workshop", theme, body, script: kitScript() + live, width: 800 }));
console.log("wrote", file);
