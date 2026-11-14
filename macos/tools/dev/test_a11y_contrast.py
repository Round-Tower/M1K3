"""Tests for a11y_contrast: each contrast finding re-measured on the screen's own picture.

Signed: Kev + claude-fable-5.2, 2026-11-14, Confidence 0.85, Prior: Unknown
"""

from __future__ import annotations

from pathlib import Path

import pytest

import a11y_contrast as m

REPORT = """WINDOW (392.0, 131.0, 1440.0, 900.0)
3 issues on 1 screen: contrast 2, description 1

## chat (3)
- [contrast] static text "Chat" at (411.5, 193.0, 61.0, 20.0): Contrast failed (static text)
- [description] group at (392.0, 131.0, 254.0, 900.0): Element has no description (group)
- [contrast] Send: Contrast nearly passed (button)
"""


def test_the_window_frame_is_read_from_the_report_heading() -> None:
    assert m.window_of(REPORT) == (392.0, 131.0, 1440.0, 900.0)
    assert m.window_of("0 issues\n") is None


def test_only_contrast_findings_with_a_place_are_measured() -> None:
    found = m.findings_of(REPORT)
    assert [f.name for f in found] == ['static text "Chat"']
    assert found[0].frame == (411.5, 193.0, 61.0, 20.0)
    assert found[0].said == "Contrast failed (static text)"


def test_a_frame_is_placed_on_the_picture_in_pixels() -> None:
    # 2880 px across a 1440 pt window: two pixels a point, measured from the window's corner.
    box = m.pixel_box((411.5, 193.0, 61.0, 20.0), (392.0, 131.0, 1440.0, 900.0), (2880, 1800))
    assert box == (39, 124, 161, 164)


def test_a_frame_outside_the_picture_has_no_box() -> None:
    assert m.pixel_box((1001.0, 1035.5, 44.5, 16.0), (392.0, 131.0, 1440.0, 900.0), (2880, 1800)) is None


def test_black_on_white_is_twenty_one_to_one_either_way_round() -> None:
    dark_text = [1.0] * 900 + [0.0] * 100
    light_text = [0.0] * 900 + [1.0] * 100
    assert round(m.ratio(dark_text), 1) == 21.0
    assert round(m.ratio(light_text), 1) == 21.0


def test_a_flat_patch_has_no_contrast() -> None:
    assert m.ratio([0.5] * 100) == 1.0


def test_luminance_follows_the_wcag_curve() -> None:
    assert m.luminance((255, 255, 255)) == 1.0
    assert m.luminance((0, 0, 0)) == 0.0
    assert round(m.luminance((119, 119, 119)), 3) == 0.184


def test_a_line_says_the_measure_and_whether_it_clears_the_bar() -> None:
    assert m.line("chat", 'static text "Chat"', 16.62) == 'chat             16.6:1  passes   static text "Chat"'
    assert m.line("chat", "caption", 3.71) == "chat              3.7:1  FAILS    caption"
    assert m.line("chat", "caption", None) == "chat                 –    off-picture  caption"


def test_a_labelled_elements_finding_is_counted_as_unmeasured() -> None:
    assert m.unplaced(REPORT) == 1
    assert m.unplaced("0 issues\n") == 0


def _picture(path: Path, text: tuple[int, int, int]) -> None:
    image_module = pytest.importorskip("PIL.Image")
    image = image_module.new("RGB", (200, 100), (255, 255, 255))
    for x in range(20, 60):
        for y in range(20, 30):
            image.putpixel((x, y), text)
    image.save(path)


def test_a_run_measures_on_the_picture_and_names_what_it_could_not(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    heading = "WINDOW (0.0, 0.0, 100.0, 50.0)\n"
    (tmp_path / "pale.txt").write_text(
        heading
        + '- [contrast] static text "pale" at (5.0, 5.0, 30.0, 15.0): Contrast failed (static text)\n'
        + "- [contrast] Send: Contrast failed (button)\n"
        + '- [contrast] static text "below" at (5.0, 80.0, 30.0, 15.0): Contrast failed (static text)\n'
    )
    _picture(tmp_path / "pale.png", (200, 200, 200))
    (tmp_path / "unseen.txt").write_text(heading + '- [contrast] static text "x" at (1.0, 1.0, 2.0, 2.0): Contrast failed\n')

    assert m.main(["a11y_contrast.py", str(tmp_path)]) == 1  # pale grey on white is under the bar
    out = capsys.readouterr().out
    assert 'FAILS    static text "pale"' in out
    assert 'off-picture  static text "below"' in out
    assert "pale: 1 contrast finding(s) NOT measured (a labelled element has no frame)" in out
    assert "unseen: 1 contrast finding(s) NOT measured (no picture)" in out


def test_a_run_whose_text_clears_the_bar_exits_clean(tmp_path: Path) -> None:
    (tmp_path / "dark.txt").write_text(
        'WINDOW (0.0, 0.0, 100.0, 50.0)\n- [contrast] static text "dark" at (5.0, 5.0, 30.0, 15.0): Contrast failed\n'
    )
    _picture(tmp_path / "dark.png", (0, 0, 0))
    assert m.main(["a11y_contrast.py", str(tmp_path)]) == 0
