#!/usr/bin/env python3
"""App Review Information notes — show / set on every platform's newest version.

Why: on 2026-09-16 App Review's automated analysis stopped the Mac 1.0.0 submission —
"includes the com.apple.security.network.server entitlement but does not appear to have
matching functionality". The entitlement IS used: the loopback MCP server (127.0.0.1:4242)
and Brain at Home (the LAN brain service for QR-paired devices) both LISTEN. But the notes
described network use "in full" as outbound only and named neither listener, so the
reviewer's map contradicted the binary. The notes live in `fastlane/review_notes.txt`;
`problems()` keeps them honest about both listeners, and precheck.py runs the same check
before every submit.

  show                                   print each platform's notes + problems
  set --file NOTES [--platform P] [--confirm]
                                         PATCH the notes (a dry-run without --confirm)

Notes are LOCKED while a version is WAITING_FOR_REVIEW / IN_REVIEW; edit after a rejection
(the version reads REJECTED, then editable) or before submitting.

Signed: Kev + claude-fable-5.1, 2026-09-16, Confidence 0.85 (the pure checks are
pytest-pinned; the PATCH shape mirrors keywords.py/promo.py; `set --confirm` is
verify-by-run against the live record — ASC writes are Kev's to run). Prior: Unknown.
Review: Kev + claude-fable-5.1, 2026-09-16 (later) — a per-platform PATCH failure prints and
continues instead of bail() (which exits, so the "continue" never ran — #361's local pass).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from asc import call

NOTES_CAP = 4000

# The two inbound listeners the server entitlement exists for, by the names the
# reviewer sees in Settings ▸ Privacy. A notes text that names neither is the
# 2026-09-16 rejection waiting to happen again.
LISTENERS: tuple[tuple[str, str], ...] = (
    ("MCP server", "com.apple.security.network.server"),
    ("Brain at Home", "com.apple.security.network.server"),
)


def problems(notes: str) -> list[str]:
    """Everything wrong with a notes text, in order: emptiness, the cap, then each
    inbound listener it fails to name (case-insensitive)."""
    if not notes.strip():
        return ["notes are empty"]
    if len(notes) > NOTES_CAP:
        return [f"notes over the {NOTES_CAP}-char cap ({len(notes)})"]
    lowered = notes.lower()
    return [
        f"notes never mention the {name} ({key})" if name == "MCP server" else f"notes never mention {name} ({key})"
        for name, key in LISTENERS
        if name.lower() not in lowered
    ]


def patch_payload(detail_id: str, notes: str) -> dict[str, Any]:
    return {"data": {"type": "appStoreReviewDetails", "id": detail_id, "attributes": {"notes": notes}}}


def review_detail(version_id: str) -> dict[str, Any]:
    """The raw response — callers must split a 404 (never set) from a read failure
    (`_error` anything else); collapsing both to "no notes" once read an expired key as
    "notes are empty" (local review on the 2026-09-16 PR)."""
    return call(
        "GET",
        f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail"
        "?fields[appStoreReviewDetails]=notes,contactEmail,demoAccountRequired",
    )


def notes_in(resp: dict[str, Any]) -> str:
    return resp.get("data", {}).get("attributes", {}).get("notes") or ""


def versions(platforms: tuple[str, ...]) -> list[tuple[str, dict[str, Any]]]:
    from precheck import latest_version  # lazy: precheck imports this module's checks

    out = []
    for platform in platforms:
        version = latest_version(platform)
        if version is not None:
            out.append((platform, version))
    return out


def run_show(platforms: tuple[str, ...]) -> int:
    for platform, version in versions(platforms):
        a = version["attributes"]
        state = a.get("appVersionState") or a.get("appStoreState")
        resp = review_detail(version["id"])
        if "_error" in resp:
            print(f"== {platform} {a['versionString']} {state} · review detail read failed: {resp['_error']}")
            continue
        notes = notes_in(resp)
        print(f"== {platform} {a['versionString']} {state} · notes {len(notes)}/{NOTES_CAP} chars")
        for problem in problems(notes) or ["ok"]:
            print(f"   {problem}")
        print(notes)
        print()
    return 0


def run_set(platforms: tuple[str, ...], path: Path, confirm: bool) -> int:
    notes = path.read_text()
    found = problems(notes)
    if found:
        print("refusing to write notes with problems:", *found, sep="\n   ")
        return 1
    failed = False
    for platform, version in versions(platforms):
        resp = review_detail(version["id"])
        if "_error" in resp:
            print(f"{platform}: review detail read failed ({resp['_error']}) on version {version['id']}")
            failed = True
            continue
        detail = resp["data"]
        payload = patch_payload(detail["id"], notes)
        if not confirm:
            print(f"{platform}: would PATCH /v1/appStoreReviewDetails/{detail['id']} ({len(notes)} chars) — add --confirm")
            continue
        resp = call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", json=payload)
        if "_error" in resp:
            # not bail(): that exits, and the other platforms still deserve their write
            print(f"{platform}: notes PATCH failed: {resp['_error']} {resp.get('_body', '')[:200]}")
            failed = True
            continue
        written = resp.get("data", {}).get("attributes", {}).get("notes") or ""
        print(f"{platform}: notes written ({len(written)} chars) — {'matches the file' if written == notes else 'DIFFERS from the file'}")
        failed |= written != notes
    return 1 if failed else 0


def main() -> int:
    from asc import PLATFORMS

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    show = sub.add_parser("show")
    show.add_argument("--platform", choices=PLATFORMS)
    setp = sub.add_parser("set")
    setp.add_argument("--file", type=Path, required=True)
    setp.add_argument("--platform", choices=PLATFORMS)
    setp.add_argument("--confirm", action="store_true")
    args = ap.parse_args()
    platforms = (args.platform,) if args.platform else PLATFORMS
    if args.cmd == "show":
        return run_show(platforms)
    return run_set(platforms, args.file, args.confirm)


if __name__ == "__main__":
    sys.exit(main())
