#!/usr/bin/env python3
"""IndexNow: tell Bing, DuckDuckGo, Yandex (and through Bing, ChatGPT search)
that m1k3.app pages changed — one POST, every URL in the sitemap.

    python3 tools/site/indexnow.py --dry-run            # print the payload
    python3 tools/site/indexnow.py                      # submit every sitemap URL
    python3 tools/site/indexnow.py https://m1k3.app/install   # just these

Run AFTER a Netlify deploy: the endpoint fetches https://m1k3.app/<key>.txt to
prove ownership, so the key file must already be live. The key file in site/
(basename = key, 32 hex chars) is the single source of truth; nothing else
holds the key. 200 / 202 both mean accepted.

Signed: Kev + claude-fable-5.1, 2026-09-15 (launch night), Confidence 0.8.
Ported from murphysig's submit-indexnow.sh into the shape this repo tests
(a pure payload builder + a thin main). The live POST is exercised by hand,
not by the tests. Prior: Unknown (new file).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ENDPOINT = "https://api.indexnow.org/indexnow"
HOST = "m1k3.app"
_KEY_FILE = re.compile(r"^[0-9a-f]{32}\.txt$")


def find_key(site_dir: Path) -> str:
    """The IndexNow key is the basename of the one <32 hex>.txt file in site/."""
    keys = sorted(p.stem for p in site_dir.iterdir() if _KEY_FILE.match(p.name))
    if len(keys) != 1:
        raise SystemExit(f"expected exactly one <32-hex>.txt key file in {site_dir}, found {keys}")
    key = keys[0]
    body = (site_dir / f"{key}.txt").read_text().strip()
    if body != key:
        raise SystemExit(f"key file {key}.txt must contain its own name, found {body!r}")
    return key


def sitemap_urls(sitemap: Path) -> list[str]:
    """Every <loc> in the sitemap, in document order, de-duplicated."""
    seen: list[str] = []
    for loc in re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", sitemap.read_text()):
        if loc not in seen:
            seen.append(loc)
    return seen


def payload(key: str, urls: list[str], host: str = HOST) -> dict:
    """The IndexNow JSON body. Every URL must be on the host the key proves."""
    bad = [u for u in urls if not u.startswith(f"https://{host}/") and u != f"https://{host}"]
    if bad:
        raise SystemExit(f"URLs off-host for {host}: {bad}")
    return {"host": host, "key": key, "keyLocation": f"https://{host}/{key}.txt", "urlList": list(urls)}


def submit(body: dict) -> tuple[int, str]:
    """POST the payload; returns (status, detail). IndexNow answers 200/202 for
    accepted, 400 malformed, 403 bad key, 422 off-host URLs, 429 rate-limited —
    urllib raises on every 4xx/5xx, so those come back as (status, reason)
    instead of a stack trace."""
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.reason or ""
    except urllib.error.HTTPError as e:
        return e.code, (e.reason or "") + " " + e.read().decode(errors="replace")[:200].strip()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("urls", nargs="*", help="URLs to submit (default: every sitemap <loc>)")
    ap.add_argument("--site-dir", default=str(Path(__file__).resolve().parents[3] / "site"))
    ap.add_argument("--dry-run", action="store_true", help="print the payload, no network")
    args = ap.parse_args(argv)
    site_dir = Path(args.site_dir)
    key = find_key(site_dir)
    urls = args.urls or sitemap_urls(site_dir / "sitemap.xml")
    body = payload(key, urls)
    if args.dry_run:
        print(json.dumps(body, indent=2))
        return 0
    status, detail = submit(body)
    print(f"indexnow: HTTP {status} {detail.strip()} for {len(urls)} URL(s)")
    return 0 if status in (200, 202) else 1


if __name__ == "__main__":
    sys.exit(main())
