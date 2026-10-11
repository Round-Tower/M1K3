"""Pins for the site's native-download path: Safari's App Store banner in every page's
head, and the "Send it to my Mac" door a phone (or any non-Mac) gets in place of the
Mac-only buttons.

Signed: Kev + claude-opus-5.5, 2026-10-11 (the Mac App Store went live that morning),
Confidence 0.8. The banner is iPhone/iPad Safari only (macOS Safari shows none), so on a
Mac the page's own App Store button is the native download; the platform is read in
<head> so a phone never flashes the Mac row. Prior: Unknown (new file).
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
SITE = REPO / "site"
APP_ID = re.search(r'^APP_ID = "(\d+)"', (REPO / "macos/tools/asc/asc.py").read_text(), re.MULTILINE).group(1)
BANNER = f'<meta name="apple-itunes-app" content="app-id={APP_ID}" />'
PAGES = sorted(SITE.glob("*.html"))
DOOR_PAGES = ["index.html", "install.html"]
HEAD_SCRIPT = re.compile(r"<script>\s*/\*.*?\*/\s*(\(function \(n\) \{.*?\}\)\(navigator\);)\s*</script>", re.DOTALL)


def _head(html: str) -> str:
    return html.split("</head>", 1)[0]


@pytest.mark.parametrize("page", PAGES, ids=lambda p: p.name)
def test_every_page_carries_safaris_app_store_banner(page: Path):
    assert _head(page.read_text()).count(BANNER) == 1


def test_the_brains_generator_keeps_the_banner():
    # brains.html is generated; a regenerate must not drop the tag.
    assert BANNER in (REPO / "macos/tools/eval/brains_page.py").read_text()


def _door_script(name: str) -> str:
    # The inline <head> script, not the CSS selectors that also say data-platform.
    found = HEAD_SCRIPT.search(_head((SITE / name).read_text()))
    assert found, f"{name}: no platform script in <head>"
    return found.group(1)


@pytest.mark.parametrize("name", DOOR_PAGES)
def test_the_platform_is_known_before_first_paint(name: str):
    assert "setAttribute('data-platform'" in _door_script(name)


def test_both_doors_read_the_platform_the_same_way():
    assert _door_script("index.html") == _door_script("install.html")


def test_without_js_every_visitor_gets_the_mac_row():
    assert ".cta-away, .only-ios { display: none; }" in (SITE / "index.html").read_text()
    assert ".only-away { display: none; }" in (SITE / "install.html").read_text()


def test_every_away_row_still_links_the_store():
    # A crawler that runs JS reads as "other" and gets the away row, so it must carry the store link too.
    rows = re.findall(r'<div class="cta-row cta-away[^"]*"[^>]*>(.*?)</div>', (SITE / "index.html").read_text(), re.DOTALL)
    assert len(rows) == 2
    for row in rows:
        assert f'href="https://apps.apple.com/app/id{APP_ID}"' in row


@pytest.mark.parametrize("name", DOOR_PAGES)
def test_phones_get_a_send_to_mac_door(name: str):
    html = (SITE / name).read_text()
    assert "data-send-to-mac" in html
    assert '<script src="/send-to-mac.js" defer></script>' in html


def test_every_mac_cta_row_on_home_has_an_away_twin():
    html = (SITE / "index.html").read_text()
    assert html.count('class="cta-row cta-mac') == html.count('class="cta-row cta-away') == 2


def test_send_to_mac_sends_nothing_anywhere():
    js = (SITE / "send-to-mac.js").read_text()
    for beacon in ("fetch(", "XMLHttpRequest", "sendBeacon", "localStorage", "document.cookie"):
        assert beacon not in js, beacon
    assert f"https://apps.apple.com/app/id{APP_ID}" in js
    assert "aria-live" in js  # "Link copied ✓" is announced, not just drawn
