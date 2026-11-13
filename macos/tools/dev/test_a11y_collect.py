"""Tests for a11y_collect: the audit's text attachments, filed by screen out of an xcresult export.

Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85, Prior: Unknown
"""

from __future__ import annotations

import json
from pathlib import Path

import a11y_collect as m


def _export(tmp_path: Path, tests: list[dict], files: dict[str, str]) -> Path:
    export = tmp_path / "export"
    export.mkdir()
    (export / "manifest.json").write_text(json.dumps(tests))
    for name, body in files.items():
        (export / name).write_text(body)
    return export


def test_a_report_attachment_is_filed_under_its_screen(tmp_path: Path) -> None:
    export = _export(
        tmp_path,
        [{"attachments": [{"exportedFileName": "A1.txt", "suggestedHumanReadableName": "a11y-chat_0_9F3A.txt"}]}],
        {"A1.txt": "0 issues\n"},
    )
    out = tmp_path / "out"
    assert m.collect(export, out) == ["chat"]
    assert (out / "chat.txt").read_text() == "0 issues\n"


def test_a_screen_name_with_hyphens_survives(tmp_path: Path) -> None:
    export = _export(
        tmp_path,
        [{"attachments": [{"exportedFileName": "B.txt", "suggestedHumanReadableName": "a11y-brain-at-home_0_77.txt"}]}],
        {"B.txt": "1 issue on 1 screen: contrast 1\n"},
    )
    assert m.collect(export, tmp_path / "out") == ["brain-at-home"]


def test_other_attachments_are_left_alone(tmp_path: Path) -> None:
    export = _export(
        tmp_path,
        [
            {
                "attachments": [
                    {"exportedFileName": "shot.png", "suggestedHumanReadableName": "chat_0_AA.png"},
                    {"exportedFileName": "tree.txt", "suggestedHumanReadableName": "tree-brain_0_BB.txt"},
                    {"exportedFileName": "rec.mp4", "suggestedHumanReadableName": "a11y-chat_0_CC.mp4"},
                ]
            }
        ],
        {"shot.png": "x", "tree.txt": "x", "rec.mp4": "x"},
    )
    out = tmp_path / "out"
    assert m.collect(export, out) == []
    assert not out.exists() or list(out.iterdir()) == []


def test_a_manifest_entry_whose_file_is_missing_is_skipped(tmp_path: Path) -> None:
    export = _export(
        tmp_path,
        [{"attachments": [{"exportedFileName": "gone.txt", "suggestedHumanReadableName": "a11y-chat_0_AA.txt"}]}],
        {},
    )
    assert m.collect(export, tmp_path / "out") == []


def test_a_test_with_no_attachments_and_a_nameless_one_do_not_crash(tmp_path: Path) -> None:
    export = _export(
        tmp_path,
        [{}, {"attachments": [{"exportedFileName": "a11y-voice-listening.txt"}]}],
        {"a11y-voice-listening.txt": "0 issues\n"},
    )
    assert m.collect(export, tmp_path / "out") == ["voice-listening"]


def test_a_name_that_would_leave_the_report_folder_is_refused(tmp_path: Path) -> None:
    export = _export(
        tmp_path,
        [{"attachments": [{"exportedFileName": "E.txt", "suggestedHumanReadableName": "a11y-../../evil_0_AA.txt"}]}],
        {"E.txt": "x"},
    )
    out = tmp_path / "out"
    assert m.collect(export, out) == []
    assert not (tmp_path / "evil.txt").exists()
