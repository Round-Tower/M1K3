#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Reach without telemetry: what Apple and GitHub count on our behalf.

  metrics.py store [--days 14]              App Store units per day from the sales reports:
                                            downloads (first-time + redownloads), updates, by
                                            platform and country. Needs ASC_VENDOR_NUMBER.
  metrics.py analytics request              ask ASC for ONGOING analytics reports (once per app)
  metrics.py analytics list                 the reports the request produced (names + categories)
  metrics.py analytics fetch [--name "App Downloads Standard"] [--days 14] [--out DIR]
                                            download the daily instances of one report as CSV
  metrics.py repo                           GitHub stars, forks, DMG downloads per release, traffic
                                            and referrers; writes one dated line per day to
                                            marketing/metrics/repo.jsonl (gitignored) because
                                            GitHub keeps traffic for 14 days only

Why: the app sends nothing home (no telemetry, by design), so reach is read from the counters
that already exist on the other side of the door. The sales report is the only honest count of
users; GitHub traffic says who looks and from where; directory counters are impressions, not users.
Read-only everywhere except `analytics request`, which creates the standing report request Apple
needs before any analytics exist.

Sales report caveats (Apple's): a day lands around 05:00 Pacific for the previous Pacific day, so
the window ends at Pacific yesterday and a day Apple has no report for prints "n/a" (never a zero:
it is either not published yet, or every day is n/a and the vendor number or the key's role is
wrong). The report is vendor-wide, so rows are filtered to this app's Apple Identifier (the first
run counted Lexy's updates). Product types: 1/1T/1F/F1 first downloads, 3/3F/3T/F3 redownloads
(counted with downloads: that user has the app), 7/7T/7F/F7 updates; anything else is "other".
Units are opted-in, not sampled, so they are a floor.

Signed: Kev + claude-fable-5.1, 2026-10-20, Confidence 0.8, Prior: Unknown. The pure half is
pinned in test_metrics.py; the sales endpoint and product-type table are from Apple's docs, the
analytics flow (request → reports → instances → segments) from the 2024 Analytics Reports API.
`store` and `repo` ran live on 2026-10-20 (74 M1K3 downloads in 14 days; 109 DMGs); `analytics`
has not: its first live run is the review owed.
Review: Kev + claude-fable-5.1, 2026-10-20 (pre-push fold) — `gh --paginate` output is decoded
document by document, not by newline guesswork; product types are an explicit table; a 404 day is
None/"n/a", not zero; the snapshot keeps one line per date; segment files carry an index.
Review: Kev + claude-fable-5.1, 2026-10-21 — first live `analytics` run, the owed review: the
request → reports → instances → segments flow works as documented. Apple's catalogue names end
"Standard" / "Detailed" (there is no plain "App Downloads"), so the default is now
`App Downloads Standard`; on day one that report and Discovery had no instances yet while
"App Store Installation and Deletion Standard" and "App Sessions Standard" each had one, two days
deep. Review nits from #653 folded: Pacific date for the repo snapshot, instance id in segment
filenames, a tolerant date parse, a corrupt snapshot line is kept not fatal, segment transport
errors, a segment with no url yet and a truncated gzip all say FAILED. Confidence 0.85: everything has now run live; the ad-geo pattern (UZ/KZ/MA/DZ
installs with ~30 s sessions and next-day deletes) is a reading, not a measurement of intent.
Review: Kev + claude-fable-5.1, 2026-10-21 (pre-push fold) — the FAILED wrap also covers a segment
with no url yet and a truncated gzip body, so no segment path ends in a raw traceback.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import gzip
import io
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import asc

REPO = "Round-Tower/M1K3"
SNAPSHOT = Path(__file__).resolve().parents[3] / "marketing" / "metrics" / "repo.jsonl"
PACIFIC = ZoneInfo("America/Los_Angeles")
GZIP_MAGIC = b"\x1f\x8b"
DEFAULT_REPORT = "App Downloads Standard"  # the catalogue names end Standard / Detailed

# Apple's Product Type Identifiers (Sales and Trends guide). Explicit, so a new code is "other"
# until someone reads what it means, never a download by accident.
DOWNLOAD_TYPES = frozenset({"1", "1F", "1T", "F1", "3", "3F", "3T", "F3"})
UPDATE_TYPES = frozenset({"7", "7F", "7T", "F7"})


# ── sales reports (pure) ─────────────────────────────────────────────────────

def parse_sales(gz: bytes | None) -> list[dict[str, str]]:
    """Rows of the tab-separated report Apple gzips; b'' or None (a 404 day) is no rows."""
    if not gz:
        return []
    if gz[:2] != GZIP_MAGIC:
        raise SystemExit(f"sales report is not gzip (Apple answered with): {gz[:200]!r}")
    text = gzip.decompress(gz).decode("utf-8-sig")
    rows = list(csv.DictReader(io.StringIO(text), delimiter="\t"))
    if rows and "Apple Identifier" not in rows[0]:
        raise SystemExit(f"sales report has no 'Apple Identifier' column; columns: {list(rows[0])[:12]}")
    return rows


def product_class(ptype: str | None) -> str:
    """download | update | other, from Apple's Product Type Identifier."""
    code = (ptype or "").strip().upper()
    if code in DOWNLOAD_TYPES:
        return "download"
    if code in UPDATE_TYPES:
        return "update"
    return "other"


def summarise(rows: list[dict[str, str]], app_id: str = asc.APP_ID) -> dict[str, Any]:
    """Units by class, platform and country for ONE app: the report is vendor-wide, so every
    Round Tower app shares it and rows for the others are dropped here."""
    day: dict[str, Any] = {"download": 0, "update": 0, "other": 0, "by_platform": {}, "by_country": {}}
    for r in rows:
        if (r.get("Apple Identifier") or "").strip() != app_id:
            continue
        units = int(float(r.get("Units") or 0))
        cls = product_class(r.get("Product Type Identifier"))
        day[cls] += units
        if cls == "other":
            continue
        plat = day["by_platform"].setdefault(r.get("Device") or "?", {"download": 0, "update": 0})
        plat[cls] += units
        if cls == "download":
            cc = r.get("Country Code") or "?"
            day["by_country"][cc] = day["by_country"].get(cc, 0) + units
    return day


def report_days(today: dt.date, days: int) -> list[dt.date]:
    """The last `days` full days ending yesterday; `today` is Apple's (Pacific) today."""
    return [today - dt.timedelta(days=i) for i in range(days, 0, -1)]


def pacific_today(now: dt.datetime | None = None) -> dt.date:
    return (now or dt.datetime.now(dt.timezone.utc)).astimezone(PACIFIC).date()


# ── analytics (pure) ─────────────────────────────────────────────────────────

def pick_report(reports: list[dict[str, Any]], name: str) -> dict[str, Any] | None:
    want = name.strip().lower()
    for r in reports:
        if (r.get("attributes") or {}).get("name", "").strip().lower() == want:
            return r
    return None


def segment_filename(report_name: str, date: str, index: int, instance: str = "") -> str:
    """Report, processing date, instance id (two instances can share a date) and segment index."""
    safe = re.sub(r"[^A-Za-z0-9.-]+", "-", report_name).strip("-")
    inst = re.sub(r"[^A-Za-z0-9.-]+", "-", instance).strip("-")
    return f"{safe}-{date or 'undated'}-{inst + '-' if inst else ''}{index:02d}.csv"


def instance_date(processing_date: str) -> dt.date | None:
    """`processingDate` is a plain date today; a time component, if Apple ever adds one, is dropped."""
    try:
        return dt.date.fromisoformat((processing_date or "")[:10])
    except ValueError:
        return None


# ── repo (pure) ──────────────────────────────────────────────────────────────

def parse_paginated(text: str) -> Any:
    """`gh api --paginate` concatenates one JSON document per page, with or without a newline
    between them. A single object comes back as is; list pages are flattened into one list."""
    decoder = json.JSONDecoder()
    docs: list[Any] = []
    i, n = 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        doc, i = decoder.raw_decode(text, i)
        docs.append(doc)
    if not docs:
        raise SystemExit("gh api returned nothing")
    if len(docs) == 1 and not isinstance(docs[0], list):
        return docs[0]
    return [item for d in docs for item in (d if isinstance(d, list) else [d])]


def dmg_downloads(releases: list[dict[str, Any]]) -> tuple[int, dict[str, int]]:
    per: dict[str, int] = {}
    for rel in releases:
        if rel.get("draft"):
            continue
        n = sum(a.get("download_count") or 0 for a in rel.get("assets", []) if (a.get("name") or "").endswith(".dmg"))
        if n:
            per[rel.get("tag_name", "?")] = n
    return sum(per.values()), per


def clone_note(clones: int, views: int) -> str:
    if views and clones > 5 * views:
        return f"clones are mostly CI and bots ({clones:,} clones vs {views:,} views)"
    return ""


def snapshot_line(date: dt.date, fields: dict[str, Any]) -> str:
    return json.dumps({"date": date.isoformat(), **fields}) + "\n"


def merge_snapshot(existing: str, line: str) -> str:
    """One line per date: a rerun on the same day replaces that day's line."""
    date = json.loads(line)["date"]
    kept = []
    for ln in existing.splitlines():
        if not ln.strip():
            continue
        try:
            if json.loads(ln).get("date") == date:
                continue
        except (ValueError, AttributeError):
            pass  # a hand-edited line is kept as found, never a reason to drop today's snapshot
        kept.append(ln)
    return "".join(ln + "\n" for ln in kept) + line


# ── live: sales ──────────────────────────────────────────────────────────────

def fetch_sales_day(vendor: str, day: dt.date) -> bytes | None:
    """The gzipped daily SALES/SUMMARY report, or None when Apple has no report for that day."""
    import requests  # lazy, like asc.call

    params = {"filter[frequency]": "DAILY", "filter[reportDate]": day.isoformat(), "filter[reportSubType]": "SUMMARY",
              "filter[reportType]": "SALES", "filter[vendorNumber]": vendor}
    try:
        r = requests.get(asc.BASE + "/v1/salesReports", params=params, timeout=120,
                         headers={"Authorization": f"Bearer {asc.token()}", "Accept": "application/a-gzip"})
    except requests.RequestException as exc:
        asc.bail(f"salesReports {day}", {"_error": "transport", "_body": str(exc)[:600]})
    if r.status_code == 404:
        return None
    if r.status_code >= 400:
        asc.bail(f"salesReports {day}", {"_error": r.status_code, "_body": r.text[:600]})
    return r.content


def cmd_store(args: argparse.Namespace) -> int:
    vendor = args.vendor or os.environ.get("ASC_VENDOR_NUMBER", "")
    if not vendor:
        raise SystemExit("ASC_VENDOR_NUMBER is unset (App Store Connect ▸ Payments and Financial Reports shows it)")
    totals = {"download": 0, "update": 0}
    countries: dict[str, int] = {}
    platforms: dict[str, dict[str, int]] = {}
    missing = 0
    days = report_days(pacific_today(), args.days)
    print(f"{'day':<12}{'downloads':>10}{'updates':>9}  platforms")
    for day in days:
        raw = fetch_sales_day(vendor, day)
        if raw is None:
            missing += 1
            print(f"{day.isoformat():<12}{'n/a':>10}{'n/a':>9}  (no report published for this day)")
            continue
        s = summarise(parse_sales(raw))
        totals["download"] += s["download"]
        totals["update"] += s["update"]
        for cc, n in s["by_country"].items():
            countries[cc] = countries.get(cc, 0) + n
        for plat, v in s["by_platform"].items():
            p = platforms.setdefault(plat, {"download": 0, "update": 0})
            p["download"] += v["download"]
            p["update"] += v["update"]
        plats = ", ".join(f"{k} {v['download']}/{v['update']}" for k, v in sorted(s["by_platform"].items()))
        print(f"{day.isoformat():<12}{s['download']:>10}{s['update']:>9}  {plats}")
    counted = len(days) - missing
    print(f"\n{counted} of {len(days)} days: {totals['download']} downloads, {totals['update']} updates")
    if platforms:
        print("by platform (downloads/updates): " + ", ".join(
            f"{k} {v['download']}/{v['update']}" for k, v in sorted(platforms.items())))
    if countries:
        top = sorted(countries.items(), key=lambda kv: -kv[1])[:10]
        print("downloads by country: " + ", ".join(f"{cc} {n}" for cc, n in top))
    if days and missing == len(days):
        print("WARNING: no report on any day — check ASC_VENDOR_NUMBER and that the key's role has Sales access")
        return 2
    return 0


# ── live: analytics ──────────────────────────────────────────────────────────

def analytics_requests() -> list[dict[str, Any]]:
    return list(asc.paginate(f"/v1/apps/{asc.APP_ID}/analyticsReportRequests"))


def cmd_analytics(args: argparse.Namespace) -> int:
    try:
        return _analytics(args)
    except RuntimeError as exc:  # asc.paginate's error page
        raise SystemExit(f"FAILED: {exc}") from None


def _analytics(args: argparse.Namespace) -> int:
    if args.action == "request":
        existing = [r for r in analytics_requests() if r["attributes"].get("accessType") == "ONGOING"]
        if existing:
            print(f"already requested: {existing[0]['id']} (ONGOING)")
            return 0
        resp = asc.call("POST", "/v1/analyticsReportRequests", json={"data": {
            "type": "analyticsReportRequests", "attributes": {"accessType": "ONGOING"},
            "relationships": {"app": {"data": {"type": "apps", "id": asc.APP_ID}}}}})
        if "_error" in resp:
            asc.bail("analyticsReportRequests", resp)
        print(f"requested: {resp['data']['id']} — reports appear within a day or two; then `analytics list`")
        return 0
    reqs = analytics_requests()
    if not reqs:
        raise SystemExit("no analytics report request yet: run `metrics.py analytics request` first")
    reports: list[dict[str, Any]] = []
    for req in reqs:
        reports += list(asc.paginate(f"/v1/analyticsReportRequests/{req['id']}/reports"))
    if args.action == "list":
        for r in sorted(reports, key=lambda r: (r["attributes"].get("category", ""), r["attributes"].get("name", ""))):
            print(f"{r['attributes'].get('category', ''):<28}{r['attributes'].get('name', '')}")
        return 0
    report = pick_report(reports, args.name)
    if report is None:
        raise SystemExit(f"no report named {args.name!r}; `analytics list` shows them")
    out = Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    since = pacific_today() - dt.timedelta(days=args.days)
    import requests  # lazy

    n = 0
    for inst in asc.paginate(f"/v1/analyticsReports/{report['id']}/instances?filter[granularity]=DAILY"):
        day = instance_date(inst["attributes"].get("processingDate") or "")
        if day is None or day < since:
            continue
        for i, seg in enumerate(asc.paginate(f"/v1/analyticsReportInstances/{inst['id']}/segments")):
            try:
                r = requests.get(seg["attributes"]["url"], timeout=120)  # pre-signed: no bearer token
                r.raise_for_status()
                raw = r.content
                data = gzip.decompress(raw) if raw[:2] == GZIP_MAGIC else raw
            except (requests.RequestException, KeyError, OSError, EOFError) as exc:  # no url yet, truncated gzip
                raise SystemExit(f"FAILED: segment {i} of {report['attributes']['name']} {day}: {exc!r}") from None
            (out / segment_filename(report["attributes"]["name"], day.isoformat(), i, inst["id"])).write_bytes(data)
            n += 1
    print(f"{n} segment(s) written under {out}")
    return 0


# ── live: repo ───────────────────────────────────────────────────────────────

def gh(path: str) -> Any:
    try:
        proc = subprocess.run(["gh", "api", path, "--paginate"], capture_output=True, text=True, check=True)
    except FileNotFoundError:
        raise SystemExit("gh is not installed (brew install gh)") from None
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"gh api {path} failed: {(exc.stderr or exc.stdout).strip()[:400]}") from None
    return parse_paginated(proc.stdout)


