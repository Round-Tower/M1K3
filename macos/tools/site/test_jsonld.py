"""Every page's JSON-LD parses, the homepage's SoftwareApplication says what the
App Store and the repo say (#573), and the homepage links its guides (#572).

Search engines and AI agents read these blocks before the page. A block that
does not parse is silently dropped; one that says the wrong category, a stale
version or "open source" is repeated as fact.

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9. Prior: none (new file).
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "site"
BLOCK = re.compile(r'<script type="application/ld\+json">(.*?)</script>', re.DOTALL)
APP_ID = "6780230835"
GUIDES = ("mcp-knowledge-server", "vs-ollama", "private-chatgpt-alternative-mac", "local-llm-mac-guide",
          "golden-gate-on-device-ai")


def blocks(page: pathlib.Path) -> list[dict]:
    return [json.loads(raw) for raw in BLOCK.findall(page.read_text(encoding="utf-8"))]


def homepage_app() -> dict:
    app = next((b for b in blocks(SITE / "index.html") if b.get("@type") == "SoftwareApplication"), None)
    assert app is not None, "index.html has no SoftwareApplication block"
    return app


def test_every_json_ld_block_on_every_page_parses_and_is_found():
    pages = sorted(SITE.glob("*.html"))
    assert pages, f"no pages under {SITE}"
    for page in pages:
        text = page.read_text(encoding="utf-8")
        # a tag the regex misses (an added id=, single quotes) would go unchecked
        assert text.count("application/ld+json") == len(BLOCK.findall(text)), page.name
        try:
            parsed = blocks(page)
        except json.JSONDecodeError as err:
            raise AssertionError(f"{page.name}: JSON-LD does not parse: {err}") from err
        for block in parsed:
            # a block without @context or @type parses and is still ignored
            assert "@context" in block and "@type" in block, page.name


def test_no_page_invents_a_rating():
    # No aggregateRating until there are real App Store ratings to cite.
    for page in sorted(SITE.glob("*.html")):
        assert "aggregateRating" not in json.dumps(blocks(page)), page.name


def test_the_homepage_app_says_what_the_store_and_repo_say():
    app = homepage_app()
    store_category = (ROOT / "macos/fastlane/metadata_mac/primary_category.txt").read_text().strip()
    assert app["applicationCategory"] == f"{store_category.capitalize()}Application"
    assert "softwareVersion" not in app, "a version here drifts from every release"
    assert (ROOT / "LICENSE").is_file()
    assert app["license"] == "https://github.com/Round-Tower/M1K3/blob/master/LICENSE"
    assert app["publisher"]["legalName"] == "Round Tower Software Ltd"
    assert app["author"]["name"] == app["publisher"]["name"] == "Round Tower"
    assert app["operatingSystem"] == "macOS 26 or later" and "or later" in app["softwareRequirements"]
    store = f"https://apps.apple.com/app/id{APP_ID}"
    assert app["downloadUrl"] == app["offers"]["url"] == store
    assert app["offers"]["price"] == "0" and app["offers"]["priceCurrency"] == "EUR"
    # FSL is source-available. The FAQPage may say "not open source"; the app block says nothing of the kind.
    assert "open source" not in json.dumps(app).lower() and "open-source" not in json.dumps(app).lower()


def test_the_homepage_links_every_guide():
    page = (SITE / "index.html").read_text(encoding="utf-8")
    for slug in GUIDES:
        assert (SITE / f"{slug}.html").is_file(), slug
        assert f'href="/{slug}"' in page, f"the homepage does not link /{slug}"
