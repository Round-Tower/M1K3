"""Pins for the pure half of keywords.py (no key, no network)."""
from __future__ import annotations

import pytest

import keywords


@pytest.mark.parametrize("text,hits", [
    ("assistant,GPT,chatbot", ["GPT"]),
    ("chatgpt alternative,private", ["ChatGPT"]),  # the whole mark, once
    ("agi,AGI", ["AGI"]),
    ("assistant,LLM,MLX,private", []),
    ("", []),
    (None, []),
    ("magical,gemination", []),  # inside a word is not the mark
])
def test_trademark_hits(text, hits) -> None:
    assert keywords.trademark_hits(text) == hits


def test_field_report_flags_trademarks_and_caps() -> None:
    lines = keywords.field_report("IOS", "en-US", "keywords", "a,GPT," + "x" * 100, 100)
    assert any("TRADEMARK" in line and "'GPT'" in line for line in lines)
    assert any("OVER-CAP" in line and "/100" in line for line in lines)
    assert keywords.field_report("MAC_OS", "de-DE", "subtitle", "Punk-Intelligenz, auf Gerät", 30) == []
