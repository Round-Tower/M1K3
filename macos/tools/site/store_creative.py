#!/usr/bin/env python3
"""Render M1K3's App Store creative assets — the product page header and the search
results image (iOS / iPadOS 27) — from the README hero's own parts.

    python3 tools/site/store_creative.py                   # header, search + universal PNGs
    python3 tools/site/store_creative.py --video           # + the 24 s seamless loops (MP4)
    python3 tools/site/store_creative.py --guides 0,6.5    # small proofs with Apple's safe area drawn
    python3 tools/site/store_creative.py --check           # spec-check what's already rendered

Textless on purpose: the store draws the app's name, icon and Get button over the art, and
art with no words ships to every locale unchanged. The scene is the hero's: a Game of Life
field (LifeField.swift's rules and seed) with the Phosphor Fox surveying it, centred in the
art safe area so no device's crop can clip it. Every frame is a static SVG computed from
its frame number, so the loop closes exactly: Life plays 48 generations, crossfading each
into the next (the last into the first), the fox turns through Survey four times, the halo
breathes three.

Specs are App Store Connect's own catalogue (GET /v1/appAssetLibraryRefData, read
2026-10-07): header i3840x1646 (PNG only), search 3:2 at 1920–3840 wide, universal
i5244x2950 (PNG only, satisfies both); video 30 or 60 fps, 5–30 s, header 3840×1646 and
search 3:2. Safe areas are the "Art Safe Area" layers of Apple's creative-assets templates
(developer.apple.com/app-store/asset-best-practices). Re-read both when Apple changes them.

Needs numpy; rendering needs rsvg-convert (librsvg) and ffmpeg/ffprobe; tests need only numpy.

Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.7. Prior: Unknown (new file;
the scene is readme_hero_svg.py's, PR #505, re-laid for Apple's canvases). The specs and
safe areas are read from Apple, not guessed; how the header sits under the store's own
chrome on a device is UNVERIFIED until ASC's Preview or an iOS 27 device shows it.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from functools import cache
from pathlib import Path

import numpy as np
from readme_hero_svg import (
    BG,
    BRIGHT,
    DENSITY,
    FOX_GLB,
    FOX_SCALE,
    INK,
    MAX_AGE,
    NIGHT,
    REPO,
    SEED,
    Fox,
    _path_d,
    life_run,
    project,
    strokes,
)

OUT = REPO / "marketing/app-store/out/creative"
MAX_FILE = 524_288_000   # every creative spec's maxFileSize


@dataclass(frozen=True)
class Canvas:
    name: str
    w: int
    h: int
    safe: tuple[int, int, int, int]      # x, y, w, h of Apple's art safe area
    placements: tuple[str, ...]
    video: tuple[int, int] | None = None  # the loop's size; None = the spec has no video

    @property
    def file_stem(self) -> str:
        return f"m1k3-{self.name}-{self.w}x{self.h}"

    def scaled(self, w: int, h: int) -> Canvas:
        """The same composition at another size (the safe area scales with it)."""
        sx, sy = w / self.w, h / self.h
        x, y, sw, sh = self.safe
        return Canvas(self.name, w, h, (round(x * sx), round(y * sy), round(sw * sx), round(sh * sy)),
                      self.placements, self.video)


HEADER, SEARCH = "PRODUCT_PAGE_HEADER_ASSET", "APP_STORE_SEARCH_RESULTS_ASSET"
CANVASES = {
    "header": Canvas("header", 3840, 1646, (1097, 493, 1646, 661), (HEADER,), video=(3840, 1646)),
    # The search loop is 3072×2048, not 3840×2560: 3:2 is the spec's whole range, and 3840×2560
    # is more macroblocks than H.264 level 5.1 decodes (36,864); 3072×2048 is 24,576.
    "search": Canvas("search", 3840, 2560, (836, 765, 2168, 1030), (SEARCH,), video=(3072, 2048)),
    # One file, both placements. Its safe area sits high: the header's crop of it is top-anchored.
    "universal": Canvas("universal", 5244, 2950, (1921, 660, 1402, 962), (HEADER, SEARCH)),
}

# ── The clock: everything a whole number of cycles in LOOP, so frame N == frame 0 ──
FPS = 30
GENS, GEN_SECONDS = 48, 0.5      # slower than the README's 0.4 s: a header plays big
LOOP = GENS * GEN_SECONDS        # 24 s
FRAMES = round(LOOP * FPS)       # 720: frame FRAMES is frame 0
FADE = 0.2                       # each generation dissolves in over 6 frames, never a hard cut
FOX_PERIOD = LOOP / 4            # 6 s a turn: Survey (3.42 s) slowed ~1.76×
HALO_PERIOD = LOOP / 3           # 8 s a breath
LIFE_START = 90                  # mid-run, past the soup's first burn-off
POSTER = 1.0                     # the still's moment

FOX_FILL = 0.86                  # of the safe area, in the tighter axis
FIELD_GAIN = 0.8                 # the field is ambience; at header size the hero's full strength shouts
CELLS_PER_FOX = 14               # Life's pitch, in fox heights: the README's ratio
BUCKETS = [(1, 1, 0.62), (2, 4, 0.44), (5, 12, 0.30), (13, MAX_AGE, 0.20)]   # the hero's age curve


@cache
def _fox() -> tuple[Fox, list[list[int]], list[list[int]], np.ndarray]:
    """The fox, its near/far stroke split, and its Survey poses for one turn, in model units
    (x right, y down from the floor) — shared by every canvas."""
    fox = Fox(FOX_GLB)
    duration = fox.clip_duration("Survey")
    rest = project(fox.posed("Survey", 0))
    centre, floor = (rest[:, 0].min() + rest[:, 0].max()) / 2, rest[:, 1].min()
    flank = [(fox.pos[a, 0] + fox.pos[b, 0]) / 2 for a, b in fox.edges]
    near = strokes([tuple(e) for e, x in zip(fox.edges, flank) if x >= -0.5])
    far = strokes([tuple(e) for e, x in zip(fox.edges, flank) if x < -0.5])
    turn = round(FOX_PERIOD * FPS)
    poses = []
    for k in range(turn):
        q = project(fox.posed("Survey", duration * k / turn))
        poses.append(np.c_[q[:, 0] - centre, -(q[:, 1] - floor)])
    return fox, near, far, np.stack(poses)


class Scene:
    """One canvas's layout: the fox fitted to the safe area, the Life field at its pitch."""

    def __init__(self, canvas: Canvas) -> None:
        self.canvas = canvas
        _, self.near, self.far, raw = _fox()
        sx, sy, sw, sh = canvas.safe
        lo, hi = raw.reshape(-1, 2).min(0), raw.reshape(-1, 2).max(0)
        self.scale = FOX_FILL * min(sw / (hi[0] - lo[0]), sh / (hi[1] - lo[1]))
        mid = (lo + hi) / 2
        self.poses = np.round(((raw - mid) * self.scale + (sx + sw / 2, sy + sh / 2)) * 2).astype(int)
        flat = self.poses.reshape(-1, 2) / 2
        x0, y0 = flat.min(0)
        x1, y1 = flat.max(0)
        self.fox_box = (float(x0), float(y0), float(x1), float(y1))
        self.k = self.scale / FOX_SCALE          # stroke widths, glow and halo scale with the fox
        self.pitch = max(8, round((y1 - y0) / CELLS_PER_FOX))
        self.cols, self.rows = math.ceil(canvas.w / self.pitch), math.ceil(canvas.h / self.pitch)
        ages = life_run(self.cols, self.rows, DENSITY, SEED, LIFE_START + GENS)[LIFE_START : LIFE_START + GENS]
        half = self.pitch / 2
        mask = np.array([[self.field_mask(c * self.pitch + half, r * self.pitch + half)
                          for c in range(self.cols)] for r in range(self.rows)])
        self.levels = [self._bucket(a) * mask for a in ages]

    @staticmethod
    def _bucket(ages: np.ndarray) -> np.ndarray:
        out = np.zeros(ages.shape)
        for lo, hi, opacity in BUCKETS:
            out[(ages >= lo) & (ages <= hi)] = opacity
        return out

    def field_mask(self, x: float, y: float) -> float:
        """How much of the field may show here: a whisper on the fox, quieter in the bands
        above and below the safe area (where the store lays its own title, icon and Get
        button over the art), fading to the corners."""
        x0, y0, x1, y1 = self.fox_box
        dx, dy = (x - (x0 + x1) / 2) / ((x1 - x0) * 0.62), (y - (y0 + y1) / 2) / ((y1 - y0) * 0.62)
        fox = min(1.0, max(0.12, (math.hypot(dx, dy) - 0.55) / 0.75))
        W, H = self.canvas.w, self.canvas.h
        _, top, _, height = self.canvas.safe
        bottom = top + height
        band = 1 - 0.55 * (y - bottom) / (H - bottom) if y > bottom else 1 - 0.4 * (top - y) / top if y < top else 1.0
        corner = math.hypot((x - W / 2) / (W / 2), (y - H / 2) / (H / 2)) / math.sqrt(2)
        return FIELD_GAIN * fox * band * (1 - 0.6 * corner * corner)

    # ── time ──
    @staticmethod
    def _frame(t: float) -> int:
        """Frame number within the loop: every motion reads time from here, so frame FRAMES is frame 0."""
        return round(t * FPS) % FRAMES

    def fox_points(self, t: float) -> np.ndarray:
        """The fox's vertices at time t, in half-pixel integers."""
        return self.poses[self._frame(t) % len(self.poses)]

    def cell_opacities(self, t: float) -> dict[tuple[int, int], float]:
        """Each lit cell's opacity at time t: this generation crossfading in over the last."""
        per_gen = round(GEN_SECONDS * FPS)
        g, into = divmod(self._frame(t) % (GENS * per_gen), per_gen)
        fade = min(1.0, into / round(FADE * FPS))
        level = self.levels[(g - 1) % GENS] * (1 - fade) + self.levels[g] * fade
        return {(int(r), int(c)): round(float(level[r, c]), 2) for r, c in zip(*np.nonzero(level >= 0.06))}

    # ── drawing ──
    def frame_svg(self, t: float, guides: bool = False) -> str:
        cv, f, k, p = self.canvas, self._frame(t), self.k, self.pitch
        W, H = cv.w, cv.h
        x0, y0, x1, y1 = self.fox_box
        fx, fy, ground = (x0 + x1) / 2, (y0 + y1) / 2, y1
        breath = 0.5 - 0.5 * math.cos(2 * math.pi * (f / FPS) / HALO_PERIOD)
        halo_r = 300 * k * (1 + 0.06 * breath)

        side, inset = p * 10 / 16, p * 3 / 16
        by_level: dict[float, list[str]] = {}
        for (r, c), o in sorted(self.cell_opacities(t).items()):
            by_level.setdefault(o, []).append(f"M{c * p + inset:.1f} {r * p + inset:.1f}h{side:.1f}v{side:.1f}h-{side:.1f}z")
        life = "".join(f'<path d="{"".join(d)}" fill-opacity="{o:.2f}"/>' for o, d in sorted(by_level.items()))

        pose = self.fox_points(t)
        near, far = _path_d(pose, self.near), _path_d(pose, self.far)
        sx, sy, sw, sh = cv.safe
        guide = (f'<rect x="{sx}" y="{sy}" width="{sw}" height="{sh}" fill="#0f0" fill-opacity=".10" '
                 f'stroke="#0f0" stroke-width="{max(2, W // 900)}"/>') if guides else ""
        return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0b0b0c"/><stop offset=".55" stop-color="{BG}"/><stop offset="1" stop-color="{NIGHT}"/></linearGradient>
