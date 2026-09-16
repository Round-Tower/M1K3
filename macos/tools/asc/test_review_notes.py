"""Pins for the pure half of review_notes.py (no key, no network)."""
from __future__ import annotations

from pathlib import Path

import review_notes


def test_review_notes_problems_wants_both_inbound_listeners_named() -> None:
    # the 09-15 notes: outbound "in full", no listener named → the automated
    # entitlement check found network.server with "no matching functionality"
    stale = "NETWORK USAGE — IN FULL\nOutbound network use is limited to the model download."
    assert review_notes.problems(stale) == [
        "notes never mention the MCP server (com.apple.security.network.server)",
        "notes never mention Brain at Home (com.apple.security.network.server)",
    ]
    good = "MCP server on 127.0.0.1:4242 … Brain at Home serves paired devices on the LAN"
    assert review_notes.problems(good) == []


def test_review_notes_problems_reports_the_cap_and_emptiness() -> None:
    assert review_notes.problems("") == ["notes are empty"]
    over = "MCP server Brain at Home " + "x" * review_notes.NOTES_CAP
    assert review_notes.problems(over) == [f"notes over the {review_notes.NOTES_CAP}-char cap ({len(over)})"]


def test_review_notes_patch_payload_shape() -> None:
    payload = review_notes.patch_payload("detail-1", "hello")
    assert payload == {
        "data": {"type": "appStoreReviewDetails", "id": "detail-1", "attributes": {"notes": "hello"}}
    }


def test_the_tracked_review_notes_pass_their_own_check() -> None:
    text = (Path(__file__).resolve().parents[2] / "fastlane" / "review_notes.txt").read_text()
    assert review_notes.problems(text) == []
    # the two listeners the entitlement exists for, by the names the reviewer will see in Settings
    for phrase in ("MCP server", "Brain at Home", "127.0.0.1", "4242", "OFF by default", "network.server"):
        assert phrase in text, phrase
