#!/usr/bin/env python3
"""Render M1K3's App Store in-app event art — the event card (16:9) and the event details
page (9:16) — from the store creative's own parts: the Phosphor Fox from the site's GLB,
a Game of Life field, textless.

    python3 tools/site/event_art.py --palette halloween                 # both JPEGs + a spec check
    python3 tools/site/event_art.py --palette halloween --guides        # + proofs with the safe area drawn
    python3 tools/site/event_art.py --palette halloween --check         # spec-check what's in --out

Writes `event-card-1920x1080.jpg` and `event-details-1080x1920.jpg`, the stills
tools/asc/events.py uploads when a slot has no video, into marketing/events/<palette>/
(gitignored: binaries stay out of the tree; `--out` elsewhere to keep the stills already
there). JPEG at quality 90, sRGB-tagged, exact pixel sizes.

Palettes: `phosphor` is the default and is the store creative's own (white phosphor on
the hero's black), so a future event starts from the brand; `halloween` is the app's
seasonal look, colour for colour (PUMPKIN fox, EMBER halo, VIOLET thought, NIGHT sky),
plus a harvest moon made of the field's own cells with Life gliders for bats.

Specs: Apple's media table (developer.apple.com/help/app-store-connect/reference/
in-app-event-media-and-audio-specifications, read 2026-10-11): card 16:9 at 1920×1080 to
3840×2160, details 9:16 at 1080×1920 to 2160×3840, .jpg/.png, 500 MB. Apple publishes no
safe area for events — it says to check ASC's preview and to keep text and logos out of
the media. The safe area here is a measured third-party read (yellowhead.com: top 5% / 8%,
bottom 40%, sides 6% at risk under the store's overlays), which also keeps the fox in the
upper-centre 60% and the bottom third quiet for the badge, name and description.

Needs numpy; rendering needs rsvg-convert (librsvg), ffmpeg and macOS's sips; tests need
only numpy.

Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.7. Prior: store_creative.py
(Kev + claude-opus-5-5, 2026-10-07) and readme_hero_svg.py (PR #505) — the fox, Life and
the rasterizer are imported from them, not copied; the palettes, the event canvases, the
moon and the bats are new. The safe area is a third party's measurement, not Apple's:
UNVERIFIED until ASC's event preview shows the card and the details page.
Review: Kev + claude-opus-5-5, 2026-10-14 — docstring only: Halloween's slots are video now
(a 3D render from the private motion project), so these stills are the fallback events.py
uploads when a slot has no video, and the default --out would overwrite the stills that sit
beside the videos. Confidence unchanged (0.7).
"""
from __future__ import annotations

import argparse
import math
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from functools import cache
from pathlib import Path

import numpy as np
from readme_hero_svg import (
    BG,
    BRIGHT,
    DENSITY,
    FOX_SCALE,
    INK,
    MAX_AGE,
    NIGHT,
    REPO,
    SEED,
    _path_d,
    life_run,
    life_step,
)
from store_creative import (
    BUCKETS,
    CELLS_PER_FOX,
    FIELD_GAIN,
    LIFE_START,
    MAX_FILE,
    Canvas,
    _fox,
    _tool,
    opaque,
    rasterize,
)

# The app's Halloween look (shared with the app's theme — exact, never "close enough").
PUMPKIN, EMBER, VIOLET, HALLOWEEN_NIGHT = "#FF8A1F", "#FFB347", "#9B5CFF", "#0A0610"

