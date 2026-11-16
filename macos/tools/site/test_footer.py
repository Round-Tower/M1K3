"""The footer is one source (footer.py) and every page carries it unchanged.

Signed: Kev + claude-fable-5.2, 2026-11-16, Confidence 0.85. Prior: none (new file).
"""

from __future__ import annotations

import re
from pathlib import Path

import footer

SITE = Path(__file__).resolve().parents[3] / "site"


def test_no_page_footer_has_drifted_from_the_one_source():
    assert footer.main(["--check"]) == 0


def test_every_page_with_a_footer_is_found():
    # vr.html is a full-screen scene with no footer; everything else has one.
    assert {p.name for p in footer.pages()} == {p.name for p in SITE.glob("*.html")} - {"vr.html"}


def test_every_internal_footer_link_is_a_real_page():
    for href in re.findall(r'href="(/[^"#]*)"', footer.render("index")):
        if href.startswith("/featured"):
            continue
        assert (SITE / f"{href.strip('/') or 'index'}.html").exists(), f"the footer links {href}, which is not a page"


def test_the_footer_is_grouped_and_not_a_run_of_capitals():
    html = footer.render("agents")
    assert html.count('<p class="foot-h">') == 4
    labels = re.findall(r"<a [^>]*>([^<]+)</a>", html)
    assert labels and not any(label.isupper() and len(label) > 4 for label in labels)


def test_a_page_marks_itself_current_and_only_itself():
    assert footer.render("agents").count('aria-current="page"') == 1
    assert 'href="/agents" aria-current="page"' in footer.render("agents")
    assert footer.render("terms").count('aria-current="page"') == 1


def test_creature_credits_ride_only_the_pages_that_draw_them():
    assert "Quaternius" in footer.render("companions")
    assert "Quaternius" not in footer.render("index") and "PixelMannen" in footer.render("index")
    assert "PixelMannen" not in footer.render("privacy")
    assert "service marks of Apple Inc." in footer.render("privacy")
