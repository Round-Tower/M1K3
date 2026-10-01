"""Pins for the pure half of testflight.py (no key, no network)."""
from __future__ import annotations

from pathlib import Path

import testflight


def test_the_tracked_description_passes_its_own_rules() -> None:
    assert testflight.problems(testflight.DESCRIPTION_FILE.read_text(encoding="utf-8")) == []


def test_a_mac_only_description_is_a_problem() -> None:
    # The 09-02 text: "lives entirely on your Mac … Requirements: Apple Silicon Mac".
    # One record, so iPhone testers read it too.
    [p] = testflight.problems("A private AI companion that lives entirely on your Mac.")
    assert "iPhone" in p


def test_naming_every_platform_is_fine() -> None:
    assert testflight.problems("Lives on your iPhone, iPad and Mac.") == []


def test_empty_and_over_cap() -> None:
    assert testflight.problems("") == ["beta description is empty"]
    over = "iPhone iPad Mac " + "x" * testflight.DESCRIPTION_CAP
    assert testflight.problems(over) == [
        f"beta description over the {testflight.DESCRIPTION_CAP}-char cap ({len(over)})"]


def test_read_description_drops_one_trailing_newline(tmp_path: Path) -> None:
    f = tmp_path / "d.txt"
    f.write_text("iPhone iPad Mac\n", encoding="utf-8")
    assert testflight.read_description(f) == "iPhone iPad Mac"


def test_patch_payload_shape() -> None:
    assert testflight.patch_payload("loc-1", "hello") == {
        "data": {"type": "betaAppLocalizations", "id": "loc-1", "attributes": {"description": "hello"}}}