JPEG_QUALITY = 90
SRGB_ICC = Path("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
OUT = REPO / "marketing/events"


@dataclass(frozen=True)
class Palette:
    name: str
    bg: tuple[str, str, str]              # the background gradient's three stops
    grid: str                             # the LED dot grid
    grid_opacity: float
    fox: str                              # the near flank
    far: str                              # the far flank, sunk back
    glow: str                             # the blur behind the near flank
    halo: str                             # the fox's halo and floor
    life: tuple[str, str, str, str]       # Life by age bucket, newborn → oldest (BUCKETS' order)
    life_gain: float = 1.0
    moon: str | None = None               # the moon's cells; None = no moon
    moon_glow: str | None = None
    bat: str | None = None                # the gliders' silhouette against the moon
    body_opacity: float = 0.0             # a solid fox behind the strokes (in the night colour), so a moon can't show through it


PALETTES = {
    # The store creative's palette, stop for stop — so `phosphor` art sits beside the header.
    "phosphor": Palette("phosphor", ("#0b0b0c", BG, NIGHT), INK, 0.045, BRIGHT, INK, BRIGHT, BRIGHT, (INK, INK, INK, INK)),
    # Newborn cells burn ember, cool through pumpkin, and settle to violet ash: phosphor decay.
    "halloween": Palette("halloween", (HALLOWEEN_NIGHT,) * 3, VIOLET, 0.07, PUMPKIN, VIOLET, EMBER, EMBER,
                         (EMBER, PUMPKIN, VIOLET, VIOLET), life_gain=0.85,
                         moon=EMBER, moon_glow=PUMPKIN, bat=HALLOWEEN_NIGHT, body_opacity=0.85),
}
DEFAULT_PALETTE = "phosphor"


def safe_area(w: int, h: int, top: float, bottom: float, side: float) -> tuple[int, int, int, int]:
    """x, y, w, h of the region clear of the store's overlays, from the fractions at risk."""
    x, y = round(side * w), round(top * h)
    return x, y, w - 2 * x, round((1 - bottom) * h) - y


EVENT_CARD, EVENT_DETAILS = "EVENT_CARD", "EVENT_DETAILS_PAGE"
CANVASES = {
    "card": Canvas("event-card", 1920, 1080, safe_area(1920, 1080, 0.05, 0.40, 0.06), (EVENT_CARD,)),
    "details": Canvas("event-details", 1080, 1920, safe_area(1080, 1920, 0.08, 0.40, 0.06), (EVENT_DETAILS,)),
}


@dataclass(frozen=True)
class Layout:
    fill: float                           # the fox, as a fraction of the safe area's tighter axis
    floor: float                          # where its feet stand, as a fraction down the safe area
    shift: float                          # its centre's offset across, in fox widths
    moon: tuple[float, float, float]      # centre (fox widths from the fox's centre, fox heights from its top), radius in fox heights
    bats: tuple[tuple[float, float, int], ...]   # each glider: (x, y) as fractions of the moon's radius from its centre, phase


LAYOUTS = {
    "event-card": Layout(fill=0.64, floor=0.97, shift=-0.08, moon=(0.28, 0.22, 0.68),
                         bats=((-0.42, -0.40, 0), (-0.02, -0.66, 1), (0.40, -0.30, 2))),
    "event-details": Layout(fill=0.80, floor=0.97, shift=0.0, moon=(0.08, -0.36, 0.78),
                            bats=((-0.46, -0.38, 0), (0.0, -0.66, 1), (0.42, -0.24, 2))),
}

POSE = 30          # the Survey frame the stills hold (of 180 in a turn; chosen by eye)
LIFE_GEN = 2       # the field's generation past LIFE_START (the store poster's)
QUIET = 0.14       # the field's ceiling in the bottom third, where the store lays its text

# A glider heading up and left (the classic one turned half round); its four phases are Life's own.
GLIDER = ((0, 0), (0, 1), (0, 2), (1, 0), (2, 1))


@cache
def glider_phases() -> tuple[tuple[tuple[int, int], ...], ...]:
    """The glider's four phases, each normalised to its own top-left, by stepping B3/S23."""
    board = np.zeros((10, 10), np.uint8)
    for r, c in GLIDER:
        board[r + 4, c + 4] = 1
    out = []
    for _ in range(4):
        cells = np.argwhere(board > 0)
        out.append(tuple(sorted((int(r), int(c)) for r, c in cells - cells.min(0))))
        board = life_step(board)
    return tuple(out)


@cache
def _triangles() -> np.ndarray:
    """The fox's triangles over its welded vertices (Fox welds the same way but keeps only edges)."""
    fox = _fox()[0]
    skinned = next(n for n in fox.gltf["nodes"] if "skin" in n and "mesh" in n)
    prim = fox.gltf["meshes"][skinned["mesh"]]["primitives"][0]
    pos = fox.accessor(prim["attributes"]["POSITION"])
    tris = (fox.accessor(prim["indices"]) if "indices" in prim else np.arange(len(pos))).astype(int).reshape(-1, 3)
    _, inverse = np.unique(np.round(pos, 4), axis=0, return_inverse=True)
    welded = inverse.reshape(-1)[tris]
    return welded[(welded[:, 0] != welded[:, 1]) & (welded[:, 1] != welded[:, 2]) & (welded[:, 0] != welded[:, 2])]


def life_colour(palette: Palette, age: int) -> str:
    for (lo, hi, _), colour in zip(BUCKETS, palette.life):
        if lo <= age <= hi:
            return colour
    raise ValueError(f"age {age} outside 1…{MAX_AGE}")


def asset_name(canvas: Canvas) -> str:
    return f"{canvas.name}-{canvas.w}x{canvas.h}.jpg"


def guides_name(canvas: Canvas) -> str:
    return f"{canvas.name}-{canvas.w}x{canvas.h}-guides.png"


class EventScene:
    """One still: the fox fitted to the canvas's safe area, the field at its pitch, and in a
    palette with a moon, the moon behind the fox with gliders crossing it."""

    def __init__(self, canvas: Canvas, palette: Palette) -> None:
        self.canvas, self.palette = canvas, palette
        _, self.near, self.far, raw = _fox()
        lay = LAYOUTS[canvas.name]
        pose = raw[POSE]
        sx, sy, sw, sh = canvas.safe
        lo, hi = pose.min(0), pose.max(0)
        fw, fh = hi - lo
        self.scale = lay.fill * min(sw / fw, sh / fh)
        anchor = np.array([sx + sw / 2 + lay.shift * fw * self.scale, sy + sh * lay.floor])
        self.points = np.round(((pose - ((lo[0] + hi[0]) / 2, hi[1])) * self.scale + anchor) * 2).astype(int)
        flat = self.points / 2
        x0, y0 = flat.min(0)
        x1, y1 = flat.max(0)
        self.fox_box = (float(x0), float(y0), float(x1), float(y1))
        self.k = self.scale / FOX_SCALE
        self.pitch = max(8, round((y1 - y0) / CELLS_PER_FOX))
        self.cols, self.rows = math.ceil(canvas.w / self.pitch), math.ceil(canvas.h / self.pitch)
        self.ages = life_run(self.cols, self.rows, DENSITY, SEED, LIFE_START + LIFE_GEN)[LIFE_START + LIFE_GEN]
        self.moon: tuple[float, float, float] | None = None
        self.bats: list[list[tuple[int, int]]] = []
        if palette.moon:
            mx, my, mr = lay.moon
            w, h = x1 - x0, y1 - y0
            self.moon = ((x0 + x1) / 2 + mx * w, y0 + my * h, mr * h)
            cx, cy, r = self.moon
            for bx, by, phase in lay.bats:
                row, col = int((cy + by * r) // self.pitch), int((cx + bx * r) // self.pitch)
                self.bats.append([(row + dr, col + dc) for dr, dc in glider_phases()[phase % 4]])

    def fox_points(self) -> np.ndarray:
        """The fox's vertices, in half-pixel integers."""
        return self.points

    def field_mask(self, x: float, y: float) -> float:
        """How much of the field may show here: a whisper on the fox and on the moon (so the
        bats read alone), full across the safe area, quiet in the bottom third where the store
        lays the badge, name and description, fading to the corners."""
        x0, y0, x1, y1 = self.fox_box
        dx, dy = (x - (x0 + x1) / 2) / ((x1 - x0) * 0.62), (y - (y0 + y1) / 2) / ((y1 - y0) * 0.62)
        fox = min(1.0, max(0.12, (math.hypot(dx, dy) - 0.55) / 0.75))
        moon = 1.0
        if self.moon:
            cx, cy, r = self.moon
            moon = min(1.0, max(0.1, (math.hypot(x - cx, y - cy) / r - 0.9) / 0.3))
        W, H = self.canvas.w, self.canvas.h
        _, top, _, height = self.canvas.safe
        bottom, quiet = top + height, H * 2 / 3
        if y < top:
            band = 1 - 0.4 * (top - y) / top
        elif y <= bottom:
            band = 1.0
        elif y < quiet:
            u = (y - bottom) / (quiet - bottom)
            band = 1 - (1 - QUIET) * u * u * (3 - 2 * u)        # smoothstep down to the ceiling
        else:
            band = QUIET * (1 - (y - quiet) / (H - quiet))
        corner = math.hypot((x - W / 2) / (W / 2), (y - H / 2) / (H / 2)) / math.sqrt(2)
        return FIELD_GAIN * self.palette.life_gain * fox * moon * band * (1 - 0.6 * corner * corner)

    # ── layers ──
    def _cell(self, r: int, c: int) -> str:
        p = self.pitch
        side, inset = p * 10 / 16, p * 3 / 16
        return f"M{c * p + inset:.1f} {r * p + inset:.1f}h{side:.1f}v{side:.1f}h-{side:.1f}z"

    def _life(self) -> str:
        p, groups = self.pitch, {}
        for r, c in zip(*np.nonzero(self.ages)):
            age = int(self.ages[r, c])
            level = next(o for lo, hi, o in BUCKETS if lo <= age <= hi)
            o = round(level * self.field_mask(c * p + p / 2, r * p + p / 2) / 0.02) * 0.02
            if o >= 0.06:
                groups.setdefault((life_colour(self.palette, age), o), []).append(self._cell(int(r), int(c)))
        return "".join(f'<path d="{"".join(d)}" fill="{colour}" fill-opacity="{o:.2f}"/>'
                       for (colour, o), d in sorted(groups.items()))

    def _moon(self) -> str:
        if not self.moon:
            return ""
        cx, cy, r = self.moon
        p, pal = self.pitch, self.palette
        bat_cells = {cell for bat in self.bats for cell in bat}
        # Maria: soft dark seas, placed as a full moon shows them, as fractions of the radius.
        seas = ((-0.28, -0.22, 0.30, 0.45), (0.18, -0.30, 0.24, 0.40), (0.05, 0.18, 0.34, 0.40), (-0.30, 0.30, 0.18, 0.30))
        groups: dict[float, list[str]] = {}
        for row in range(int((cy - r) // p), int((cy + r) // p) + 1):
            for col in range(int((cx - r) // p), int((cx + r) // p) + 1):
                d = math.hypot(col * p + p / 2 - cx, row * p + p / 2 - cy) / r
                if d > 1 or (row, col) in bat_cells:
                    continue
                u, v = (col * p + p / 2 - cx) / r, (row * p + p / 2 - cy) / r
                sea = sum(a * math.exp(-((u - su) ** 2 + (v - sv) ** 2) / (2 * s * s)) for su, sv, s, a in seas)
                o = 0.24 * (1 - 0.4 * d * d) * (1 - min(0.55, sea))
                groups.setdefault(round(o / 0.02) * 0.02, []).append(self._cell(row, col))
        cells = "".join(f'<path d="{"".join(d)}" fill-opacity="{o:.2f}"/>' for o, d in sorted(groups.items()))
        bats = "".join(self._cell(row, col) for bat in self.bats for row, col in bat)
        return (f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r * 1.45:.1f}" fill="url(#moonglow)"/>'
                f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{pal.moon}" fill-opacity=".07"/>'
                f'<g fill="{pal.moon}" filter="url(#lifeglow)">{cells}</g>'
                f'<path d="{bats}" fill="{pal.bat}" fill-opacity=".92"/>')

    def _body(self) -> str:
        if not self.palette.body_opacity:
            return ""
        pts = self.points
        d = "".join(f"M{pts[a][0]} {pts[a][1]}L{pts[b][0]} {pts[b][1]}L{pts[c][0]} {pts[c][1]}z" for a, b, c in _triangles())
        return (f'<path transform="scale(.5)" d="{d}" fill="{self.palette.bg[0]}" fill-opacity="{self.palette.body_opacity}" '
                f'stroke="{self.palette.bg[0]}" stroke-opacity="{self.palette.body_opacity}" stroke-width="{2 * self.k:.2f}" stroke-linejoin="round"/>')

    def svg(self, guides: bool = False) -> str:
        cv, pal, k, p = self.canvas, self.palette, self.k, self.pitch
        W, H = cv.w, cv.h
        x0, y0, x1, y1 = self.fox_box
        fx, fy, ground = (x0 + x1) / 2, (y0 + y1) / 2, y1
        side, inset = p * 10 / 16, p * 3 / 16
        near, far = _path_d(self.points, self.near), _path_d(self.points, self.far)
        moon_glow = ""
        if self.moon:
            cx, cy, r = self.moon
            moon_glow = (f'<radialGradient id="moonglow" cx="{cx:.1f}" cy="{cy:.1f}" r="{r * 1.45:.1f}" gradientUnits="userSpaceOnUse">'
                         f'<stop offset=".55" stop-color="{pal.moon_glow}" stop-opacity=".16"/>'
                         f'<stop offset=".72" stop-color="{pal.moon_glow}" stop-opacity=".06"/>'
                         f'<stop offset="1" stop-color="{pal.moon_glow}" stop-opacity="0"/></radialGradient>')
        guide = ""
        if guides:
            sx, sy, sw, sh = cv.safe
            line = max(2, W // 640)
            guide = (f'<rect width="{W}" height="{sy}" fill="#f00" fill-opacity=".18"/>'
                     f'<rect y="{sy + sh}" width="{W}" height="{H - sy - sh}" fill="#f00" fill-opacity=".18"/>'
                     f'<line x1="0" y1="{H * 2 / 3:.0f}" x2="{W}" y2="{H * 2 / 3:.0f}" stroke="#ff0" stroke-width="{line}" stroke-dasharray="{line * 6} {line * 4}"/>'
                     f'<rect x="{sx}" y="{sy}" width="{sw}" height="{sh}" fill="#0f0" fill-opacity=".10" stroke="#0f0" stroke-width="{line}"/>')
        return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{pal.bg[0]}"/><stop offset=".55" stop-color="{pal.bg[1]}"/><stop offset="1" stop-color="{pal.bg[2]}"/></linearGradient>
<pattern id="led" width="{p}" height="{p}" patternUnits="userSpaceOnUse"><rect x="{inset:.1f}" y="{inset:.1f}" width="{side:.1f}" height="{side:.1f}" rx="{p * 2.5 / 16:.1f}" fill="{pal.grid}" fill-opacity="{pal.grid_opacity}"/></pattern>
<mask id="ledmask"><radialGradient id="vig" cx="{fx:.0f}" cy="{fy:.0f}" r="{math.hypot(W, H) / 2:.0f}" gradientUnits="userSpaceOnUse"><stop offset=".2" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity=".3"/></radialGradient><rect width="{W}" height="{H}" fill="url(#vig)"/></mask>
<radialGradient id="halo" cx="{fx:.1f}" cy="{fy + 30 * k:.1f}" r="{300 * k:.1f}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{pal.halo}" stop-opacity=".12"/><stop offset=".5" stop-color="{pal.halo}" stop-opacity=".035"/><stop offset="1" stop-color="{pal.halo}" stop-opacity="0"/></radialGradient>
<radialGradient id="floor" cx="{fx:.1f}" cy="{ground:.1f}" r="{210 * k:.1f}" gradientTransform="translate(0 {ground:.1f}) scale(1 .12) translate(0 {-ground:.1f})" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{pal.halo}" stop-opacity=".18"/><stop offset="1" stop-color="{pal.halo}" stop-opacity="0"/></radialGradient>
{moon_glow}
<filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="{5 * k:.1f}"/></filter>
<filter id="lifeglow" x="0" y="0" width="100%" height="100%"><feGaussianBlur stdDeviation="{2.4 * p / 16:.2f}" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<rect width="{W}" height="{H}" fill="url(#led)" mask="url(#ledmask)"/>
{self._moon()}
<g filter="url(#lifeglow)">{self._life()}</g>
{self._body()}
<circle cx="{fx:.1f}" cy="{fy + 30 * k:.1f}" r="{300 * k:.1f}" fill="url(#halo)"/>
<ellipse cx="{fx:.1f}" cy="{ground:.1f}" rx="{210 * k:.1f}" ry="{26 * k:.1f}" fill="url(#floor)"/>
<g opacity=".55" filter="url(#glow)"><path transform="scale(.5)" d="{near}" fill="none" stroke="{pal.glow}" stroke-width="{4.2 * k:.2f}" stroke-linejoin="round" stroke-linecap="round"/></g>
<path transform="scale(.5)" d="{far}" fill="none" stroke="{pal.far}" stroke-width="{3.2 * k:.2f}" stroke-linejoin="round" stroke-linecap="round" opacity=".30"/>
<path transform="scale(.5)" d="{near}" fill="none" stroke="{pal.fox}" stroke-width="{4.2 * k:.2f}" stroke-linejoin="round" stroke-linecap="round" opacity=".92"/>
{guide}</svg>
"""


# ── The spec check, run on rendered files before anything is uploaded ─────
_SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def jpeg_problems(path: Path, canvas: Canvas) -> list[str]:
    """Problems with a rendered JPEG, as text — a broken file is a finding, never a crash."""
    path = Path(path)
    raw = path.read_bytes()
    if raw[:2] != b"\xff\xd8":
        return [f"{path.name}: not a JPEG"]
    at, frame = 2, None
    while at + 4 <= len(raw) and raw[at] == 0xFF:
        marker, length = raw[at + 1], int.from_bytes(raw[at + 2 : at + 4], "big")
        if marker in _SOF and at + 10 <= len(raw):
            h, w, components = int.from_bytes(raw[at + 5 : at + 7], "big"), int.from_bytes(raw[at + 7 : at + 9], "big"), raw[at + 9]
            frame = (w, h, components)
            break
        if marker == 0xDA:          # start of scan: entropy-coded data follows, no frame header came first
            break
        at += 2 + length
    if frame is None:
        return [f"{path.name}: no frame header (SOF) — truncated or malformed"]
    w, h, components = frame
    problems = []
    if (w, h) != (canvas.w, canvas.h):
        problems.append(f"{path.name}: {w}×{h}, expected {canvas.w}×{canvas.h}")
    if components == 4:
        problems.append(f"{path.name}: 4 components (CMYK/YCCK) — the store wants RGB")
    elif components != 3:
        problems.append(f"{path.name}: {components} component(s), expected 3 (RGB)")
    if not raw.endswith(b"\xff\xd9"):
        problems.append(f"{path.name}: truncated (no end-of-image marker)")
    if len(raw) > MAX_FILE:
        problems.append(f"{path.name}: {len(raw)} bytes, over 500 MB")
    return problems


def check(out_dir: Path, canvases: list[Canvas] | None = None) -> int:
    """Spec-check the rendered card and details: every one must exist and pass."""
    bad = 0
    for canvas in canvases or list(CANVASES.values()):
        path = Path(out_dir) / asset_name(canvas)
        problems = jpeg_problems(path, canvas) if path.exists() else [f"{path.name}: missing"]
        bad += bool(problems)
        print(("✗ " if problems else "✓ ") + path.name + "".join(f"\n    {p}" for p in problems))
    return 1 if bad else 0


# ── Rendering ──────────────────────────────────────────────────────────────
def to_jpeg(png: Path, out: Path) -> None:
    """Opaque PNG → JPEG at JPEG_QUALITY, tagged sRGB (assigned, not converted: rsvg's pixels are sRGB already)."""
    sips = _tool("sips", "macOS's sips renders the JPEG")
    if not SRGB_ICC.exists():
        raise SystemExit(f"{SRGB_ICC} not found")
    subprocess.run([sips, "-s", "format", "jpeg", "-s", "formatOptions", str(JPEG_QUALITY),
                    "--embedProfile", str(SRGB_ICC), str(png), "--out", str(out)], check=True, capture_output=True)


def render(canvas: Canvas, palette: Palette, out_dir: Path) -> Path:
    out = out_dir / asset_name(canvas)
    with tempfile.TemporaryDirectory() as tmp:
        raw, flat = Path(tmp) / "raw.png", Path(tmp) / "flat.png"
        rasterize(EventScene(canvas, palette).svg(), raw)
        opaque(raw, flat)
        to_jpeg(flat, out)
    return out


def _canvas_names(arg: str) -> list[str]:
    names = [n.strip() for n in arg.split(",") if n.strip()]
    if unknown := [n for n in names if n not in CANVASES]:
        raise argparse.ArgumentTypeError(f"unknown canvas {', '.join(unknown)} (have {', '.join(CANVASES)})")
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--palette", choices=list(PALETTES), default=DEFAULT_PALETTE)
    parser.add_argument("--out", type=Path, help="default: marketing/events/<palette>")
    parser.add_argument("--only", type=_canvas_names, default=list(CANVASES), help="comma-separated: card,details")
    parser.add_argument("--guides", action="store_true", help="also write proofs with the safe area drawn")
    parser.add_argument("--check", action="store_true", help="only spec-check what's in --out")
    args = parser.parse_args(argv)
    out = args.out or OUT / args.palette
    out.mkdir(parents=True, exist_ok=True)
    canvases = [CANVASES[n] for n in args.only]
    if args.check:
        return check(out, canvases)
    palette = PALETTES[args.palette]
    for canvas in canvases:
        print(f"wrote {render(canvas, palette, out)}")
        if args.guides:
            path = out / guides_name(canvas)
            rasterize(EventScene(canvas, palette).svg(guides=True), path)
            print(f"wrote {path}")
    return check(out, canvases)


if __name__ == "__main__":
    sys.exit(main())
