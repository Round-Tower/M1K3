"""Pins for store_creative.py — Apple's specs as App Store Connect states them, the fox
inside Apple's safe area in every pose, a loop that closes, and the spec check that runs
on the rendered files before anything is uploaded."""
import struct
import xml.etree.ElementTree as ET
import zlib

import pytest
import store_creative as sc


@pytest.fixture(scope="module")
def scenes():
    return {name: sc.Scene(canvas) for name, canvas in sc.CANVASES.items()}


# ── Specs: App Store Connect's catalogue (GET /v1/appAssetLibraryRefData) ──

def test_canvases_are_the_catalogue_sizes():
    assert (sc.CANVASES["header"].w, sc.CANVASES["header"].h) == (3840, 1646)        # i3840x1646a0
    assert (sc.CANVASES["universal"].w, sc.CANVASES["universal"].h) == (5244, 2950)  # i5244x2950a0
    search = sc.CANVASES["search"]                                                    # i3x2w1920~3840a0
    assert 1920 <= search.w <= 3840 and search.w * 2 == search.h * 3


def test_safe_areas_are_apples_and_sit_centred():
    for canvas in sc.CANVASES.values():
        x, y, w, h = canvas.safe
        assert 0 < x and 0 < y and x + w < canvas.w and y + h < canvas.h
        assert abs((x + w / 2) - canvas.w / 2) <= 1, canvas.name   # every template centres it across
    assert sc.CANVASES["header"].safe == (1097, 493, 1646, 661)
    assert sc.CANVASES["search"].safe == (836, 765, 2168, 1030)
    assert sc.CANVASES["universal"].safe == (1921, 660, 1402, 962)   # high: the header crop is top-anchored


def test_the_loop_closes_inside_apples_video_bounds():
    assert sc.FPS in (30, 60)
    assert 5 <= sc.LOOP <= 30
    assert sc.LOOP == pytest.approx(sc.GENS * sc.GEN_SECONDS)
    for period in (sc.FOX_PERIOD, sc.HALO_PERIOD):
        assert (sc.LOOP / period) == pytest.approx(round(sc.LOOP / period))   # whole cycles, no seam
    assert (sc.LOOP * sc.FPS) == round(sc.LOOP * sc.FPS)


# ── The scene ──────────────────────────────────────────────────────────────

def test_the_fox_stays_inside_the_safe_area_in_every_pose(scenes):
    for name, scene in scenes.items():
        x, y, w, h = scene.canvas.safe
        for k in range(round(sc.FOX_PERIOD * sc.FPS)):
            pts = scene.fox_points(k / sc.FPS) / 2          # half-pixel integers → pixels
            assert pts[:, 0].min() >= x and pts[:, 0].max() <= x + w, (name, k)
            assert pts[:, 1].min() >= y and pts[:, 1].max() <= y + h, (name, k)


def test_the_fox_fills_the_safe_area(scenes):
    for name, scene in scenes.items():
        _, _, w, h = scene.canvas.safe
        x0, y0, x1, y1 = scene.fox_box
        assert max((x1 - x0) / w, (y1 - y0) / h) > 0.8, name   # the one focal point, not a speck


def test_frames_are_well_formed_self_contained_svg(scenes):
    for scene in scenes.values():
        svg = scene.frame_svg(1.0)
        root = ET.fromstring(svg)
        assert root.get("viewBox") == f"0 0 {scene.canvas.w} {scene.canvas.h}"
        assert "<script" not in svg and "<text" not in svg      # textless: every locale, unchanged
        assert "href=\"http" not in svg and "url(http" not in svg


def test_the_loop_is_seamless(scenes):
    scene = scenes["header"]
    for t in (0.0, 0.1, 5.5, 12.25):
        assert scene.frame_svg(t) == scene.frame_svg(t + sc.LOOP)


def test_frames_move(scenes):
    scene = scenes["header"]
    assert scene.frame_svg(1.0) != scene.frame_svg(1.0 + 1 / sc.FPS)   # the fox turns every frame


def test_life_clears_around_the_fox(scenes):
    """No cell burns bright on the fox: the mask fades the field to a whisper there."""
    for scene in scenes.values():
        x0, y0, x1, y1 = scene.fox_box
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        assert scene.field_mask(cx, cy) <= 0.2
        assert scene.field_mask(4, 4) > scene.field_mask(cx, cy)


def test_life_crossfades_between_generations(scenes):
    scene = scenes["header"]
    mid = scene.cell_opacities(sc.GEN_SECONDS * 3 + sc.FADE / 2)
    settled = scene.cell_opacities(sc.GEN_SECONDS * 3 + sc.FADE * 2)
    assert mid != settled                       # mid-fade differs from the settled generation
    assert settled == scene.cell_opacities(sc.GEN_SECONDS * 3 + sc.GEN_SECONDS * 0.9)


def test_scenes_are_deterministic():
    a = sc.Scene(sc.CANVASES["search"]).frame_svg(3.3)
    b = sc.Scene(sc.CANVASES["search"]).frame_svg(3.3)
    assert a == b


# ── The spec check on rendered files ───────────────────────────────────────

def _png(path, w, h, color_type, trns=False):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    channels = {2: 3, 6: 4}[color_type]
    raw = b"".join(b"\0" + b"\0" * (w * channels) for _ in range(h))
    body = chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0))
    if trns:
        body += chunk(b"tRNS", b"\0\0\0\0\0\0")
    body += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + body)
    return path


