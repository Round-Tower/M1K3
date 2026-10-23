#!/usr/bin/env python3
"""Where M1K3 ranks in App Store search, per term × storefront × platform, logged daily.

  ranks.py                                  every term in rank_terms.txt, default storefronts, iOS + Mac
  ranks.py --country kz,uz --platform ios   narrow the sweep
  ranks.py "local ai" "offline ai"          ad-hoc terms instead of the file
  ranks.py --vs 2026-10-30                  movement against the newest run on or before that day
                                            (the before/after for a keyword-field change)
  ranks.py --no-log                         look without appending
  ranks.py --log PATH                       another log (a worktree's own marketing/ starts empty)

Movement is against the newest run of an EARLIER day (a same-day rerun compares with yesterday),
or with --vs, the newest run up to and including that day. A cell reads `36 ▲4` (up four), `new`
(entered the top 200), `lost` (left it), `·` (no earlier run) or `?` (Apple answered nothing: a
throttle, not a rank, so it is neither logged nor used as a baseline). Throttles (403/429) and
server errors (5xx), timeouts and non-JSON pages are retried with backoff; a search that still
fails is reported and skipped, and every result is appended as it arrives.

Why: the organic iOS downloads come from KZ/UZ/IN search, not the ad countries, and the
day-14 keyword swap (2026-10-30) needs a before/after. The sweep reads Apple's public iTunes
Search API (no key, stdlib only), which approximates the store's ranking rather than reproducing it —
trust the trend, not the exact slot. Apple throttles it near 20 requests a minute, so a full
sweep (terms × 8 storefronts × 2 platforms) takes about ten minutes. Each result is appended
to marketing/metrics/ranks.jsonl (gitignored), the same home as metrics.py's repo.jsonl.

Signed: Kev + claude-opus-5.5, 2026-10-23, Confidence 0.75 (the API's order is a proxy for the
  store's; the Mac search entity did not list M1K3 at all on the day this was written, even for
  "m1k3", so a Mac "—" may be the API's blind spot rather than the store's — UNVERIFIED).
Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: marketing/rank_check.py (US, iOS, top
  50, unlogged), which this replaces.
Review: Kev + claude-opus-5.5, 2026-10-23 — pre-push review fold: append per result (a crash lost
  the sweep), retry timeouts and non-JSON pages, an empty answer is `?` and never a baseline, the
  depth read is logged and matched, same-day ties take the last line, --vs is validated, terms are
  lowercased and deduped, corrupt log lines are skipped, --log for worktrees.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

APP_ID = 6780230835
TERMS = Path(__file__).resolve().parent / "rank_terms.txt"
LOG = Path(os.environ.get("RANKS_LOG") or Path(__file__).resolve().parents[3] / "marketing" / "metrics" / "ranks.jsonl")
# Ad countries first, then where the organic iOS search traffic comes from (2026-10-22 read).
DEFAULT_COUNTRIES = "us,gb,ie,ca,au,kz,uz,in"
ENTITY = {"ios": "software", "mac": "macSoftware"}
MAX_LIMIT = 200  # the Search API's own ceiling
DELAY_S = 3.2    # under Apple's ~20 requests/minute
RETRY_CODES = frozenset({403, 429, 500, 502, 503, 504})  # Apple throttles with 403 as often as 429
ATTEMPTS = 4


# ── pure ─────────────────────────────────────────────────────────────────────

def search_url(term: str, country: str, platform: str, limit: int) -> str:
    query = {"term": term, "country": country, "entity": ENTITY[platform], "limit": min(limit, MAX_LIMIT)}
    return "https://itunes.apple.com/search?" + urllib.parse.urlencode(query)


def rank_of(results: list[dict[str, Any]], track_id: int) -> int | None:
    return next((i + 1 for i, r in enumerate(results) if r.get("trackId") == track_id), None)


def entry(date: str, term: str, country: str, platform: str,
          results: list[dict[str, Any]], track_id: int, *, limit: int = MAX_LIMIT) -> dict[str, Any]:
    lead = results[0] if results else None
    return {"date": date, "term": term, "country": country, "platform": platform,
            "rank": rank_of(results, track_id), "n": len(results), "limit": min(limit, MAX_LIMIT),
            "leader": lead and lead.get("trackName"), "leader_ratings": lead and lead.get("userRatingCount", 0)}


def baseline(log: list[dict[str, Any]], term: str, country: str, platform: str, *,
             before: str, on_or_before: str | None = None, limit: int = MAX_LIMIT) -> dict[str, Any] | None:
    """The run to compare against: the newest of an earlier day, or with on_or_before, the newest up to
    and including that day. Same-day ties take the line written last. A run that read fewer results
    than this one, or got none at all (a throttle), never counts."""
    def counts(line: dict[str, Any]) -> bool:
        if (line.get("term"), line.get("country"), line.get("platform")) != (term, country, platform):
            return False
        if line.get("n") == 0 or line.get("limit", MAX_LIMIT) < min(limit, MAX_LIMIT):
            return False
        return line["date"] <= on_or_before if on_or_before is not None else line["date"] < before

    hits = [(line["date"], i, line) for i, line in enumerate(log) if counts(line)]
    return max(hits, key=lambda hit: hit[:2])[2] if hits else None


def movement(now: int | None, then: int | None, *, had_baseline: bool = True) -> str:
    if not had_baseline:
        return ""
    if now is None and then is None:
        return ""
    if then is None:
        return "new"
    if now is None:
        return "lost"
    if now == then:
        return "="
    return f"▲{then - now}" if now < then else f"▼{now - then}"


def cell(line: dict[str, Any], base: dict[str, Any] | None) -> str:
    if line["n"] == 0:
        return "?"
    shown = str(line["rank"]) if line["rank"] is not None else "—"
    move = movement(line["rank"], base["rank"], had_baseline=True) if base is not None else "·"
    return f"{shown}{move and ' ' + move}"


def split_list(text: str) -> list[str]:
    return [part.strip().lower() for part in text.split(",") if part.strip()]


def clean_terms(terms: list[str]) -> list[str]:
    """Lowercased, blank-free, first occurrence kept: the log keys on the exact string."""
    return list(dict.fromkeys(t.strip().lower() for t in terms if t.strip()))


def load_terms(path: Path) -> list[str]:
    """One term per line; `#` opens a comment at a line's start or after a space, so `c#` survives."""
    lines = path.read_text(encoding="utf-8").splitlines()
    return clean_terms([line.split(" #", 1)[0] for line in lines if not line.lstrip().startswith("#")])


