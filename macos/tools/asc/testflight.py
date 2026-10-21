#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""TestFlight's beta app description — one text for every platform's testers.

The description lives on the app (betaAppLocalizations), not on a build or a
platform, so the universal record shows iPhone, iPad and Mac testers the
same words. Until 2026-10-01 those words said "lives entirely on your Mac …
Requirements: Apple Silicon Mac" to everyone. The tracked copy is
`TestFlight/beta_description.en-US.txt`. Per-build "What to Test" notes come
from `TestFlight/notes/<platform>.<locale>.txt`: Xcode Cloud copies them in itself
(`ci_scripts/select_what_to_test.sh`); a local upload arrives with none, so
`notes --build N` writes them and reads them back.

  ./testflight.py show
  ./testflight.py set                       # dry run: was / now
  ./testflight.py set --confirm             # PATCH en-US (classifier-blocked in auto mode — stage for Kev)
  ./testflight.py notes --build N           # dry run: each platform's build N, locale, chars
  ./testflight.py notes --build N --confirm # write What to Test on Mac + iOS build N, read back

Signed: Kev + claude-opus-5.5, 2026-10-01, Confidence 0.8 (the PATCH shape is
  the ASC API's betaAppLocalizations; the first live write is Kev's).
Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
Review: Kev + claude-opus-5.5, 2026-10-21 — `notes --build N` writes each platform's What to Test from
  TestFlight/notes/ and reads it back (a local upload arrives without it: 537–539 were scratch
  scripts); a uv header so it runs as ./testflight.py. Confidence 0.8: the dry run read 539's live
  notes; the POST branch (a build with no localization yet) first runs on the next local build.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, bail, call

DESCRIPTION_CAP = 4000
DESCRIPTION_FILE = Path(__file__).resolve().parents[2] / "TestFlight" / "beta_description.en-US.txt"
# Every platform the record ships a beta on must be named, or some testers
# are told the app is for a device they are not holding.
PLATFORM_WORDS = ("iPhone", "iPad", "Mac")
NOTES_DIR = DESCRIPTION_FILE.parent / "notes"
NOTES_CAP = 4000
# ASC platform → the file prefix select_what_to_test.sh reads (CI_PRODUCT_PLATFORM, lowercased).
NOTES_PLATFORMS = {"MAC_OS": "macos", "IOS": "ios"}


def read_description(path: Path = DESCRIPTION_FILE) -> str:
    return path.read_text(encoding="utf-8").removesuffix("\n")


def problems(text: str) -> list[str]:
    if not text.strip():
        return ["beta description is empty"]
    found = []
    if missing := [w for w in PLATFORM_WORDS if w not in text]:
        found.append(f"beta description never names {', '.join(missing)} — every platform's testers read it")
    if len(text) > DESCRIPTION_CAP:
        found.append(f"beta description over the {DESCRIPTION_CAP}-char cap ({len(text)})")
    return found


def patch_payload(localization_id: str, text: str) -> dict[str, Any]:
    return {"data": {"type": "betaAppLocalizations", "id": localization_id, "attributes": {"description": text}}}


def en_us_localization() -> dict[str, Any]:
    resp = call("GET", f"/v1/apps/{APP_ID}/betaAppLocalizations")
    if "_error" in resp:
        bail("list beta app localizations", resp)
    loc = next((l for l in resp["data"] if l["attributes"]["locale"] == "en-US"), None)
    if loc is None:
        raise SystemExit("no en-US beta app localization")
    return loc


def show() -> int:
    loc = en_us_localization()
    text = loc["attributes"].get("description") or ""
    print(f"en-US {len(text)}/{DESCRIPTION_CAP}\n{text}")
    for p in problems(text):
        print(f"PROBLEM  {p}")
    return 0


def set_description(confirm: bool) -> int:
    text = read_description()
    if found := problems(text):
        raise SystemExit("refusing: " + "; ".join(found))
    loc = en_us_localization()
    print(f"was:\n{loc['attributes'].get('description') or ''}\n\nnow:\n{text}")
    if not confirm:
        print("(dry run — pass --confirm to write)")
        return 0
    resp = call("PATCH", f"/v1/betaAppLocalizations/{loc['id']}", json=patch_payload(loc["id"], text))
    if "_error" in resp:
        bail("patch beta app description", resp)
    print("written")
    return 0