def test_png_check_passes_an_opaque_png_at_spec(tmp_path):
    canvas = sc.Canvas("tiny", 8, 4, (2, 1, 4, 2), ("PRODUCT_PAGE_HEADER_ASSET",))
    assert sc.png_problems(_png(tmp_path / "ok.png", 8, 4, 2), canvas) == []


def test_png_check_names_alpha_and_size(tmp_path):
    canvas = sc.Canvas("tiny", 8, 4, (2, 1, 4, 2), ("PRODUCT_PAGE_HEADER_ASSET",))
    rgba = sc.png_problems(_png(tmp_path / "a.png", 8, 4, 6), canvas)
    trns = sc.png_problems(_png(tmp_path / "t.png", 8, 4, 2, trns=True), canvas)
    size = sc.png_problems(_png(tmp_path / "s.png", 9, 4, 2), canvas)
    assert any("alpha" in p for p in rgba) and any("alpha" in p for p in trns)
    assert any("9×4" in p for p in size)


def _probe(w=3840, h=1646, rate="30/1", duration="24.0", codec="h264"):
    return {"streams": [{"codec_type": "video", "codec_name": codec, "width": w, "height": h, "r_frame_rate": rate}],
            "format": {"duration": duration, "size": "1000"}}


def test_video_check_passes_the_header_loop():
    assert sc.video_problems(_probe(), sc.CANVASES["header"]) == []


def test_video_check_names_each_breach():
    header = sc.CANVASES["header"]
    assert any("fps" in p for p in sc.video_problems(_probe(rate="24/1"), header))
    assert any("31.0 s" in p for p in sc.video_problems(_probe(duration="31.0"), header))
    assert any("3840×2160" in p for p in sc.video_problems(_probe(h=2160), header))
    assert any("no video" in p for p in sc.video_problems({"streams": [], "format": {}}, header))
    assert sc.video_problems(_probe(), sc.CANVASES["universal"]) == ["universal has no video placement"]


# ── the checker is the release gate: it must fail loudly, never pass by skipping ──

def test_png_check_reports_a_broken_file_instead_of_crashing(tmp_path):
    canvas = sc.Canvas("tiny", 8, 4, (2, 1, 4, 2), ("PRODUCT_PAGE_HEADER_ASSET",))
    good = _png(tmp_path / "g.png", 8, 4, 2).read_bytes()
    (tmp_path / "cut.png").write_bytes(good[:-10])
    (tmp_path / "stub.png").write_bytes(good[:12])
    (tmp_path / "jpeg.png").write_bytes(b"\xff\xd8\xff\xe0" + b"\0" * 40)
    assert any("truncated" in p for p in sc.png_problems(tmp_path / "cut.png", canvas))
    assert any("IHDR" in p for p in sc.png_problems(tmp_path / "stub.png", canvas))
    assert any("not a PNG" in p for p in sc.png_problems(tmp_path / "jpeg.png", canvas))


def test_video_check_survives_a_nonsense_rate():
    probe = {"streams": [{"codec_type": "video", "codec_name": "h264", "width": 3840, "height": 1646,
                          "r_frame_rate": "0/0"}], "format": {"duration": "24", "size": "1"}}
    assert any("fps" in p for p in sc.video_problems(probe, sc.CANVASES["header"]))


def test_check_fails_on_an_empty_folder(tmp_path):
    assert sc.check(tmp_path) == 1


def test_check_requires_what_was_rendered_and_ignores_proofs(tmp_path):
    header = sc.CANVASES["header"]
    _png(tmp_path / f"{header.file_stem}-guides-1s.png", 10, 10, 6)       # a proof, not an asset
    assert sc.check(tmp_path, [(header, f"{header.file_stem}.png")]) == 1  # the asset itself is missing
    _png(tmp_path / f"{header.file_stem}.png", header.w, header.h, 2)
    assert sc.check(tmp_path) == 0


def test_check_marks_video_unverified_without_ffprobe(tmp_path, monkeypatch):
    header = sc.CANVASES["header"]
    name = f"m1k3-header-{header.video[0]}x{header.video[1]}.mp4"
    (tmp_path / name).write_bytes(b"\0" * 64)
    monkeypatch.setattr(sc.shutil, "which", lambda tool: None)
    assert sc.check(tmp_path, [(header, name)]) == 1


def test_video_is_tagged_bt709_so_colours_match_the_stills():
    args = " ".join(sc.encode_args())
    for flag in ("out_color_matrix=bt709", "-colorspace bt709", "-color_primaries bt709", "-color_trc bt709"):
        assert flag in args


def test_every_frame_closes_the_loop_on_every_canvas(scenes):
    for scene in scenes.values():
        for f in range(0, round(sc.LOOP * sc.FPS), 37):
            assert scene.frame_svg(f / sc.FPS) == scene.frame_svg(f / sc.FPS + sc.LOOP), (scene.canvas.name, f)


def test_survey_turns_back_into_its_first_pose():
    """The fox's last pose must flow into its first like any other step — or the loop pops."""
    import numpy as np
    _, _, _, raw = sc._fox()
    steps = np.abs(np.diff(raw, axis=0)).max(axis=(1, 2))
    assert np.abs(raw[0] - raw[-1]).max() <= 2 * np.median(steps)


def test_the_shipped_search_loop_keeps_the_fox_safe():
    scene = sc.Scene(sc.CANVASES["search"].scaled(*sc.CANVASES["search"].video))
    x, y, w, h = scene.canvas.safe
    x0, y0, x1, y1 = scene.fox_box
    assert x <= x0 and x1 <= x + w and y <= y0 and y1 <= y + h
    assert (scene.canvas.w, scene.canvas.h) == (3072, 2048)
