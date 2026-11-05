# Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.8, Prior: none
# Pins hud-capture.sh's Debug-app guard: a Release app ignores -hudDemo, so the script must refuse it
# before launching anything (the launch would open Kev's real container).
from __future__ import annotations

import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).with_name("hud-capture.sh")


def _fake_app(root: Path, marker: bool) -> Path:
    app = root / "M1K3.app"
    binary = app / "Contents" / "MacOS" / "M1K3"
    binary.parent.mkdir(parents=True)
    body = b"\x00\x01HUDDemoConfig\x00" if marker else b"\x00\x01nothing here\x00"
    binary.write_bytes(b"#!/bin/sh\n" + body)
    binary.chmod(0o755)
    return app


def _run(app: Path, out: Path) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "HUD_CAPTURE_CHECK_ONLY": "1"}
    return subprocess.run(["/bin/zsh", str(SCRIPT), str(app), str(out)],
                          capture_output=True, text=True, env=env, timeout=60)


def test_refuses_a_build_without_the_demo(tmp_path: Path) -> None:
    r = _run(_fake_app(tmp_path, marker=False), tmp_path / "out")
    assert r.returncode == 2
    assert "not a Debug build" in r.stderr


def test_accepts_a_build_carrying_the_demo(tmp_path: Path) -> None:
    r = _run(_fake_app(tmp_path, marker=True), tmp_path / "out")
    assert r.returncode == 0, r.stderr


def test_refuses_installed_apps_even_with_the_marker(tmp_path: Path) -> None:
    # A path containing /Applications is refused on the path alone (the marker would be present).
    apps = tmp_path / "Applications"
    apps.mkdir()
    r = _run(_fake_app(apps, marker=True), tmp_path / "out")
    assert r.returncode == 2
    assert "/Applications" in r.stderr