<pattern id="led" width="{p}" height="{p}" patternUnits="userSpaceOnUse"><rect x="{inset:.1f}" y="{inset:.1f}" width="{side:.1f}" height="{side:.1f}" rx="{p * 2.5 / 16:.1f}" fill="{INK}" fill-opacity=".045"/></pattern>
<radialGradient id="vig" cx="{fx:.0f}" cy="{fy:.0f}" r="{math.hypot(W, H) / 2:.0f}" gradientUnits="userSpaceOnUse"><stop offset=".2" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity=".3"/></radialGradient>
<mask id="ledmask"><rect width="{W}" height="{H}" fill="url(#vig)"/></mask>
<radialGradient id="halo" cx="{fx:.1f}" cy="{fy + 30 * k:.1f}" r="{halo_r:.1f}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity=".10"/><stop offset=".5" stop-color="#fff" stop-opacity=".03"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<radialGradient id="floor" cx="{fx:.1f}" cy="{ground:.1f}" r="{210 * k:.1f}" gradientTransform="translate(0 {ground:.1f}) scale(1 .12) translate(0 {-ground:.1f})" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="{5 * k:.1f}"/></filter>
<filter id="lifeglow" x="0" y="0" width="100%" height="100%"><feGaussianBlur stdDeviation="{2.4 * p / 16:.2f}" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<rect width="{W}" height="{H}" fill="url(#led)" mask="url(#ledmask)"/>
<g fill="{INK}" filter="url(#lifeglow)">{life}</g>
<circle cx="{fx:.1f}" cy="{fy + 30 * k:.1f}" r="{halo_r:.1f}" fill="url(#halo)" opacity="{1 - 0.45 * breath:.3f}"/>
<ellipse cx="{fx:.1f}" cy="{ground:.1f}" rx="{210 * k:.1f}" ry="{26 * k:.1f}" fill="url(#floor)"/>
<!-- Strokes sit in the path's half-pixel space: 4.2k draws 2.1k px, twice the README's weight on
     purpose. The store shows this canvas at about a third of its size, where the hero's hairline vanishes. -->
