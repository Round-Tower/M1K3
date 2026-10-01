"""Pins for ci_scripts/select_what_to_test.sh — the per-platform TestFlight notes.

Xcode Cloud uploads TestFlight/WhatToTest.<locale>.txt (beside the project) as
the build's "What to Test". One file for every platform would tell iPhone
testers to try the Mac CLI, so the hook copies the platform's own notes in.
"""
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "ci_scripts" / "select_what_to_test.sh"


def _run(testflight: Path, platform: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(SCRIPT), str(testflight), platform],
                          capture_output=True, text=True, check=False)


def _notes(testflight: Path, **files: str) -> None:
    (testflight / "notes").mkdir(parents=True)
    for name, text in files.items():
        (testflight / "notes" / name.replace("_", ".", 1)).write_text(text)


def test_copies_the_platforms_notes_for_every_locale(tmp_path):
    _notes(tmp_path, **{"ios_en-US.txt": "phone", "ios_de-DE.txt": "Telefon", "macos_en-US.txt": "mac"})
    assert _run(tmp_path, "iOS").returncode == 0
    assert (tmp_path / "WhatToTest.en-US.txt").read_text() == "phone"
    assert (tmp_path / "WhatToTest.de-DE.txt").read_text() == "Telefon"


def test_never_uses_another_platforms_notes(tmp_path):
    _notes(tmp_path, **{"macos_en-US.txt": "try the m1k3 CLI"})
    assert _run(tmp_path, "visionOS").returncode == 0
    # No notes beats wrong notes — and a missing file must not fail the archive.
    assert list(tmp_path.glob("WhatToTest.*.txt")) == []


def test_unknown_or_empty_platform_is_a_no_op(tmp_path):
    _notes(tmp_path, **{"ios_en-US.txt": "phone"})
    assert _run(tmp_path, "").returncode == 0
    assert list(tmp_path.glob("WhatToTest.*.txt")) == []


def test_a_rerun_for_another_platform_leaves_no_stale_notes(tmp_path):
    _notes(tmp_path, **{"ios_en-US.txt": "phone", "ios_de-DE.txt": "Telefon", "macos_en-US.txt": "mac"})
    _run(tmp_path, "iOS")
    _run(tmp_path, "macOS")
    assert sorted(p.name for p in tmp_path.glob("WhatToTest.*.txt")) == ["WhatToTest.en-US.txt"]
    assert (tmp_path / "WhatToTest.en-US.txt").read_text() == "mac"
