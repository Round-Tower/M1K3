"""Pins for event_art.py — the in-app event card and details art: Apple's sizes, the
palettes (the default one is the store creative's, untouched), the fox inside the safe
area on both canvases, a quiet bottom for the text Apple lays over the art, real Life
gliders for bats, and the JPEG check that runs on the rendered files before upload.

Pure: numpy only, no rsvg, no network.

Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8. Prior: test_store_creative.py
(its fixtures' shape). The safe-area bounds pin a third party's measurement, not Apple's."""
import re
import struct
import sys
from pathlib import Path

import event_art as ea
import numpy as np
import pytest
import readme_hero_svg as hero
import store_creative as sc

HEX = re.compile(r"#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b")


@pytest.fixture(scope="module")
def scenes():
    return {(c, p): ea.EventScene(ea.CANVASES[c], ea.PALETTES[p]) for c in ea.CANVASES for p in ea.PALETTES}


def _visible_colours(svg: str) -> set[str]:
    """Hex colours that reach the picture: masks only shape it, and the guide is a proof overlay."""
    svg = re.sub(r"<mask\b.*?</mask>", "", svg, flags=re.DOTALL)
    return {c.upper() for c in HEX.findall(svg)}


# ── Apple's media spec (developer.apple.com/help/app-store-connect/reference/in-app-event-media-and-audio-specifications) ──

def test_canvases_are_apples_minimum_sizes():
    card, details = ea.CANVASES["card"], ea.CANVASES["details"]
    assert (card.w, card.h) == (1920, 1080) and card.w * 9 == card.h * 16          # 16:9
    assert (details.w, details.h) == (1080, 1920) and details.w * 16 == details.h * 9   # 9:16


def test_file_names_are_the_ones_the_uploader_reads():
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "asc"))
    import events
    assert ea.asset_name(ea.CANVASES["card"]) == events.CARD_FILE
    assert ea.asset_name(ea.CANVASES["details"]) == events.DETAILS_FILE
    for canvas in ea.CANVASES.values():
        assert ea.guides_name(canvas) != ea.asset_name(canvas)    # a proof can never be uploaded by name


def test_safe_areas_sit_centred_in_the_upper_sixty_percent():
    """Apple publishes no event safe area; the store's text sits at the bottom, so the art keeps
    its subject in the upper-centre 60% (top 5–8% and the side 6% kept clear too)."""
    for canvas in ea.CANVASES.values():
        x, y, w, h = canvas.safe
        assert abs((x + w / 2) - canvas.w / 2) <= 1, canvas.name
        assert x >= 0.06 * canvas.w - 1 and x + w <= 0.94 * canvas.w + 1, canvas.name
        assert y >= 0.05 * canvas.h - 1, canvas.name
        assert y + h <= 0.60 * canvas.h + 1, canvas.name


# ── Palettes ───────────────────────────────────────────────────────────────

def test_the_default_palette_is_the_store_creatives():
    p = ea.PALETTES[ea.DEFAULT_PALETTE]
    assert ea.DEFAULT_PALETTE == "phosphor"
    assert p.bg == ("#0b0b0c", hero.BG, hero.NIGHT)
    assert (p.fox, p.far, p.glow, p.grid) == (hero.BRIGHT, hero.INK, hero.BRIGHT, hero.INK)
    assert set(p.life) == {hero.INK} and p.moon is None


def test_the_store_creative_still_uses_the_heros_colours():
    """event_art never reaches into store_creative's scene: its frames keep their own palette."""
    svg = sc.Scene(sc.CANVASES["header"]).frame_svg(sc.POSTER)
    assert hero.BRIGHT in svg and hero.INK in svg
    assert not {c.upper() for c in (ea.PUMPKIN, ea.EMBER, ea.VIOLET, ea.HALLOWEEN_NIGHT)} & {c.upper() for c in HEX.findall(svg)}