<g opacity=".55" filter="url(#glow)"><path transform="scale(.5)" d="{near}" fill="none" stroke="{BRIGHT}" stroke-width="{4.2 * k:.2f}" stroke-linejoin="round" stroke-linecap="round"/></g>
<path transform="scale(.5)" d="{far}" fill="none" stroke="{INK}" stroke-width="{3.2 * k:.2f}" stroke-linejoin="round" stroke-linecap="round" opacity=".30"/>
<path transform="scale(.5)" d="{near}" fill="none" stroke="{BRIGHT}" stroke-width="{4.2 * k:.2f}" stroke-linejoin="round" stroke-linecap="round" opacity=".92"/>
{guide}</svg>
"""


# ── The spec check, run on rendered files before anything is uploaded ─────
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
FRAME_BUDGET = 6_000_000   # bytes of temp disk per 4K RGBA frame, with headroom


def png_problems(path: Path, canvas: Canvas) -> list[str]:
    """Problems with a rendered PNG, as text — a broken file is a finding, never a crash."""
    path = Path(path)
    raw = path.read_bytes()
    if raw[:8] != PNG_SIGNATURE:
        return [f"{path.name}: not a PNG (the header and universal specs take PNG only)"]
    if len(raw) < 33 or raw[12:16] != b"IHDR":
        return [f"{path.name}: no IHDR — truncated or malformed"]
    w, h, _, color_type = struct.unpack(">IIBB", raw[16:26])
    problems = []
    if (w, h) != (canvas.w, canvas.h):
        problems.append(f"{path.name}: {w}×{h}, expected {canvas.w}×{canvas.h}")
    at, chunks = 8, set()
    while at + 8 <= len(raw):
        length, kind = struct.unpack(">I", raw[at : at + 4])[0], raw[at + 4 : at + 8]
        if at + 12 + length > len(raw):
            break
        chunks.add(kind)
        at += 12 + length
        if kind == b"IEND":
            break
    if b"IEND" not in chunks:
        problems.append(f"{path.name}: truncated (no complete IEND chunk)")
    if color_type in (4, 6) or b"tRNS" in chunks:
        problems.append(f"{path.name}: has an alpha channel (alphaAllowed is false)")
    if len(raw) > MAX_FILE:
        problems.append(f"{path.name}: {len(raw)} bytes, over 500 MB")
    return problems


def video_problems(probe: dict, canvas: Canvas) -> list[str]:
    """Check `ffprobe -show_streams -show_format -of json` output against the spec."""
    if canvas.video is None:
        return [f"{canvas.name} has no video placement"]
    video = [s for s in probe.get("streams", []) if s.get("codec_type") == "video"]
    if not video:
        return ["no video stream"]
    s, problems = video[0], []
    if (s.get("width"), s.get("height")) != canvas.video:
        problems.append(f"{s.get('width')}×{s.get('height')}, expected {canvas.video[0]}×{canvas.video[1]}")
    num, den = (int(x) for x in s.get("r_frame_rate", "0/0").split("/"))
    fps = num / den if den else 0
    if fps not in (30, 60):
        problems.append(f"{fps:g} fps, expected 30 or 60")
    duration = float(probe.get("format", {}).get("duration", 0))
    if not 5 <= duration <= 30:
        problems.append(f"{duration:.1f} s, expected 5–30 s")
    if s.get("codec_name") not in ("h264", "hevc"):
        problems.append(f"codec {s.get('codec_name')}, expected h264 or hevc")
    if int(probe.get("format", {}).get("size", 0)) > MAX_FILE:
        problems.append("over 500 MB")
    return problems


def video_name(canvas: Canvas) -> str:
    assert canvas.video, canvas.name
    return f"m1k3-{canvas.name}-{canvas.video[0]}x{canvas.video[1]}.mp4"


def expected(canvas: Canvas, video: bool) -> list[tuple[Canvas, str]]:
    """The asset files a render of `canvas` writes (proofs and anything else in the folder aren't assets)."""
    names = [(canvas, f"{canvas.file_stem}.png")]
    if video and canvas.video:
        names.append((canvas, video_name(canvas)))
    return names


def check(out_dir: Path, required: list[tuple[Canvas, str]] | None = None) -> int:
    """Spec-check rendered assets. Every `required` (canvas, file) must exist and pass; without
    it, every asset file present is checked, and finding none is a failure. A check that can't
    run (no ffprobe) fails as UNVERIFIED — this is the gate before upload, so it never passes by
    skipping."""
    if required is None:
        required = [pair for c in CANVASES.values() for pair in expected(c, True) if (out_dir / pair[1]).exists()]
        if not required:
            print(f"✗ no m1k3 assets in {out_dir}")
            return 1
    ffprobe, bad = shutil.which("ffprobe"), 0
    for canvas, name in required:
        path = out_dir / name
        if not path.exists():
            problems = ["missing"]
        elif path.suffix == ".png":
            problems = png_problems(path, canvas)
        elif not ffprobe:
            problems = ["UNVERIFIED: ffprobe not found (brew install ffmpeg)"]
        else:
            run = subprocess.run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                                 capture_output=True, check=False)   # a failed probe is a finding, not a crash
            problems = (video_problems(json.loads(run.stdout), canvas) if run.returncode == 0
                        else [f"ffprobe failed: {run.stderr.decode(errors='replace')[:200]}"])
        bad += bool(problems)
        print(("✗ " if problems else "✓ ") + name + "".join(f"\n    {p}" for p in problems))
    return 1 if bad else 0


