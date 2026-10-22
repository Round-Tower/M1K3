"""One tagline everywhere it is written: "Your AI. Your devices. Private by design."

Kev's 2026-10-20 ruling: when iOS went live the line moved from "Your Mac" to "Your devices"
across the site, the README and the brand images in one pass, so no surface says one while
another says the other. iOS 1.2.0 went live 2026-10-21.

Signed: Kev + claude-opus-5.5, 2026-10-22, Confidence 0.85. Prior: none (new file).
"""
import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
TAGLINE = "Your AI. Your devices. Private by design."
OLD = re.compile(r"Your AI\.\s*(?:<br />\s*)?Your Mac\.")
SURFACES = [
    "README.md",
    "SECURITY.md",
    "site/index.html",
    "macos/tools/site/brand/og.html",
    "macos/tools/site/brand/readme-hero.html",
    "macos/tools/eval/brains_page.py",
    *sorted(str(p.relative_to(ROOT)) for p in (ROOT / "site").glob("*.html")),
]


def _outside_signatures(text: str) -> str:
    # Review lines quote the old line as history; only live copy counts.
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


@pytest.mark.parametrize("rel", sorted(set(SURFACES)))
def test_no_surface_still_says_your_mac(rel: str):
    assert not OLD.search(_outside_signatures((ROOT / rel).read_text(encoding="utf-8"))), rel


def test_the_headlines_carry_the_tagline():
    assert f'<h1 align="center">{TAGLINE}</h1>' in (ROOT / "README.md").read_text(encoding="utf-8")
    home = (ROOT / "site/index.html").read_text(encoding="utf-8")
    assert f"<title>M1K3 — {TAGLINE}</title>" in home
    assert f'<meta property="og:title" content="M1K3 — {TAGLINE}" />' in home
    for rel in ("site/index.html", "macos/tools/site/brand/og.html", "macos/tools/site/brand/readme-hero.html"):
        assert "Your AI.<br />Your devices.<br />" in (ROOT / rel).read_text(encoding="utf-8"), rel
