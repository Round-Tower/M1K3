#!/usr/bin/env python3
"""Generate assets/brand/readme-hero.svg — the animated README banner.

    python3 tools/site/readme_hero_svg.py                    # write the SVG
    python3 tools/site/readme_hero_svg.py --preview 1,4.8    # + a contact sheet frozen at those seconds

One self-contained SVG that GitHub animates inside an <img>: no <script>, no
external fetches (the image proxy drops both), CSS @keyframes and SMIL only.

- The field is Conway's Game of Life, ported from M1K3ScreensaverCore/LifeField.swift
  (B3/S23 on a torus, SplitMix64 soup, ages so newborns glow brightest) at the app
  backdrop's pitch and density. Sixty real generations play as stepped groups, and the
  seam cross-dissolves over one tick (the app's own field reseeds just as visibly).
- The Phosphor Fox is the site's Fox.glb, welded (the flat-shaded soup has every
  triangle own its corners) into its 864-edge lattice, skinned in numpy through the
  Survey clip and projected. Its SMIL <animate> morphs the path through 16 poses; the
  near flank is bright and the far flank sinks back. SMIL ignores CSS, so reduced
  motion swaps in a static copy.
- The wordmark is drawn in cells: M is the app's PixelMark, and 1, K and 3 share its
  five-row grid, so the title is made of the same stuff as the field.
- Plex Mono comes from site/fonts, subset to the characters used and inlined as woff2
  (OFL). Chip widths come from the font's own advances.

Needs numpy, plus fonttools + brotli to write (the tests need only numpy). --preview
needs Google Chrome (or set CHROME).

Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8. Prior: Unknown (new file;
the design came from a session on another repo's hero, the recipe pasted in by Kev).
Verified by eye in headless Chrome (as a page and inside an <img>), with
reduced motion forced, and in WebKit via Quick Look. Safari's SMIL path-morph is
assumed, not seen. The Life window and the fox camera are taste.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import struct
import subprocess
import tempfile
from itertools import pairwise
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
OUTPUT = REPO / "assets/brand/readme-hero.svg"
FOX_GLB = REPO / "site/vendor/Fox.glb"
PLEX = REPO / "site/fonts/ibm-plex-mono-latin-400-normal.woff2"
DEFAULT_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

W, H = 1280, 448
TX = 72  # the type column

# The site / store-frame palette (marketing/app-store/config.js).
BG, NIGHT, INK, BRIGHT, DIM, FAINT = "#050505", "#020309", "#e8e8e8", "#ffffff", "#8a8a8a", "#4a4a4a"

EYEBROW = "LOCAL  ·  OFFLINE  ·  AI"
TITLE = "M1K3"
TAGLINE = "Punk intelligence."
# "required", never bare: the opt-in Private Cloud Compute rung runs in Apple's data
# centres and web search calls a provider, but nothing M1K3 does needs one (2026-10-07,
# Kev; the site retired a bare "No data centers." on 2026-09-14 for the same reason).
CHIPS = ["No data centers required", "On-device MLX", "Live voice", "Memory that repairs itself", "MCP server", "No telemetry"]
FOX_LABEL = "PHOSPHOR FOX · 864 EDGES"


# ── Life (a port of M1K3ScreensaverCore/LifeField.swift) ───────────────────
PITCH = 16           # LifeBackdrop.pitch
DENSITY = 0.22       # LifeBackdrop's soup
SEED = 0x4D314B33    # LifeField's default seed, "M1K3"
MAX_AGE, STALE = 60, 24
GENS = 60
GEN_SECONDS = 0.4    # a touch quicker than the backdrop's 0.45 s
LIFE_START = 90      # mid-run: gliders and churn, before the field settles to ash


class SplitMix:
    def __init__(self, seed: int) -> None:
        self.s = seed or 0x9E3779B97F4A7C15

    def unit(self) -> float:
        mask = (1 << 64) - 1
        self.s = (self.s + 0x9E3779B97F4A7C15) & mask
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & mask
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & mask
        z ^= z >> 31
        return (z >> 11) / 2**53


def life_step(ages: np.ndarray) -> np.ndarray:
    """One generation of B3/S23 on the torus; survivors age, newborns are 1."""
    alive = (ages > 0).astype(np.uint8)
    neighbours = sum(
        np.roll(np.roll(alive, dr, 0), dc, 1) for dr in (-1, 0, 1) for dc in (-1, 0, 1) if dr or dc
    )
    survive = (alive == 1) & ((neighbours == 2) | (neighbours == 3))
    born = (alive == 0) & (neighbours == 3)
    older = np.minimum(ages.astype(int) + 1, MAX_AGE)
    return np.where(survive, older, np.where(born, 1, 0)).astype(np.uint8)


def life_run(cols: int, rows: int, density: float, seed: int, generations: int) -> list[np.ndarray]:
    """`LifeField.advance()` from a seeded soup: a stale field reseeds an 8×8 patch."""
    rng = SplitMix(seed)
    ages = np.zeros((rows, cols), np.uint8)
    for r in range(rows):
        for c in range(cols):
            if rng.unit() < density:
                ages[r, c] = 1
    frames = [ages.copy()]
    recent: list[bytes] = []
    stale = 0
    for _ in range(generations):
        ages = life_step(ages)
        signature = (ages > 0).tobytes()
        stale = stale + 1 if (not ages.any() or signature in recent) else 0
        recent = (recent + [signature])[-2:]
        if stale >= STALE:
            oc, orow = int(rng.unit() * cols), int(rng.unit() * rows)
            for dr in range(8):
                for dc in range(8):
                    if rng.unit() < 0.38:
                        ages[(orow + dr) % rows, (oc + dc) % cols] = 1
            stale, recent = 0, []
        frames.append(ages.copy())
    return frames


# ── The Phosphor Fox ───────────────────────────────────────────────────────
FOX_CX, FOX_CY, FOX_GROUND = 1010, 250, 392
FOX_SCALE = 2.55
FOX_YAW, FOX_TILT = -52, 11
FOX_POSES = 16
FOX_SLOWMO = 1.6     # Survey at real speed reads twitchy at banner size

_COMPONENT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
_WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class Fox:
    """The fox mesh welded into its edge lattice, skinnable at any clip time."""

    def __init__(self, path: Path) -> None:
        raw = path.read_bytes()
        json_len = struct.unpack("<I", raw[12:16])[0]
        self.gltf = json.loads(raw[20 : 20 + json_len])
        bin_at = 20 + json_len
        self.bin = raw[bin_at + 8 : bin_at + 8 + struct.unpack("<I", raw[bin_at : bin_at + 4])[0]]
        skinned = next(n for n in self.gltf["nodes"] if "skin" in n and "mesh" in n)
        prim = self.gltf["meshes"][skinned["mesh"]]["primitives"][0]
        attrs = prim["attributes"]
        pos = self.accessor(attrs["POSITION"])
        joints = self.accessor(attrs["JOINTS_0"]).astype(int)
        weights = self.accessor(attrs["WEIGHTS_0"]).astype(float)
        # The Khronos Fox ships un-indexed (every three vertices are a triangle).
        tris = (self.accessor(prim["indices"]) if "indices" in prim else np.arange(len(pos))).astype(int).reshape(-1, 3)
        # Weld: the flat-shaded soup gives every triangle its own corners. The copies are
        # co-located corners of ONE vertex, so their skin weights are identical too.
        _, first, inverse = np.unique(np.round(pos, 4), axis=0, return_index=True, return_inverse=True)
        self.pos = pos[first].astype(float)
        self.joints, self.weights = joints[first], weights[first]
        welded = inverse.reshape(-1)[tris]
        edges = {(min(p, q), max(p, q)) for t in welded for p, q in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])) if p != q}
        self.edges = np.array(sorted(edges))
        skin = self.gltf["skins"][skinned["skin"]]
        self.skin_joints = skin["joints"]
        self.inverse_bind = self.accessor(skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
        self.parent = {c: i for i, n in enumerate(self.gltf["nodes"]) for c in n.get("children", [])}

    def accessor(self, index: int) -> np.ndarray:
        acc = self.gltf["accessors"][index]
        view = self.gltf["bufferViews"][acc["bufferView"]]
        start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        width, dtype = _WIDTH[acc["type"]], np.dtype(_COMPONENT[acc["componentType"]])
        stride = view.get("byteStride", 0)
        if stride and stride != width * dtype.itemsize:
            out = np.stack([np.frombuffer(self.bin, dtype, width, start + k * stride) for k in range(acc["count"])])
        else:
            out = np.frombuffer(self.bin, dtype, acc["count"] * width, start).reshape(acc["count"], width)
        if acc.get("normalized"):
            out = out.astype(float) / np.iinfo(dtype).max
        return out if width > 1 else out.reshape(-1)

    def _clip(self, name: str) -> dict:
        return next(a for a in self.gltf["animations"] if a["name"] == name)

    def clip_duration(self, name: str) -> float:
        return max(float(self.accessor(s["input"])[-1]) for s in self._clip(name)["samplers"])

    def posed(self, clip: str, t: float) -> np.ndarray:
        trs = {
            i: [np.array(n.get("translation", [0, 0, 0]), float),
                np.array(n.get("rotation", [0, 0, 0, 1]), float),
                np.array(n.get("scale", [1, 1, 1]), float)]
            for i, n in enumerate(self.gltf["nodes"])
        }
        anim = self._clip(clip)
        for channel in anim["channels"]:
            sampler = anim["samplers"][channel["sampler"]]
            times = self.accessor(sampler["input"]).astype(float)
            values = self.accessor(sampler["output"]).astype(float)
            k = int(np.clip(np.searchsorted(times, t) - 1, 0, len(times) - 2))
            u = float(np.clip((t - times[k]) / (times[k + 1] - times[k]), 0, 1))
            path = channel["target"]["path"]
            value = _slerp(values[k], values[k + 1], u) if path == "rotation" else values[k] * (1 - u) + values[k + 1] * u
            trs[channel["target"]["node"]][("translation", "rotation", "scale").index(path)] = value
        local = {i: _compose(*v) for i, v in trs.items()}
        world: dict[int, np.ndarray] = {}

        def resolve(i: int) -> np.ndarray:
            if i not in world:
                world[i] = resolve(self.parent[i]) @ local[i] if i in self.parent else local[i]
            return world[i]

        joint_mats = np.stack([resolve(n) @ self.inverse_bind[k] for k, n in enumerate(self.skin_joints)])
        homogeneous = np.c_[self.pos, np.ones(len(self.pos))]
        out = np.zeros((len(self.pos), 3))
        for slot in range(4):
            mats = joint_mats[self.joints[:, slot]]
            out += self.weights[:, slot, None] * np.einsum("nij,nj->ni", mats, homogeneous)[:, :3]
        return out


def _slerp(a: np.ndarray, b: np.ndarray, u: float) -> np.ndarray:
    d = float(np.dot(a, b))
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        r = a + u * (b - a)
        return r / np.linalg.norm(r)
    theta = np.arccos(d)
    return (np.sin((1 - u) * theta) * a + np.sin(u * theta) * b) / np.sin(theta)


def _compose(t: np.ndarray, q: np.ndarray, s: np.ndarray) -> np.ndarray:
    x, y, z, w = q
    rot = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])
    m = np.eye(4)
    m[:3, :3] = rot * s
    m[:3, 3] = t
    return m


def project(p: np.ndarray) -> np.ndarray:
    a, e = np.radians(FOX_YAW), np.radians(FOX_TILT)
    yaw = np.array([[np.cos(a), 0, np.sin(a)], [0, 1, 0], [-np.sin(a), 0, np.cos(a)]])
    tilt = np.array([[1, 0, 0], [0, np.cos(e), -np.sin(e)], [0, np.sin(e), np.cos(e)]])
    return p @ yaw.T @ tilt.T


def strokes(edges: list[tuple[int, int]]) -> list[list[int]]:
    """Cover every edge exactly once with greedy polylines (odd-degree starts first)."""
    adjacent: dict[int, list[int]] = {}
    for a, b in edges:
        adjacent.setdefault(a, []).append(b)
        adjacent.setdefault(b, []).append(a)
    used: set[tuple[int, int]] = set()
    out = []
    for start in sorted(adjacent, key=lambda v: (len(adjacent[v]) % 2 == 0, v)):
        while any((min(start, n), max(start, n)) not in used for n in adjacent[start]):
            path, v = [start], start
            while (nxt := next((n for n in adjacent[v] if (min(v, n), max(v, n)) not in used), None)) is not None:
                used.add((min(v, nxt), max(v, nxt)))
                path.append(nxt)
                v = nxt
            out.append(path)
    return out


def _path_d(points: np.ndarray, polylines: list[list[int]]) -> str:
    """Absolute M, then relative l steps in half-pixel integers (deltas of rounded points, so no drift)."""
    out = []
    for line in polylines:
        x0, y0 = points[line[0]]
        steps = " ".join(f"{points[b][0] - points[a][0]} {points[b][1] - points[a][1]}" for a, b in pairwise(line))
        out.append(f"M{x0} {y0}l{steps}".replace(" -", "-"))
    return "".join(out)


def fox_layer() -> str:
    fox = Fox(FOX_GLB)
    duration = fox.clip_duration("Survey")
    rest = project(fox.posed("Survey", 0))
    centre, floor = (rest[:, 0].min() + rest[:, 0].max()) / 2, rest[:, 1].min()
    # Split by flank, not depth: the fox's +x side faces this camera through the whole
    # Survey turn, so it stays bright and the far legs sink back.
    flank = [(fox.pos[a, 0] + fox.pos[b, 0]) / 2 for a, b in fox.edges]
    near = strokes([tuple(e) for e, x in zip(fox.edges, flank) if x >= -0.5])
    far = strokes([tuple(e) for e, x in zip(fox.edges, flank) if x < -0.5])
    poses = []
    for t in [duration * k / FOX_POSES for k in range(FOX_POSES)] + [0.0]:
        q = project(fox.posed("Survey", t))
        x = (q[:, 0] - centre) * FOX_SCALE + FOX_CX
        y = -(q[:, 1] - floor) * FOX_SCALE + FOX_GROUND
        poses.append(np.c_[np.round(x * 2), np.round(y * 2)].astype(int))

    def live(polylines: list[list[int]], cls: str, ident: str) -> str:
        values = ";".join(_path_d(p, polylines) for p in poses)
        return (f'<path id="{ident}" class="{cls}" d="{_path_d(poses[0], polylines)}">'
                f'<animate attributeName="d" dur="{duration * FOX_SLOWMO:.3f}s" repeatCount="indefinite" values="{values}"/></path>')

    def still(polylines: list[list[int]], cls: str) -> str:
        return f'<path class="{cls}" d="{_path_d(poses[0], polylines)}"/>'

    return ('<g transform="scale(.5)">'
            f'<g class="fox-live">{live(far, "far", "fxF")}{live(near, "near", "fxN")}</g>'
            f'<g class="fox-still">{still(far, "far")}{still(near, "near")}</g></g>')


# ── The Life layer ─────────────────────────────────────────────────────────
def field_mask(x: float, y: float) -> float:
    """Where the field may show: faint behind the type, clear around the fox and its label."""
    left = min(1.0, max(0.07, (x - 640) / 300))
    dx, dy = (x - FOX_CX) / 270, (y - FOX_CY - 20) / 165
    fox = min(1.0, max(0.16, ((dx * dx + dy * dy) ** 0.5 - 0.6) / 0.7))
    label = 0.15 if (y > H - 40 and abs(x - FOX_CX) < 190) else 1.0
    return left * fox * label


def life_layer() -> tuple[str, str]:
    cols, rows = W // PITCH, H // PITCH
    frames = life_run(cols, rows, DENSITY, SEED, LIFE_START + GENS)
    window = frames[LIFE_START : LIFE_START + GENS]
    # Opacity by age, the LifeBackdrop curve in four steps: newborns brightest.
    buckets = [(1, 1, 0.62), (2, 4, 0.44), (5, 12, 0.30), (13, MAX_AGE, 0.20)]
    side, inset = 10, 3
    groups = []
    for g, ages in enumerate(window):
        paths = []
        for lo, hi, opacity in buckets:
            cells = []
            for r, c in zip(*np.nonzero((ages >= lo) & (ages <= hi))):
                x, y = c * PITCH + inset, r * PITCH + inset
                m = field_mask(x + side / 2, y + side / 2)
                if m * opacity >= 0.06:
                    cells.append((m, f"M{x} {y}h{side}v{side}h-{side}z"))
            for lo_m, hi_m in ((0, 0.35), (0.35, 0.7), (0.7, 1.01)):
                d = "".join(p for m, p in cells if lo_m <= m < hi_m)
                if d:
                    o = opacity if hi_m > 1 else opacity * (lo_m + hi_m) / 2
                    paths.append(f'<path d="{d}" fill-opacity="{o:.2f}"/>')
        cls = "gen g0" if g == 0 else ("gen gz" if g == GENS - 1 else "gen")
        groups.append(f'<g class="{cls}" style="animation-delay:{g * GEN_SECONDS - GENS * GEN_SECONDS:.2f}s">{"".join(paths)}</g>')
    loop, slot = GENS * GEN_SECONDS, 100 / GENS
    css = (
        f".gen{{opacity:0;animation:gen {loop:.2f}s step-end infinite}}"
        f"@keyframes gen{{0%{{opacity:1}}{slot:.4f}%{{opacity:0}}100%{{opacity:0}}}}"
        # The seam: the last generation dissolves into the first over one tick.
        f".g0{{animation-name:g0;animation-timing-function:linear}}"
        f"@keyframes g0{{0%{{opacity:1;animation-timing-function:step-end}}{slot:.4f}%{{opacity:0;animation-timing-function:step-end}}"
        f"{100 - slot:.4f}%{{opacity:0;animation-timing-function:linear}}100%{{opacity:1}}}}"
        f".gz{{animation-name:gz;animation-timing-function:linear}}"
        f"@keyframes gz{{0%{{opacity:1;animation-timing-function:linear}}{slot:.4f}%{{opacity:0;animation-timing-function:step-end}}100%{{opacity:0}}}}"
    )
    return "".join(groups), css


# ── The wordmark ───────────────────────────────────────────────────────────
# M is the app's PixelMark (M1K3ScreensaverCore/PixelMark.swift); 1, K and 3 share
# its five-row grid, so the title is made of the same cells as the field.
GLYPHS = {
    "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
    "1": [".#.", "##.", ".#.", ".#.", "###"],
    "K": ["#..#", "#.#.", "##..", "#.#.", "#..#"],
    "3": ["###.", "...#", ".##.", "...#", "###."],
}
CELL = 24  # a 21-px cell (19 + its 2-px rounding stroke) and a 3-px gutter: the M mark's ratio


def wordmark(x0: float, top: float) -> tuple[str, float]:
    cells, x = [], x0
    for ch in TITLE:
        rows = GLYPHS[ch]
        for r, row in enumerate(rows):
            for c, on in enumerate(row):
                if on == "#":
                    cells.append(f"M{x + c * CELL + 2.5:.1f} {top + r * CELL + 2.5:.1f}h19v19h-19z")
        x += (len(rows[0]) + 1) * CELL
    return "".join(cells), x - CELL - x0


# ── Fonts ──────────────────────────────────────────────────────────────────
def font_face(path: Path, family: str, text: str):
    from fontTools import subset  # only the writer needs fonttools (+ brotli for woff2)
    from fontTools.ttLib import TTFont

    font = TTFont(path, recalcTimestamp=False)  # a reproducible SVG: no fresh head.modified per run
    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["kern"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=text)
    subsetter.subset(font)
    buf = io.BytesIO()
    font.save(buf)
    b64 = base64.b64encode(buf.getvalue()).decode()
    css = f"@font-face{{font-family:'{family}';src:url(data:font/woff2;base64,{b64}) format('woff2')}}"
    return css, TTFont(path)


def advance(font, text: str, size: float) -> float:
    cmap, hmtx, upm = font.getBestCmap(), font["hmtx"], font["head"].unitsPerEm
    return sum(hmtx[cmap[ord(ch)]][0] for ch in text) * size / upm


# ── Compose ────────────────────────────────────────────────────────────────
def build() -> str:
    plex_css, plex = font_face(PLEX, "Plex", EYEBROW + TAGLINE + "".join(CHIPS) + FOX_LABEL)
    life, life_css = life_layer()
    fox = fox_layer()

    title_size, title_y = 5 * CELL, 228
    title_d, title_w = wordmark(TX, title_y - title_size)
    tag_size = 30
    tag_w = advance(plex, TAGLINE, tag_size)

    chip_size, chip_h, chip_pad, chip_gap = 15, 32, 14, 10
    chips, cx, cy = [], TX, 334
    for label in CHIPS:
        w = advance(plex, label, chip_size) + chip_pad * 2
        if cx + w > 700:
            cx, cy = TX, cy + chip_h + chip_gap
        chips.append(f'<g class="chip{" lead" if label == CHIPS[0] else ""}"><rect x="{cx}" y="{cy}" width="{w:.1f}" height="{chip_h}" rx="{chip_h / 2}"/>'
                     f'<text x="{cx + chip_pad}" y="{cy + chip_h / 2 + 5.2:.1f}">{label}</text></g>')
        cx += w + chip_gap

    css = f"""{plex_css}
