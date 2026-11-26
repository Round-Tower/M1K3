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


def test_stamping_a_page_twice_changes_nothing():
    page = SITE / "agents.html"
    once = footer.stamped(page)
    assert footer.FOOTER.sub(lambda _: footer.render("agents"), once, count=1) == once


def test_the_home_page_carries_a_followed_ipip_badge_hosted_here():
    # iPip counts only a plain link: nofollow/ugc/sponsored disqualifies it, and the
    # badge is what unlocks a free launch day. The image is ours, like TAAFT's, so
    # the page still makes zero external requests.
    html = footer.render("index")
    link = re.search(r'<a href="https://ipip\.fyi/apps/m1k3\?ref=badge"([^>]*)>(.*?)</a>', html, re.DOTALL)
    assert link, "the home page footer has no link to M1K3 on iPip"
    rel = re.search(r'rel="([^"]*)"', link.group(1))
    assert not rel or not {"nofollow", "ugc", "sponsored"} & set(rel.group(1).split())
    src = re.search(r'<img [^>]*src="(/[^"]+)"', link.group(2))
    assert src and (SITE / src.group(1).lstrip("/")).exists()
    assert "ipip.fyi" not in footer.render("privacy")


def test_no_page_has_two_footers():
    # stamped() replaces the first only; a second would be left stale without a word.
    for page in footer.pages():
        assert page.read_text(encoding="utf-8").count("<footer>") == 1, page.name
