"""Every page's JSON-LD parses, the homepage's SoftwareApplication says what the
App Store and the repo say (#573), and the homepage links its guides (#572).

Search engines and AI agents read these blocks before the page. A block that
does not parse is silently dropped; one that says the wrong category, a stale
version or "open source" is repeated as fact.

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9. Prior: none (new file).
Review: Kev + claude-opus-5.5, 2026-10-22 — operatingSystem names iOS and iPadOS 26 now the
iPhone & iPad app is live on the same record. Confidence 0.9.
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
    assert app["operatingSystem"] == "macOS 26 or later, iOS 26 or later, iPadOS 26 or later" and "or later" in app["softwareRequirements"]
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


def test_each_guide_has_a_breadcrumb_trail_home_to_itself():
    # #572: a crawler places each guide under the homepage, not floating in the sitemap.
    for slug in GUIDES:
        page = SITE / f"{slug}.html"
        crumbs = next((b for b in blocks(page) if b.get("@type") == "BreadcrumbList"), None)
        assert crumbs is not None, f"{slug} has no BreadcrumbList"
        items = crumbs["itemListElement"]
        assert [i["position"] for i in items] == [1, 2], slug
        assert items[0]["item"] == "https://m1k3.app/"
        canonical = re.search(r'<link rel="canonical" href="([^"]*)"', page.read_text(encoding="utf-8")).group(1)
        assert items[1]["item"] == canonical, slug


def test_every_footer_links_every_guide():
    # #572: each guide links the others, and every page carries the list.
    pages = [p for p in sorted(SITE.glob("*.html")) if "<footer>" in p.read_text(encoding="utf-8")]
    assert len(pages) >= 10, "the footer scan stopped finding pages"
    for page in pages:
        footer = re.search(r"<footer>.*?</footer>", page.read_text(encoding="utf-8"), re.DOTALL).group(0)
        for slug in GUIDES:
            assert f'href="/{slug}"' in footer, f"{page.name}'s footer does not link /{slug}"


def test_every_page_names_its_canonical_url():
    for page in sorted(SITE.glob("*.html")):
        assert '<link rel="canonical" href="https://m1k3.app/' in page.read_text(encoding="utf-8"), page.name


# Directory listings (There's An AI For That, 2026-10-18) refuse a submission unless the site
# links a Privacy Policy AND a Terms of Service. Both live as pages; every footer points at them.
LEGAL = ("privacy", "terms")


def test_every_footer_links_the_privacy_policy_and_the_terms():
    pages = [p for p in sorted(SITE.glob("*.html")) if "<footer>" in p.read_text(encoding="utf-8")]
    assert len(pages) >= 10, "the footer scan stopped finding pages"
    for slug in LEGAL:
        assert (SITE / f"{slug}.html").is_file(), slug
    for page in pages:
        footer = re.search(r"<footer>.*?</footer>", page.read_text(encoding="utf-8"), re.DOTALL).group(0)
        for slug in LEGAL:
            assert f'href="/{slug}"' in footer, f"{page.name}'s footer does not link /{slug}"


def test_the_legal_pages_say_what_they_are_in_the_title():
    # A reviewer lands on the page and reads the tab: it must say "Privacy Policy" / "Terms".
    for slug, needle in (("privacy", "Privacy Policy"), ("terms", "Terms of Service")):
        text = (SITE / f"{slug}.html").read_text(encoding="utf-8")
        title = re.search(r"<title>(.*?)</title>", text, re.DOTALL).group(1)
        assert needle in title, f"{slug}: <title> is {title!r}"
        assert "Round Tower Software Ltd" in text, slug


# The policy says every page serves its own fonts, scripts and models, with one named exception:
# the experimental /vr demo loads three.js from jsDelivr. A new third-party load must be named
# on the privacy page before it ships, so this list is the policy's twin.
THIRD_PARTY_LOADS = {"vr.html": {"https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"}}
EXTERNAL_SRC = re.compile(r'<(?:script|link|img|iframe|video|audio|source)[^>]+(?:src|href)="(https?://[^"]+)"')


def test_no_page_loads_a_third_party_asset_the_privacy_policy_does_not_name():
    for page in sorted(SITE.glob("*.html")):
        text = page.read_text(encoding="utf-8")
        loads = set()
        for tag_src in EXTERNAL_SRC.findall(text):
            # a <link rel="canonical"/"license"> or a plain <a> is a reference, not a load
            if tag_src.startswith("https://m1k3.app/"):
                continue
            loads.add(tag_src)
        assert loads == THIRD_PARTY_LOADS.get(page.name, set()), f"{page.name} loads {sorted(loads)}"
    privacy = (SITE / "privacy.html").read_text(encoding="utf-8")
    assert "jsDelivr" in privacy and 'href="/vr"' in privacy


def test_the_legal_pages_are_in_the_sitemap_and_llms_txt():
    sitemap = (SITE / "sitemap.xml").read_text(encoding="utf-8")
    llms = (SITE / "llms.txt").read_text(encoding="utf-8")
    for slug in LEGAL:
        assert f"<loc>https://m1k3.app/{slug}</loc>" in sitemap, slug
        assert f"(https://m1k3.app/{slug})" in llms, slug