def build_notes(platform: str, notes_dir: Path = NOTES_DIR) -> dict[str, str]:
    prefix = NOTES_PLATFORMS[platform]
    return {f.stem.removeprefix(f"{prefix}."): f.read_text(encoding="utf-8").strip()
            for f in sorted(notes_dir.glob(f"{prefix}.*.txt"))}


def notes_problems(text: str) -> list[str]:
    if not text.strip():
        return ["What to Test is empty"]
    if len(text) > NOTES_CAP:
        return [f"What to Test over the {NOTES_CAP}-char cap ({len(text)})"]
    return []


def notes_patch_payload(localization_id: str, text: str) -> dict[str, Any]:
    return {"data": {"type": "betaBuildLocalizations", "id": localization_id, "attributes": {"whatsNew": text}}}


def notes_post_payload(build_id: str, locale: str, text: str) -> dict[str, Any]:
    return {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
                     "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}


def _build_localizations(build_id: str) -> dict[str, dict[str, Any]]:
    resp = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")
    if "_error" in resp:
        bail("list beta build localizations", resp)
    return {l["attributes"]["locale"]: l for l in resp["data"]}


def set_notes(build: str, confirm: bool) -> int:
    plan = {p: build_notes(p) for p in NOTES_PLATFORMS}
    for platform, notes in plan.items():
        if not notes:
            raise SystemExit(f"refusing: no {NOTES_PLATFORMS[platform]}.*.txt in {NOTES_DIR}")
        if found := [f"{platform} {loc}: {p}" for loc, t in notes.items() for p in notes_problems(t)]:
            raise SystemExit("refusing: " + "; ".join(found))
    worst = 0
    for platform, notes in plan.items():
        resp = call("GET", "/v1/builds", params={
            "filter[app]": APP_ID, "filter[version]": build,
            "filter[preReleaseVersion.platform]": platform, "limit": 1})
        if "_error" in resp:
            bail(f"find {platform} build {build}", resp)
        if not resp["data"]:
            print(f"{platform} build {build}: not found (still processing?)")
            worst = 1
            continue
        build_id = resp["data"][0]["id"]
        have = _build_localizations(build_id)
        for locale, text in notes.items():
            was = (have.get(locale, {}).get("attributes") or {}).get("whatsNew") or ""
            print(f"{platform} {build} {locale}: {len(was)} → {len(text)} chars")
            if not confirm or was == text:
                continue
            if locale in have:
                resp = call("PATCH", f"/v1/betaBuildLocalizations/{have[locale]['id']}",
                            json=notes_patch_payload(have[locale]["id"], text))
            else:
                resp = call("POST", "/v1/betaBuildLocalizations", json=notes_post_payload(build_id, locale, text))
            if "_error" in resp:
                bail(f"write {platform} {locale} What to Test", resp)
        if confirm:
            back = _build_localizations(build_id)
            for locale, text in notes.items():
                got = (back.get(locale, {}).get("attributes") or {}).get("whatsNew") or ""
                ok = got == text
                worst = worst or (0 if ok else 1)
                print(f"   read back {locale}: {'matches' if ok else 'MISMATCH'} ({len(got)} chars)")
    if not confirm:
        print("(dry run — pass --confirm to write)")
    return worst


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    s = sub.add_parser("set")
    s.add_argument("--confirm", action="store_true")
    n = sub.add_parser("notes", help="per-build What to Test from TestFlight/notes/, Mac + iOS")
    n.add_argument("--build", required=True)
    n.add_argument("--confirm", action="store_true")
    args = ap.parse_args()
    if args.cmd == "notes":
        return set_notes(args.build, args.confirm)
    return show() if args.cmd == "show" else set_description(args.confirm)


if __name__ == "__main__":
    sys.exit(main())