def iso_day(text: str) -> str:
    try:
        if len(text) == 10:  # fromisoformat also takes 20261030
            return dt.date.fromisoformat(text).isoformat()
    except ValueError:
        pass
    raise argparse.ArgumentTypeError(f"{text!r} is not a YYYY-MM-DD day")


# ── I/O ──────────────────────────────────────────────────────────────────────

def search(term: str, country: str, platform: str, limit: int) -> list[dict[str, Any]]:
    """One search, retried with backoff on a throttle, a server error, a dropped connection or a
    non-JSON page; a 4xx that isn't a throttle (a bad country code) raises at once."""
    req = urllib.request.Request(search_url(term, country, platform, limit), headers={"User-Agent": "m1k3-ranks"})
    for attempt in range(ATTEMPTS):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp).get("results", [])
        except urllib.error.HTTPError as err:
            if err.code not in RETRY_CODES or attempt == ATTEMPTS - 1:
                raise
        except (OSError, json.JSONDecodeError):  # URLError, timeouts, resets
            if attempt == ATTEMPTS - 1:
                raise
        time.sleep(30 * (attempt + 1))
    raise AssertionError("unreachable")


def read_log(path: Path) -> list[dict[str, Any]]:
    """Every whole line; a torn one (a Ctrl-C mid-append) or a keyless one is skipped, not fatal."""
    if not path.exists():
        return []
    lines = []
    for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            line = json.loads(text) if text.strip() else None
        except json.JSONDecodeError:
            line = None
        if isinstance(line, dict) and {"date", "term", "country", "platform", "rank"} <= line.keys():
            lines.append(line)
        elif text.strip():
            print(f"{path.name}:{number}: skipped a damaged line", file=sys.stderr)
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("terms", nargs="*", help="terms to check (default: rank_terms.txt)")
    ap.add_argument("--country", default=DEFAULT_COUNTRIES, help=f"comma list (default {DEFAULT_COUNTRIES})")
    ap.add_argument("--platform", default="ios,mac", help="ios, mac or both (default ios,mac)")
    ap.add_argument("--limit", type=int, default=MAX_LIMIT, help="results read per search (max 200)")
    ap.add_argument("--vs", metavar="YYYY-MM-DD", type=iso_day,
                    help="compare with the newest run on or before this day (default: the previous day's run)")
    ap.add_argument("--log", type=Path, default=LOG, help="the JSONL log (default marketing/metrics/ranks.jsonl"
                    " in this checkout, or $RANKS_LOG)")
    ap.add_argument("--no-log", action="store_true", help="look without appending")
    args = ap.parse_args(argv)

    terms = clean_terms(args.terms) if args.terms else load_terms(TERMS)
    countries = split_list(args.country)
    platforms = split_list(args.platform)
    if not terms or not countries or not platforms:
        ap.error("need at least one term, storefront and platform")
    if bad := [p for p in platforms if p not in ENTITY]:
        ap.error(f"unknown platform {bad}; use ios and/or mac")
    limit = min(args.limit, MAX_LIMIT)
    # The UTC day: the log is keyed by day, and one zone keeps a late-evening run from straddling two.
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    log = read_log(args.log)
    print(f"{len(terms)} terms × {len(countries)} storefronts × {len(platforms)} platforms, top {limit}"
          f" — vs {args.vs or 'the previous day'}", file=sys.stderr)

    out = None if args.no_log else _open_log(args.log)
    width = max(len(t) for t in terms) + 6
    print(f"{'term':{width}} " + " ".join(f"{c:>10}" for c in countries))
    searched = failed = 0
    try:
        for platform in platforms:
            for term in terms:
                cells = []
                for country in countries:
                    if searched:
                        time.sleep(DELAY_S)
                    searched += 1
                    try:
                        results = search(term, country, platform, limit)
                    except (OSError, json.JSONDecodeError) as err:
                        failed += 1
                        print(f"{term} {country} {platform}: {err}", file=sys.stderr)
                        cells.append("err")
                        continue
                    line = entry(today, term, country, platform, results, APP_ID, limit=limit)
                    if out and line["n"]:
                        out.write(json.dumps(line, ensure_ascii=False) + "\n")
                        out.flush()
                    base = baseline(log, term, country, platform, before=today, on_or_before=args.vs, limit=limit)
                    cells.append(cell(line, base))
                print(f"{term + ' ' + platform:{width}} " + " ".join(f"{c:>10}" for c in cells), flush=True)
    finally:
        if out:
            out.close()
            print(f"logged to {args.log}", file=sys.stderr)
    return 1 if failed else 0


def _open_log(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    out = path.open("a", encoding="utf-8")
    # A torn last line (a Ctrl-C mid-write) would glue onto the next record: start on a fresh line.
    if path.stat().st_size and not path.read_bytes().endswith(b"\n"):
        out.write("\n")
    return out


if __name__ == "__main__":
    sys.exit(main())
