"""Pins for readme_hero_svg.py — the Life rules the app runs, the wordmark the
app draws, the fox's welded lattice, and an SVG GitHub will actually animate."""
import re
from itertools import pairwise

import numpy as np
import pytest

import readme_hero_svg as hero

REPO = hero.REPO


# ── Life: the same field as M1K3ScreensaverCore/LifeField.swift ────────────

def _field(cols: int, rows: int, alive: list[tuple[int, int]]) -> np.ndarray:
    ages = np.zeros((rows, cols), np.uint8)
    for c, r in alive:
        ages[r, c] = 1
    return ages


def test_life_blinker_flips_and_survivors_age():
    ages = hero.life_step(_field(5, 5, [(1, 2), (2, 2), (3, 2)]))
    assert {(c, r) for r, c in zip(*np.nonzero(ages))} == {(2, 1), (2, 2), (2, 3)}
    assert ages[2, 2] == 2          # the centre survived: one generation older
    assert ages[1, 2] == ages[3, 2] == 1   # the tips are newborns


def test_life_glider_moves_one_cell_diagonally_every_four_generations():
    glider = [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
    ages = _field(8, 8, glider)
    for _ in range(4):
        ages = hero.life_step(ages)
    assert {(c, r) for r, c in zip(*np.nonzero(ages))} == {(c + 1, r + 1) for c, r in glider}


def test_life_wraps_on_a_torus():
    ages = hero.life_step(_field(5, 5, [(4, 2), (0, 2), (1, 2)]))   # a blinker across the seam
    assert {(c, r) for r, c in zip(*np.nonzero(ages))} == {(0, 1), (0, 2), (0, 3)}


def test_life_soup_matches_the_store_frames_seeding():
    """marketing/app-store/life.js `new LifeField(10, 6, 0.3, 0x4D314B33).ages` — the
    same SplitMix64 draw order, so the hero, the store frames and the app agree."""
    js = [0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0,
          0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0]
    frames = hero.life_run(10, 6, 0.3, 0x4D314B33, 0)
    assert frames[0].reshape(-1).tolist() == js


def test_life_run_is_deterministic():
    a = hero.life_run(20, 10, 0.22, 7, 30)
    b = hero.life_run(20, 10, 0.22, 7, 30)
    assert all((x == y).all() for x, y in zip(a, b))


# ── Wordmark ───────────────────────────────────────────────────────────────

def test_the_wordmark_m_is_the_apps_pixel_mark():
    swift = (REPO / "macos/Sources/M1K3ScreensaverCore/PixelMark.swift").read_text()
    start = swift.index("= [", swift.index("onCells"))   # past the [(col:, row:)] type
    block = swift[start:swift.index("]", start)]
    app = {(int(c), int(r)) for c, r in re.findall(r"\((\d+),\s*(\d+)\)", block)}
    ours = {(c, r) for r, row in enumerate(hero.GLYPHS["M"]) for c, ch in enumerate(row) if ch == "#"}
    assert ours == app


def test_every_glyph_is_five_rows_of_even_width():
    for ch in hero.TITLE:
        rows = hero.GLYPHS[ch]
        assert len(rows) == 5, ch
        assert len({len(r) for r in rows}) == 1, ch


# ── Fox ────────────────────────────────────────────────────────────────────

def test_a_non_glb_file_is_refused_by_name(tmp_path):
    bad = tmp_path / "Fox.glb"
    bad.write_bytes(b"not a glb at all, just some bytes")
    with pytest.raises(ValueError, match="not a binary glTF"):
        hero.Fox(bad)


def test_the_fox_welds_to_a_closed_lattice():
    fox = hero.Fox(hero.FOX_GLB)
    faces = 576
    assert len(fox.pos) - len(fox.edges) + faces == 2   # Euler: a closed manifold, no seams
    assert len(fox.edges) == 864


def test_strokes_draw_every_edge_exactly_once():
    fox = hero.Fox(hero.FOX_GLB)
    edges = [tuple(e) for e in fox.edges]
    drawn = [tuple(sorted(p)) for s in hero.strokes(edges) for p in pairwise(s)]
    assert sorted(drawn) == sorted(edges)


def test_the_survey_clip_actually_moves_the_fox():
    fox = hero.Fox(hero.FOX_GLB)
    duration = fox.clip_duration("Survey")
    delta = np.abs(fox.posed("Survey", 0) - fox.posed("Survey", duration / 3)).max()
    assert delta > 1.0


# ── The committed SVG ──────────────────────────────────────────────────────

def test_the_readme_shows_the_svg_hero():
    assert hero.OUTPUT.relative_to(REPO).as_posix() in (REPO / "README.md").read_text()


def test_the_committed_svg_is_self_contained_and_github_safe():
    svg = hero.OUTPUT.read_text()
    assert "<script" not in svg            # GitHub's image proxy drops scripts
    assert not re.search(r'(href|src|url\()\s*=?\s*["\']?https?:', svg)   # no external fetches from an <img>
    assert "@font-face" in svg and "data:font/woff2;base64," in svg
    assert f'viewBox="0 0 {hero.W} {hero.H}"' in svg
    assert "<title" in svg and "<desc" in svg


def test_the_committed_svg_honours_reduced_motion():
    svg = hero.OUTPUT.read_text()
    block = svg[svg.index("prefers-reduced-motion"):]
    assert "animation:none" in block
    assert ".fox-live{display:none}" in block   # SMIL ignores CSS, so the morphing fox is swapped out
    assert ".fox-glow{display:none}" in block   # and its glow is a <use> clone the swap doesn't reach
    assert 'class="fox-glow"' in svg


def test_the_committed_svg_stays_inside_its_budget():
    assert hero.OUTPUT.stat().st_size < 400_000


def test_the_committed_svg_carries_the_punk_line_and_never_a_bare_data_centre_promise():
    svg = hero.OUTPUT.read_text()
    assert "Punk intelligence." in svg
    assert "No data centers required" in svg
    # Opt-in PCC runs in Apple's data centres and web search calls a provider: "required" stays.
    assert not re.search(r"no data cent(er|re)s(?! required)", svg, re.IGNORECASE)
    assert not re.search(r"nothing leaves", svg, re.IGNORECASE)


def test_the_committed_svg_carries_every_line_the_generator_writes():
    """CI has no fonttools, so it can't rebuild — but it can catch copy edited without a regenerate."""
    svg = hero.OUTPUT.read_text()
    for line in [hero.EYEBROW, hero.TAGLINE, hero.FOX_LABEL, *hero.CHIPS]:
        assert line in svg, line
    assert "Generated by macos/tools/site/readme_hero_svg.py" in svg


def test_the_committed_svg_is_exactly_what_the_generator_builds():
    """Byte-for-byte, so it's also reproducible (the font subset's timestamp is pinned).
    Skipped where fonttools isn't installed (CI); run it locally after any edit."""
    pytest.importorskip("fontTools")
    pytest.importorskip("brotli")
    assert hero.build() == hero.OUTPUT.read_text()
