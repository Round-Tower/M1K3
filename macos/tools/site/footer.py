#!/usr/bin/env python3
"""One footer for every page of the site, in grouped columns.

Usage:
    python3 tools/site/footer.py           # write the footer into every page
    python3 tools/site/footer.py --check   # exit 1 if a page's footer has drifted

The footer used to be hand-copied into fourteen pages and had drifted: twelve
pages never linked /agents, three had lost the Apple service-mark line, and no
footer linked /install. This is the one source. `site/brains.html` is generated,
so `tools/eval/brains_page.py` calls `render("brains")` and stays in step.

A page keeps a bare `<footer>` tag (test_jsonld.py scans for it). Pages without
a footer (vr.html, a full-screen scene) are left alone.

Signed: Kev + claude-fable-5.2, 2026-11-16, Confidence 0.8. Prior: none (new file).
Context: Kev, 2026-11-16: "the footer needs some love" and "Grouped collumes please
for the footer amigo".
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parents[3] / "site"

# (heading, [(href, label)]). Sentence case on purpose: a long run of capitals is
# the hardest thing on the page to read.
COLUMNS: list[tuple[str, list[tuple[str, str]]]] = [
    (
        "M1K3",
        [
            ("/install", "Install"),
            ("/brains", "The brains"),
            ("/companions", "Companions"),
            ("/vr", "Memory Sky for Vision Pro"),
            ("/teams", "For teams"),
        ],
    ),
    (
        "Build with it",
        [
            ("/agents", "For coding agents"),
            ("/local-api", "Local API"),
            ("/weights", "Model weights"),
            ("https://github.com/Round-Tower/M1K3", "GitHub"),
            ("https://github.com/sponsors/Round-Tower", "Sponsor"),
        ],
    ),
    (
        "Guides",
        [
            ("/local-llm-mac-guide", "Local LLMs on a Mac"),
            ("/vs-ollama", "M1K3 vs Ollama"),
            ("/private-chatgpt-alternative-mac", "Private ChatGPT alternative"),
            ("/mcp-knowledge-server", "A local memory for Claude"),
            ("/golden-gate-on-device-ai", "On-device AI in macOS 27"),
        ],
    ),
    (
        "Small print",
        [
            ("/privacy", "Privacy policy"),
            ("/terms", "Terms"),
            ("https://round-tower.ie", "Round Tower Software"),
        ],
    ),
]

FOX_CREDIT = (
    'Fox model: <a href="https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox" '
    'rel="license">PixelMannen and tomkranis, CC-BY 4.0</a>.'
)
CREATURES_CREDIT = 'Creatures: <a href="https://quaternius.com" rel="license">Quaternius, CC0</a>.'

# What only some pages carry. The fox is drawn on the home page; the whole cast
# on /companions.
CREDITS = {"index": [FOX_CREDIT], "companions": [FOX_CREDIT, CREATURES_CREDIT]}

SHARE = (
    '  <p class="foot-extra"><button class="share-link" id="shareBtn" type="button" '
    'aria-label="Share M1K3">Share M1K3</button></p>\n'
)
FEATURED = (
    '  <p class="foot-extra featured"><a href="https://theresanaiforthat.com/ai/m1k3/?ref=featured&amp;v=13348798" '
    'target="_blank" rel="nofollow noopener"><img width="300" height="63" src="/featured-on-taaft.png" '
    'alt="Featured on There\'s An AI For That"></a></p>\n'
)

FOOTER = re.compile(r"<footer>.*?</footer>", re.DOTALL)


def render(slug: str) -> str:
    """The footer for the page at /<slug> ("index" for the home page)."""
    here = "/" if slug == "index" else f"/{slug}"
    out = ["<footer>", '  <div class="foot-cols">']
    for heading, links in COLUMNS:
        out.append("    <div>")
        out.append(f'      <p class="foot-h">{heading}</p>')
        out.append("      <ul>")
        for href, label in links:
            current = ' aria-current="page"' if href == here else ""
            out.append(f'        <li><a href="{href}"{current}>{label}</a></li>')
        out.append("      </ul>")
        out.append("    </div>")
    out.append("  </div>")
    body = "\n".join(out) + "\n"
    if slug == "index":
        body += SHARE + FEATURED
    body += (
        '  <p class="foot-line">© 2026 Round Tower Software Ltd. Made in Ireland. '
        "No tracking on this page, obviously.</p>\n"
    )
    small = ["Mac App Store and App Store are service marks of Apple Inc.", *CREDITS.get(slug, [])]
    body += f'  <p class="foot-line foot-faint">{" ".join(small)}</p>\n'
    return body + "</footer>"


def pages() -> list[Path]:
    return [p for p in sorted(SITE.glob("*.html")) if "<footer>" in p.read_text(encoding="utf-8")]


def stamped(page: Path) -> str:
    html = page.read_text(encoding="utf-8")
    footer = render(page.stem)
    return FOOTER.sub(lambda _: footer, html, count=1)


def main(argv: list[str]) -> int:
    check = "--check" in argv
    drifted = []
    for page in pages():
        want = stamped(page)
        if want != page.read_text(encoding="utf-8"):
            drifted.append(page.name)
            if not check:
                page.write_text(want, encoding="utf-8")
    if check and drifted:
        print("footer drifted on: " + ", ".join(drifted) + ". Run tools/site/footer.py.")
        return 1
    print(("checked" if check else "wrote") + f" {len(pages())} footers" + ("" if check else f", {len(drifted)} changed"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
