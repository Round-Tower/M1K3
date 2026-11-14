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
- [contrast] static text "Chat" at (411.5, 193.0, 61.0, 20.0): Contrast failed (static text at (411.5, 193.0, 61.0, 20.0))
- [description] group at (392.0, 131.0, 254.0, 900.0): Element has no description (group at (392.0, 131.0, 254.0, 900.0))
- [contrast] Send: Contrast nearly passed (button at (1573.0, 980.0, 30.0, 30.0))
- [contrast] Stop: Contrast failed
"""


def test_the_window_frame_is_read_from_the_report_heading() -> None:
    assert m.window_of(REPORT) == (392.0, 131.0, 1440.0, 900.0)
    assert m.window_of("0 issues\n") is None


def test_an_empty_window_frame_is_no_window() -> None:
    # What a window that has gone reports: nothing can be placed on it (it divided by zero once).
    assert m.window_of("WINDOW (0.0, 0.0, 0.0, 0.0)\n0 issues\n") is None


def test_a_frame_partly_above_a_full_screen_phone_picture_is_clipped_to_it() -> None:
    box = m.pixel_box((76.0, -10.0, 85.0, 19.0), (0.0, 0.0, 402.0, 874.0), (1206, 2622))
    assert box == (228, 0, 483, 27)


def test_only_contrast_findings_with_a_place_are_measured() -> None:
    found = m.findings_of(REPORT)
    assert [f.name for f in found] == ['static text "Chat"', "Send"]
    assert found[0].frame == (411.5, 193.0, 61.0, 20.0)
    assert found[0].said == "Contrast failed (static text at (411.5, 193.0, 61.0, 20.0))"
    assert found[1].frame == (1573.0, 980.0, 30.0, 30.0)


def test_a_report_from_before_the_frame_moved_into_the_detail_is_still_read() -> None:
    old = '- [contrast] static text "Chat" at (411.5, 193.0, 61.0, 20.0): Contrast failed (static text)\n'
    assert [(f.name, f.frame) for f in m.findings_of(old)] == [('static text "Chat"', (411.5, 193.0, 61.0, 20.0))]


def test_a_label_with_a_colon_or_brackets_does_not_split_the_line() -> None:
    line = "- [contrast] Note: see (below) at once: Contrast failed (static text at (1.0, 2.0, 3.0, 4.0))\n"
    found = m.findings_of(line)
    assert [(f.name, f.frame) for f in found] == [("Note: see (below) at once", (1.0, 2.0, 3.0, 4.0))]


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
        + "- [contrast] Send: Contrast failed\n"
        + '- [contrast] static text "below" at (5.0, 80.0, 30.0, 15.0): Contrast failed (static text)\n'
    )
    _picture(tmp_path / "pale.png", (200, 200, 200))
    (tmp_path / "unseen.txt").write_text(heading + '- [contrast] static text "x" at (1.0, 1.0, 2.0, 2.0): Contrast failed\n')

    assert m.main(["a11y_contrast.py", str(tmp_path)]) == 1  # pale grey on white is under the bar
    out = capsys.readouterr().out
    assert 'FAILS    static text "pale"' in out
    assert 'off-picture  static text "below"' in out
    assert "pale: 1 contrast finding(s) NOT measured (its line carries no frame)" in out
    assert "unseen: 1 contrast finding(s) NOT measured (no picture)" in out


def test_a_run_whose_text_clears_the_bar_exits_clean(tmp_path: Path) -> None:
    (tmp_path / "dark.txt").write_text(
        'WINDOW (0.0, 0.0, 100.0, 50.0)\n- [contrast] static text "dark" at (5.0, 5.0, 30.0, 15.0): Contrast failed\n'
    )
    _picture(tmp_path / "dark.png", (0, 0, 0))
    assert m.main(["a11y_contrast.py", str(tmp_path)]) == 0


def test_a_patch_with_no_text_in_it_is_said_to_be_that_and_is_not_a_failure(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert m.line("settings", "Battery", 1.2) == "settings          1.2:1  no text there (the screen moved)  Battery"
    (tmp_path / "blank.txt").write_text(
        'WINDOW (0.0, 0.0, 100.0, 50.0)\n- [contrast] Battery: Contrast failed (static text at (60.0, 30.0, 30.0, 15.0))\n'
    )
    _picture(tmp_path / "blank.png", (0, 0, 0))  # the text is drawn elsewhere on the picture
    assert m.main(["a11y_contrast.py", str(tmp_path)]) == 0
    assert "1 contrast finding(s) NOT measured (no text at the frame" in capsys.readouterr().out