def test_the_halloween_palette_is_the_apps_exactly():
    assert (ea.PUMPKIN, ea.EMBER, ea.VIOLET, ea.HALLOWEEN_NIGHT) == ("#FF8A1F", "#FFB347", "#9B5CFF", "#0A0610")
    p = ea.PALETTES["halloween"]
    assert p.fox == ea.PUMPKIN and p.glow == ea.EMBER and p.halo == ea.EMBER and p.moon == ea.EMBER
    assert set(p.bg) == {ea.HALLOWEEN_NIGHT}
    assert p.life[0] in (ea.EMBER, ea.PUMPKIN) and p.life[-1] == ea.VIOLET   # newborns burn, ash goes violet


def test_halloween_draws_only_the_shared_palette(scenes):
    allowed = {c.upper() for c in (ea.PUMPKIN, ea.EMBER, ea.VIOLET, ea.HALLOWEEN_NIGHT)}
    for canvas in ea.CANVASES:
        assert _visible_colours(scenes[(canvas, "halloween")].svg()) <= allowed, canvas


def test_phosphor_draws_none_of_the_halloween_colours(scenes):
    halloween = {c.upper() for c in (ea.PUMPKIN, ea.EMBER, ea.VIOLET, ea.HALLOWEEN_NIGHT)}
    for canvas in ea.CANVASES:
        assert not _visible_colours(scenes[(canvas, "phosphor")].svg()) & halloween, canvas


def test_life_colour_follows_age():
    p = ea.PALETTES["halloween"]
    assert ea.life_colour(p, 1) == p.life[0]
    assert ea.life_colour(p, 3) == p.life[1]
    assert ea.life_colour(p, 8) == p.life[2]
    assert ea.life_colour(p, hero.MAX_AGE) == p.life[3]


# ── The scene ──────────────────────────────────────────────────────────────

def test_the_fox_fits_inside_the_safe_area_on_both_canvases(scenes):
    for (name, palette), scene in scenes.items():
        x, y, w, h = scene.canvas.safe
        pts = scene.fox_points() / 2                      # half-pixel integers → pixels
        assert pts[:, 0].min() >= x and pts[:, 0].max() <= x + w, (name, palette)
        assert pts[:, 1].min() >= y and pts[:, 1].max() <= y + h, (name, palette)


def test_the_fox_is_the_subject_not_a_speck(scenes):
    for (name, _), scene in scenes.items():
        _, _, w, h = scene.canvas.safe
        x0, y0, x1, y1 = scene.fox_box
        assert max((x1 - x0) / w, (y1 - y0) / h) > 0.6, name


def test_the_fox_stands_in_the_same_place_in_every_palette(scenes):
    for canvas in ea.CANVASES:
        assert scenes[(canvas, "phosphor")].fox_box == scenes[(canvas, "halloween")].fox_box


def test_the_bottom_third_stays_quiet_for_apples_text(scenes):
    for (name, _), scene in scenes.items():
        W, H = scene.canvas.w, scene.canvas.h
        for x in np.linspace(0, W, 9):
            for y in np.linspace(H * 2 / 3, H, 7):
                assert scene.field_mask(x, y) <= 0.12, (name, x, y)


def test_life_clears_around_the_fox(scenes):
    for scene in scenes.values():
        x0, y0, x1, y1 = scene.fox_box
        assert scene.field_mask((x0 + x1) / 2, (y0 + y1) / 2) <= 0.2


def test_the_moon_rises_behind_the_fox_in_the_upper_sixty_percent(scenes):
    for canvas in ea.CANVASES:
        scene = scenes[(canvas, "halloween")]
        cx, cy, r = scene.moon
        x0, y0, x1, y1 = scene.fox_box
        assert cy < (y0 + y1) / 2                                  # above the fox's middle
        assert x0 < cx + r and cx - r < x1                         # behind it, not beside it
        assert cy - r >= 0.05 * scene.canvas.h                     # whole: never clipped at the top
        assert cy + r <= 0.60 * scene.canvas.h                     # never into the text band
        assert r >= 0.5 * (y1 - y0)                                # large: a backdrop, not a button
        assert scenes[(canvas, "phosphor")].moon is None and not scenes[(canvas, "phosphor")].bats


