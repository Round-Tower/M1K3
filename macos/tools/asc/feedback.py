#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""TestFlight feedback and crash reports for one build, read-only (#748).

  ./feedback.py list --build N            # one line per item: kind, platform, device, OS, date
  ./feedback.py list --build N --text     # also print each comment (your terminal, your call)
  ./feedback.py list --build N --logs     # also fetch each crash's log into the saved record

Testers' screenshot feedback and crash submissions sat in App Store Connect and nothing here
read them. This lists them for Mac + iOS build N, newest first, and saves the full record
(comments, tester emails, crash logs with --logs) to ~/.cache/m1k3-release/feedback/, mode 0600.

Privacy, because this repo is public: feedback holds tester emails and free text. The terminal
never shows an email and shows a comment only with --text. The record is written outside the
checkout, so it cannot be committed. Paste none of it into an issue or a PR; write the finding
in your own words. Screenshot links are signed and expire; they are saved, never printed.

Read-only: GETs only (the two submission lists per build and, with --logs, one log per crash). The
endpoint and attribute names are Apple's, read from the API reference on 2026-11-11
(`/v1/apps/{id}/betaFeedbackScreenshotSubmissions`, `…/betaFeedbackCrashSubmissions`,
`/v1/betaFeedbackCrashSubmissions/{id}/crashLog` → `logText`).

Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.7, Prior: none (new file).
Format: MurphySig v0.4 (https://murphysig.dev/spec).
Open: the screenshot image entries are saved as Apple sends them; no build has had screenshot
  feedback yet, so their fields are unread.
  Crashes on the live store build are not here: those stay in Xcode's Organizer.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from asc import APP_ID, call, paginate

REPO = Path(__file__).resolve().parents[3]
OUT_DIR = Path("~/.cache/m1k3-release/feedback").expanduser()
KINDS = {"betaFeedbackScreenshotSubmissions": "screenshot", "betaFeedbackCrashSubmissions": "crash"}

# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def rows(found: list[tuple[str, dict[str, Any]]], builds: dict[str, str]) -> list[dict[str, Any]]:
    """One flat row per submission, newest first. `found` pairs each item with the build id it was asked
    for (the list reply carries no build relationship unless included: build 544's crash read as "no
    feedback" on the first live run); `builds` maps build id → platform."""
    out, seen = [], set()
    for build, item in found:
        # One crash came back under BOTH of build 544's ids (Mac and iOS), live 2026-11-11: keep one.
        if build not in builds or item["id"] in seen:
            continue
        seen.add(item["id"])
        a = item.get("attributes") or {}
        out.append({
            "id": item["id"], "kind": KINDS.get(item.get("type", ""), "other"), "at": a.get("createdDate") or "",
            "platform": a.get("appPlatform") or builds[build], "device": a.get("deviceModel") or "?",
            "os": a.get("osVersion") or "?", "comment": a.get("comment") or "", "email": a.get("email") or "",
            "screenshots": len(a.get("screenshots") or []),
            # Signed, expiring links: saved in the record, never printed.
            "screenshot_images": a.get("screenshots") or [],
        })
    return sorted(out, key=lambda r: r["at"], reverse=True)


def line(row: dict[str, Any], show_text: bool) -> str:
    """The terminal line: never an email; the comment's words only when asked for."""
    head = f"{row['at'][:16].replace('T', ' ')}  {row['kind']:<10} {row['platform']:<7} {row['device']} · {row['os']}"
    # A tester's words reach a terminal: printable characters only (no escape sequences), on one line.
    comment = " ".join("".join(ch if ch.isprintable() else " " for ch in row["comment"]).split())
    if not comment:
        return head
    return f"{head}\n    {comment}" if show_text else f"{head}  (comment: {len(comment)} chars)"


def summary(found: list[dict[str, Any]]) -> str:
    if not found:
        return "no feedback"
    counts = Counter((r["kind"], r["platform"]) for r in found)
    parts = [f"{n} {kind} on {platform}" for (kind, platform), n in sorted(counts.items())]
    return f"{len(found)} item(s): " + ", ".join(parts)


def save(out_dir: Path, build: str, found: list[dict[str, Any]], logs: dict[str, str]) -> Path:
    """The full record, for the person at this Mac only (0600), outside the checkout."""
    out_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = out_dir / f"build-{build}.json"
    # A run without --logs keeps the logs an earlier run fetched.
    try:
        kept = {i["id"]: i["crash_log"] for i in json.loads(path.read_text()).get("items", []) if "crash_log" in i}
    except (OSError, ValueError, KeyError, TypeError):
        kept = {}
    logs = {**kept, **logs}
    items = [{**row, **({"crash_log": logs[row["id"]]} if row["id"] in logs else {})} for row in found]
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    path.write_text(json.dumps({"build": build, "items": items}, indent=2))
    return path


# --------------------------------------------------------------------------- #
# Effectful (GET only)
# --------------------------------------------------------------------------- #


def build_ids(build: str) -> dict[str, str]:
    """Build id → platform for build number N on the one record (Mac + iOS)."""
    resp = call("GET", "/v1/builds", params={"filter[app]": APP_ID, "filter[version]": build,
                                             "include": "preReleaseVersion", "limit": 10})
    if "_error" in resp:
        raise SystemExit(f"reading build {build} failed: {resp['_error']}")
    platform = {i["id"]: i["attributes"]["platform"] for i in resp.get("included", [])
                if i["type"] == "preReleaseVersions"}
    def platform_of(build: dict[str, Any]) -> str:
        version = ((build.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
        return platform.get(version.get("id"), "?")

    return {b["id"]: platform_of(b) for b in resp["data"]}


def submissions(kind: str, ids: list[str]) -> list[tuple[str, dict[str, Any]]]:
    # One build per request: two ids in the filter is "Too many filters for this type" (400, live 2026-11-11).
    return [(build, item) for build in ids
            for item in paginate(f"/v1/apps/{APP_ID}/{kind}?filter[build]={build}&sort=-createdDate&limit=200")]


def crash_log(submission_id: str) -> str:
    resp = call("GET", f"/v1/betaFeedbackCrashSubmissions/{submission_id}/crashLog")
    if "_error" in resp:
        return f"(log not read: {resp['_error']})"
    return ((resp.get("data") or {}).get("attributes") or {}).get("logText") or ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list", help="feedback and crashes for one build")
    ls.add_argument("--build", required=True)
    ls.add_argument("--text", action="store_true", help="print each comment in the terminal")
    ls.add_argument("--logs", action="store_true", help="fetch each crash log into the saved record")
    args = ap.parse_args()
    if not args.build.isascii() or not args.build.isdigit():
        print("--build is a build number, like 546")
        return 2
    builds = build_ids(args.build)
    if not builds:
        print(f"no build {args.build} on the record")
        return 1
    ids = sorted(builds)
    try:
        found = rows(submissions("betaFeedbackScreenshotSubmissions", ids)
                     + submissions("betaFeedbackCrashSubmissions", ids), builds)
    except RuntimeError as exc:
        # The status only: an error body is not ours to print.
        print(f"reading feedback failed: {str(exc).split(':')[0]}")
        return 1
    print(f"build {args.build} ({', '.join(sorted(builds.values()))}): {summary(found)}")
    for row in found:
        print(line(row, show_text=args.text))
    logs = {r["id"]: crash_log(r["id"]) for r in found if r["kind"] == "crash"} if args.logs else {}
    if found:
        print(f"full record (emails, comments{', crash logs' if logs else ''}): {save(OUT_DIR, args.build, found, logs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
