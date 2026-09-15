#!/usr/bin/env python3
"""Generate site/llms-full.txt — every answer page on m1k3.app as one text file,
the llmstxt.org companion to llms.txt (which is the index).

    python3 tools/site/llms_full.py                 # writes site/llms-full.txt
    python3 tools/site/llms_full.py --check         # exit 1 if the file is stale

Each page's <main> is converted to plain text with light markdown: headings,
paragraphs, lists, fenced code, pipe tables, FAQ details as Q/A. Navigation,
footer, scripts, the "more answers" aside and the closing CTA are dropped.
Links keep their absolute URL in parentheses so a citing model can point back.
install.txt is included verbatim. Regenerate whenever a site page changes;
the --check mode is for a CI guard.

Signed: Kev + claude-fable-5.1, 2026-09-15 (launch night), Confidence 0.8.
A generator, not hand copy, so the full file cannot drift from the pages.
The page list is explicit (PAGES) because the home page is a marketing
surface with a THREE.js hero, not an answer. Prior: Unknown (new file).
"""
from __future__ import annotations

import argparse
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

SITE_ROOT = "https://m1k3.app"

# (file, slug) in reading order: install first, then the on-ramps, then the answers.
PAGES: list[tuple[str, str]] = [
    ("install.html", "install"),
    ("agents.html", "agents"),
    ("privacy.html", "privacy"),
    ("mcp-knowledge-server.html", "mcp-knowledge-server"),
    ("vs-ollama.html", "vs-ollama"),
    ("private-chatgpt-alternative-mac.html", "private-chatgpt-alternative-mac"),
    ("local-llm-mac-guide.html", "local-llm-mac-guide"),
    ("brains.html", "brains"),
    ("golden-gate-on-device-ai.html", "golden-gate-on-device-ai"),
    ("teams.html", "teams"),
    ("companions.html", "companions"),
]

SKIP_TAGS = {"script", "style", "nav", "footer", "svg", "button", "input", "label"}
SKIP_CLASSES = {"more", "page-cta", "term-bar", "wiz-doors", "wiz-note", "clients", "copy-btn", "label"}
# Void elements never close, so they must never sit on the stack or count toward a skip.
VOID_TAGS = {"br", "hr", "img", "input", "meta", "link", "source", "wbr"}
BLOCK_TAGS = {"p", "li", "h1", "h2", "h3", "h4", "pre", "tr", "summary", "div", "section", "header", "aside", "details", "table", "ul", "ol", "blockquote"}