def test_bats_are_real_gliders_crossing_the_moon(scenes):
    """The bats arise from the scene: each is a Life glider, which B3/S23 carries one cell
    diagonally every four generations — the same shape, moved."""
    scene = scenes[("card", "halloween")]
    assert scene.bats, "a Halloween moon has bats"
    cx, cy, r = scene.moon
    p = scene.pitch
    for cells in scene.bats:
        assert len(cells) == 5
        for row, col in cells:                                     # every cell on the moon
            assert np.hypot((col + 0.5) * p - cx, (row + 0.5) * p - cy) <= r
        rows, cols = zip(*cells)
        r0, c0 = min(rows), min(cols)
        board = np.zeros((12, 12), np.uint8)
        for row, col in cells:
            board[row - r0 + 4, col - c0 + 4] = 1
        later = board
        for _ in range(4):
            later = hero.life_step(later)
        moved = {tuple(rc) for rc in np.argwhere(later > 0)}
        start = {tuple(rc) for rc in np.argwhere(board > 0)}
        dr, dc = (np.array(sorted(moved)) - np.array(sorted(start)))[0]
        assert abs(dr) == 1 and abs(dc) == 1
        assert moved == {(a + dr, b + dc) for a, b in start}


def test_frames_are_textless_self_contained_svg(scenes):
    for scene in scenes.values():
        svg = scene.svg()
        assert f'viewBox="0 0 {scene.canvas.w} {scene.canvas.h}"' in svg
        assert "<text" not in svg and "<script" not in svg
        assert 'href="http' not in svg and "url(http" not in svg


def test_guides_draw_only_on_the_proof(scenes):
    scene = scenes[("card", "halloween")]
    assert scene.svg(guides=True) != scene.svg()
    assert "#0f0" not in scene.svg()


def test_scenes_are_deterministic():
    a = ea.EventScene(ea.CANVASES["details"], ea.PALETTES["halloween"]).svg()
    b = ea.EventScene(ea.CANVASES["details"], ea.PALETTES["halloween"]).svg()
    assert a == b


# ── The JPEG check on rendered files ───────────────────────────────────────

def _jpeg(path, w, h, components=3, eoi=True, sof=0xC0):
    seg = lambda marker, body: struct.pack(">BBH", 0xFF, marker, len(body) + 2) + body
    sof_body = struct.pack(">BHHB", 8, h, w, components) + b"".join(bytes([i + 1, 0x11, 0]) for i in range(components))
    data = b"\xff\xd8" + seg(0xE0, b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0") + seg(sof, sof_body)
    data += b"\0" * 32 + (b"\xff\xd9" if eoi else b"")
    path.write_bytes(data)
    return path


def test_jpeg_check_passes_an_rgb_jpeg_at_spec(tmp_path):
    canvas = ea.CANVASES["card"]
    assert ea.jpeg_problems(_jpeg(tmp_path / "ok.jpg", 1920, 1080), canvas) == []
    assert ea.jpeg_problems(_jpeg(tmp_path / "prog.jpg", 1920, 1080, sof=0xC2), canvas) == []


def test_jpeg_check_names_each_breach(tmp_path):
    canvas = ea.CANVASES["card"]
    assert any("1080×1920" in p for p in ea.jpeg_problems(_jpeg(tmp_path / "s.jpg", 1080, 1920), canvas))
    assert any("CMYK" in p for p in ea.jpeg_problems(_jpeg(tmp_path / "k.jpg", 1920, 1080, components=4), canvas))
    assert any("truncated" in p for p in ea.jpeg_problems(_jpeg(tmp_path / "t.jpg", 1920, 1080, eoi=False), canvas))
    (tmp_path / "png.jpg").write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0" * 40)
    assert any("not a JPEG" in p for p in ea.jpeg_problems(tmp_path / "png.jpg", canvas))
    (tmp_path / "stub.jpg").write_bytes(b"\xff\xd8\xff\xe0\x00")
    assert any("no frame header" in p for p in ea.jpeg_problems(tmp_path / "stub.jpg", canvas))


def test_check_fails_on_a_missing_asset(tmp_path):
    assert ea.check(tmp_path) == 1
    _jpeg(tmp_path / ea.asset_name(ea.CANVASES["card"]), 1920, 1080)
    assert ea.check(tmp_path) == 1                                  # details still missing
    _jpeg(tmp_path / ea.asset_name(ea.CANVASES["details"]), 1080, 1920)
    assert ea.check(tmp_path) == 0