.mono{{font-family:'Plex',ui-monospace,Menlo,monospace}}
.eyebrow{{font-size:14px;letter-spacing:3.2px;fill:{DIM}}}
.title{{fill:url(#ink);stroke:url(#ink);stroke-width:2;stroke-linejoin:round}}
.tag{{font-size:{tag_size}px;fill:{INK}}}
.chip rect{{fill:rgba(232,232,232,.035);stroke:rgba(232,232,232,.28);stroke-width:1}}
.chip text{{font-family:'Plex',ui-monospace,monospace;font-size:{chip_size}px;fill:#cfcfcf}}
.lead rect{{fill:rgba(255,255,255,.09);stroke:rgba(255,255,255,.7)}}.lead text{{fill:{BRIGHT}}}
.label{{font-size:11px;letter-spacing:2.4px;fill:{FAINT}}}
.life{{fill:{INK}}}
.near{{fill:none;stroke:{BRIGHT};stroke-width:2.1;stroke-linejoin:round;stroke-linecap:round;opacity:.92}}
.far{{fill:none;stroke:{INK};stroke-width:1.6;stroke-linejoin:round;stroke-linecap:round;opacity:.30}}
.fox-still{{display:none}}
{life_css}
.shine{{animation:shine 7s cubic-bezier(.5,0,.3,1) infinite}}
@keyframes shine{{0%,55%{{transform:translateX(-260px) skewX(-18deg)}}85%,100%{{transform:translateX({title_w + 200:.0f}px) skewX(-18deg)}}}}
.cursor{{animation:blink 1.1s step-end infinite}}
@keyframes blink{{50%{{opacity:0}}}}
.scan{{animation:scan 6.5s linear infinite}}
@keyframes scan{{0%{{transform:translateY(-140px)}}100%{{transform:translateY({H + 40}px)}}}}
.halo{{animation:breathe 6.8s ease-in-out infinite;transform-origin:{FOX_CX}px {FOX_CY + 30}px}}
@keyframes breathe{{50%{{opacity:.55;transform:scale(1.06)}}}}
@media (prefers-reduced-motion:reduce){{
.gen,.shine,.cursor,.scan,.halo{{animation:none}}
.gen{{opacity:0}}.gen:first-child{{opacity:1}}
.scan{{display:none}}.fox-live{{display:none}}.fox-glow{{display:none}}.fox-still{{display:inline}}
}}"""

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">
<title id="t">M1K3 — local, offline AI. Punk intelligence.</title>
<desc id="d">The Phosphor Fox, a glowing wireframe, surveys a field of Conway's Game of Life beside the pixel wordmark M1K3: local, offline AI. Punk intelligence. No data centers required. Fox model by PixelMannen (CC0); rig and Survey animation by tomkranis (CC BY 4.0).</desc>
<!-- Generated by macos/tools/site/readme_hero_svg.py — edit that, not this. -->
<style>{css}</style>
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0b0b0c"/><stop offset=".55" stop-color="{BG}"/><stop offset="1" stop-color="{NIGHT}"/></linearGradient>
<radialGradient id="halo" cx="{FOX_CX}" cy="{FOX_CY + 30}" r="300" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity=".10"/><stop offset=".5" stop-color="#fff" stop-opacity=".03"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<radialGradient id="floor" cx="{FOX_CX}" cy="{FOX_GROUND}" r="210" gradientTransform="translate(0 {FOX_GROUND}) scale(1 .12) translate(0 -{FOX_GROUND})" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<pattern id="led" width="{PITCH}" height="{PITCH}" patternUnits="userSpaceOnUse"><rect x="3" y="3" width="10" height="10" rx="2.5" fill="{INK}" fill-opacity=".045"/></pattern>
<linearGradient id="ledfade" x1="0" x2="1"><stop offset=".30" stop-color="#fff" stop-opacity=".35"/><stop offset=".62" stop-color="#fff" stop-opacity="1"/></linearGradient>
<mask id="ledmask"><rect width="{W}" height="{H}" fill="url(#ledfade)"/></mask>
<pattern id="scanlines" width="4" height="4" patternUnits="userSpaceOnUse"><rect width="4" height="1.4" fill="#000" fill-opacity=".38"/></pattern>
<linearGradient id="scanband" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".85" stop-color="#fff" stop-opacity=".045"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="ink" x1="0" y1="{title_y - title_size}" x2="0" y2="{title_y}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#a8a8a8"/></linearGradient>
<linearGradient id="shineg" x1="0" x2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".5" stop-color="#fff" stop-opacity=".95"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<clipPath id="titleclip"><path d="{title_d}" stroke="#000" stroke-width="2"/></clipPath>
<filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter>
<filter id="soft" x="-10%" y="-30%" width="120%" height="160%"><feGaussianBlur stdDeviation="9"/></filter>
<filter id="lifeglow" x="0" y="0" width="100%" height="100%"><feGaussianBlur stdDeviation="2.4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<rect width="{W}" height="{H}" fill="url(#led)" mask="url(#ledmask)"/>
<g class="life" filter="url(#lifeglow)">{life}</g>
<circle class="halo" cx="{FOX_CX}" cy="{FOX_CY + 30}" r="300" fill="url(#halo)"/>
<ellipse cx="{FOX_CX}" cy="{FOX_GROUND}" rx="210" ry="26" fill="url(#floor)"/>
<g class="fox-glow" opacity=".55" filter="url(#glow)"><use href="#fxN" class="near" transform="scale(.5)"/></g>
{fox}
<text class="mono label" x="{FOX_CX}" y="{H - 22}" text-anchor="middle">{FOX_LABEL}</text>
<text class="mono eyebrow" x="{TX}" y="90">{EYEBROW}</text>
<path class="title" d="{title_d}" filter="url(#soft)" opacity=".5"/>
<path class="title" d="{title_d}"/>
<g clip-path="url(#titleclip)"><rect class="shine" x="{TX}" y="{title_y - title_size}" width="120" height="{title_size + 20}" fill="url(#shineg)" opacity=".8"/></g>
<text class="mono tag" x="{TX}" y="{title_y + 58}">{TAGLINE}</text>
<rect class="cursor" x="{TX + tag_w + 6:.1f}" y="{title_y + 58 - tag_size * 0.78:.1f}" width="{tag_size * 0.52:.1f}" height="{tag_size * 0.95:.1f}" fill="{INK}"/>
{"".join(chips)}
<rect class="scan" width="{W}" height="140" fill="url(#scanband)"/>
<rect width="{W}" height="{H}" fill="url(#scanlines)" opacity=".5"/>
</svg>
"""


FREEZE = """<script><![CDATA[
const T = parseFloat(location.hash.slice(1)) || 0;
document.documentElement.pauseAnimations(); document.documentElement.setCurrentTime(T);
for (const a of document.getAnimations()) { a.pause(); a.currentTime = T * 1000; }
]]></script></svg>"""


def preview(svg: str, seconds: list[float], out: Path) -> None:
    """A contact sheet frozen at each time. Headless Chrome's clock won't step animations
    reliably, so a throwaway copy pauses SMIL and CSS and seeks both."""
    with tempfile.TemporaryDirectory() as tmp:
        here = Path(tmp)
        (here / "frozen.svg").write_text(svg.rstrip().removesuffix("</svg>") + FREEZE)
        frames = "".join(f'<iframe src="frozen.svg#{t}" width="{W}" height="{H}" style="border:0;display:block"></iframe>' for t in seconds)
        (here / "sheet.html").write_text(f'<html><body style="margin:0;background:#222">{frames}</body></html>')
        subprocess.run([os.environ.get("CHROME", DEFAULT_CHROME), "--headless=new", "--hide-scrollbars",
                        "--allow-file-access-from-files", "--virtual-time-budget=3000", f"--window-size={W},{H * len(seconds)}",
                        f"--screenshot={out.resolve()}", f"file://{here}/sheet.html"], stderr=subprocess.DEVNULL, check=True, timeout=60)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--preview", help="comma-separated seconds for a frozen contact sheet")
    parser.add_argument("--sheet", type=Path, default=Path("readme-hero-sheet.png"))
    args = parser.parse_args(argv)
    svg = build()
    OUTPUT.write_text(svg)
    print(f"wrote {OUTPUT.relative_to(REPO)} ({len(svg.encode()) / 1024:.0f} KB)")
    if args.preview:
        preview(svg, [float(t) for t in args.preview.split(",")], args.sheet)
        print(f"wrote {args.sheet}")


if __name__ == "__main__":
    main()