class _Text(HTMLParser):
    """Walks <main> and emits markdown-ish lines."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.lines: list[str] = []
        self._buf: list[str] = []
        # (tag, counted-toward-skip): a skipped subtree's every descendant counts,
        # so the close of each one decrements — the bug the first cut had was a
        # <span> inside .term-bar incrementing on open and never on close.
        self._stack: list[tuple[str, bool]] = []
        self._skip = 0
        self._in_main = False
        self._pre = 0
        self._cell: list[str] = []
        self._row: list[str] | None = None
        self._href: str | None = None
        self._list: list[str] = []

    # -- helpers -----------------------------------------------------------
    def _flush(self, prefix: str = "") -> None:
        text = "".join(self._buf)
        self._buf = []
        text = text if self._pre else re.sub(r"\s+", " ", text).strip()
        if text:
            self.lines.append(prefix + text)

    # -- parser callbacks ----------------------------------------------------
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        classes = set((a.get("class") or "").split())
        if tag == "main":
            self._in_main = True
        if not self._in_main:
            return
        counted = bool(self._skip) or tag in SKIP_TAGS or bool(classes & SKIP_CLASSES)
        if tag in VOID_TAGS:
            if not counted and tag == "br":
                self._buf.append("\n" if self._pre else " ")
            return
        if counted:
            self._skip += 1
            self._stack.append((tag, True))
            return
        if tag in BLOCK_TAGS and tag != "pre":
            self._flush()
        if tag in ("ul", "ol"):
            self._list.append(tag)
        if tag == "pre":
            self._flush()
            self.lines.append("```")
            self._pre += 1
        if tag == "tr":
            self._row = []
        if tag in ("td", "th"):
            self._cell = []
        if tag == "a":
            self._href = a.get("href")
        self._stack.append((tag, False))

    def handle_endtag(self, tag):
        if not self._in_main or tag in VOID_TAGS:
            return
        counted = False
        if self._stack and self._stack[-1][0] == tag:
            _, counted = self._stack.pop()
        if counted:
            self._skip -= 1
            return
        if self._skip:
            return
        if tag == "main":
            self._flush()
            self._in_main = False
            return
        if tag in ("td", "th"):
            cell = re.sub(r"\s+", " ", "".join(self._buf)).strip()
            self._buf = []
            if self._row is not None:
                self._row.append(cell)
            return
        if tag == "tr":
            if self._row:
                self.lines.append("| " + " | ".join(self._row) + " |")
            self._row = None
            return
        if tag == "pre":
            text = "".join(self._buf).strip("\n")
            self._buf = []
            self.lines.extend(text.split("\n"))
            self.lines.append("```")
            self._pre -= 1
            return
        if tag == "a" and self._href and self._href.startswith("http") and self._buf:
            self._buf.append(f" ({self._href})")
            self._href = None
            return
        if tag == "a":
            self._href = None
            return
        if tag in ("ul", "ol") and self._list:
            self._list.pop()
        prefixes = {"h1": "## ", "h2": "### ", "h3": "#### ", "h4": "##### ", "li": "- ", "summary": "**Q: "}
        if tag in prefixes:
            self._flush(prefixes[tag])
            if tag == "summary" and self.lines:
                self.lines[-1] += "**"
        elif tag in BLOCK_TAGS:
            self._flush()

    def handle_data(self, data):
        if self._in_main and not self._skip:
            self._buf.append(data)


def page_text(source: str) -> str:
    """Plain text of a page's <main>, blank-line separated."""
    parser = _Text()
    parser.feed(source)
    parser.close()
    out: list[str] = []
    in_code = False
    for line in parser.lines:
        if line == "```":
            in_code = not in_code
            out.append(line)
            continue
        if in_code:
            out.append(line)
        else:
            out.append(line)
            out.append("")
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def build(site_dir: Path) -> str:
    head = [
        "# M1K3 for Mac — the full text",
        "",
        "> The llmstxt.org companion to https://m1k3.app/llms.txt: every answer page on",
        "> m1k3.app as one file, generated from the pages themselves. M1K3 is free,",
        "> source-available (FSL-1.1-ALv2), privacy-first AI for macOS that runs entirely",
        "> on-device — local brains, live voice, a knowledge graph, a memory graph, and an",
        "> MCP server on loopback. Made by Round Tower, Ireland.",
        "",
        "Sources, in order: " + ", ".join(f"{SITE_ROOT}/{slug}" for _, slug in PAGES) + f", {SITE_ROOT}/install.txt.",
        "",
    ]
    parts = ["\n".join(head)]
    for file, slug in PAGES:
        path = site_dir / file
        if not path.exists():
            continue
        parts.append(f"\n---\n\n## Source: {SITE_ROOT}/{slug}\n\n{page_text(path.read_text())}")
    recipe = site_dir / "install.txt"
    if recipe.exists():
        parts.append(f"\n---\n\n## Source: {SITE_ROOT}/install.txt (verbatim)\n\n```\n{recipe.read_text().rstrip()}\n```\n")
    return "".join(parts)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--site-dir", default=str(Path(__file__).resolve().parents[3] / "site"))
    ap.add_argument("--check", action="store_true", help="exit 1 if site/llms-full.txt is stale")
    args = ap.parse_args(argv)
    site_dir = Path(args.site_dir)
    out = site_dir / "llms-full.txt"
    text = build(site_dir)
    if args.check:
        current = out.read_text() if out.exists() else ""
        if current != text:
            print("llms-full.txt is stale — run: python3 tools/site/llms_full.py", file=sys.stderr)
            return 1
        print("llms-full.txt is current")
        return 0
    out.write_text(text)
    print(f"wrote {out} ({len(text):,} chars, {len(PAGES)} pages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