# ── Rendering ──────────────────────────────────────────────────────────────
def _tool(name: str, hint: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SystemExit(f"{name} not found — {hint}")
    return path


def rasterize(svg: str, out: Path, width: int | None = None) -> None:
    """SVG → PNG with librsvg (static frames: no clock to freeze, so no browser)."""
    rsvg = _tool("rsvg-convert", "brew install librsvg")
    size = ["-w", str(width)] if width else []
    subprocess.run([rsvg, "-f", "png", *size, "-o", str(out)], input=svg.encode(), check=True)


def opaque(src: Path, out: Path) -> None:
    """Drop the alpha channel rsvg writes (ASC rejects any alpha)."""
    ffmpeg = _tool("ffmpeg", "brew install ffmpeg")
    subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", str(src), "-pix_fmt", "rgb24", str(out)], check=True)


def encode_args() -> list[str]:
    """H.264 High at level 5.1, BT.709 throughout. An untagged file is read as BT.601 by some
    decoders, which shifts the brand colours away from the stills."""
    return ["-c:v", "libx264", "-preset", "slow", "-crf", "14",
            "-vf", "scale=out_color_matrix=bt709:out_range=tv", "-pix_fmt", "yuv420p",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
            "-profile:v", "high", "-level:v", "5.1", "-tag:v", "avc1", "-movflags", "+faststart", "-an"]


def render_still(canvas: Canvas, out_dir: Path) -> Path:
    out = out_dir / f"{canvas.file_stem}.png"
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw.png"
        rasterize(Scene(canvas).frame_svg(POSTER), raw)
        opaque(raw, out)
    return out


def render_video(canvas: Canvas, out_dir: Path) -> Path:
    scene = Scene(canvas.scaled(*canvas.video))
    out = out_dir / video_name(canvas)
    frames = round(LOOP * FPS)
    free, need = shutil.disk_usage(tempfile.gettempdir()).free, FRAME_BUDGET * frames
    if free < need:
        raise SystemExit(f"{free / 1e9:.1f} GB free for temp frames; {frames} frames need ~{need / 1e9:.1f} GB")
    with tempfile.TemporaryDirectory() as tmp:
        here = Path(tmp)
        with ThreadPoolExecutor() as pool:
            futures = [pool.submit(lambda n=n: rasterize(scene.frame_svg(n / FPS), here / f"f{n:04d}.png"))
                       for n in range(frames)]
            try:
                for future in futures:
                    future.result()
            except BaseException:
                pool.shutdown(wait=False, cancel_futures=True)   # one bad frame stops the rest
                raise
        ffmpeg = _tool("ffmpeg", "brew install ffmpeg")
        subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(here / "f%04d.png"),
                        *encode_args(), str(out)], check=True)
    return out