def cmd_repo(args: argparse.Namespace) -> int:
    repo = gh(f"repos/{REPO}")
    views = gh(f"repos/{REPO}/traffic/views")
    clones = gh(f"repos/{REPO}/traffic/clones")
    referrers = gh(f"repos/{REPO}/traffic/popular/referrers")
    total_dmg, per_release = dmg_downloads(gh(f"repos/{REPO}/releases"))
    fields = {"stars": repo["stargazers_count"], "forks": repo["forks_count"], "watchers": repo["subscribers_count"],
              "dmg_downloads": total_dmg, "views": views["count"], "views_uniques": views["uniques"],
              "clones": clones["count"], "clones_uniques": clones["uniques"],
              "referrers": {r["referrer"]: r["count"] for r in referrers[:10]}}
    print(f"stars {fields['stars']} · forks {fields['forks']} · watchers {fields['watchers']}")
    print(f"DMG downloads {total_dmg} across {len(per_release)} releases"
          + (f" (newest: {', '.join(f'{t} {n}' for t, n in list(per_release.items())[:3])})" if per_release else ""))
    print(f"14-day views {fields['views']} ({fields['views_uniques']} unique) · clones {fields['clones']} "
          f"({fields['clones_uniques']} unique)")
    note = clone_note(fields["clones"], fields["views"])
    if note:
        print("  " + note)
    if fields["referrers"]:
        print("referrers: " + ", ".join(f"{k} {v}" for k, v in fields["referrers"].items()))
    if not args.no_snapshot:
        SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
        existing = SNAPSHOT.read_text() if SNAPSHOT.exists() else ""
        SNAPSHOT.write_text(merge_snapshot(existing, snapshot_line(pacific_today(), fields)))
        print(f"snapshot for today written to {SNAPSHOT}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("store")
    s.add_argument("--days", type=int, default=14)
    s.add_argument("--vendor", default="")
    s.set_defaults(fn=cmd_store)
    a = sub.add_parser("analytics")
    a.add_argument("action", choices=["request", "list", "fetch"])
    a.add_argument("--name", default=DEFAULT_REPORT)
    a.add_argument("--days", type=int, default=14)
    a.add_argument("--out", default=str(SNAPSHOT.parent / "analytics"))
    a.set_defaults(fn=cmd_analytics)
    r = sub.add_parser("repo")
    r.add_argument("--no-snapshot", action="store_true")
    r.set_defaults(fn=cmd_repo)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