def _canvas_names(arg: str) -> list[str]:
    names = [n.strip() for n in arg.split(",") if n.strip()]
    if unknown := [n for n in names if n not in CANVASES]:
        raise argparse.ArgumentTypeError(f"unknown canvas {', '.join(unknown)} (have {', '.join(CANVASES)})")
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--only", type=_canvas_names, default=list(CANVASES), help="comma-separated: header,search,universal")
    parser.add_argument("--video", action="store_true", help="also render the seamless loops")
    parser.add_argument("--guides", help="comma-separated seconds: 1600-px proofs with the safe area drawn")
    parser.add_argument("--check", action="store_true", help="only spec-check what's in --out")
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    if args.check:
        return check(args.out)
    rendered: list[tuple[Canvas, str]] = []
    for name in args.only:
        canvas = CANVASES[name]
        if args.guides:
            scene = Scene(canvas)
            for t in (float(s) for s in args.guides.split(",")):
                path = args.out / f"{canvas.file_stem}-guides-{t:g}s.png"
                rasterize(scene.frame_svg(t, guides=True), path, width=1600)
                print(f"wrote {path}")
            continue
        print(f"wrote {render_still(canvas, args.out)}")
        if args.video and canvas.video:
            print(f"wrote {render_video(canvas, args.out)}")
        rendered += expected(canvas, args.video)
    return check(args.out, rendered) if rendered else 0


if __name__ == "__main__":
    sys.exit(main())
