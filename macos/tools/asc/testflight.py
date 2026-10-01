"""TestFlight's beta app description — one text for every platform's testers.

The description lives on the app (betaAppLocalizations), not on a build or a
platform, so the universal record shows iPhone, iPad and Mac testers the
same words. Until 2026-10-01 those words said "lives entirely on your Mac …
Requirements: Apple Silicon Mac" to everyone. The tracked copy is
`TestFlight/beta_description.en-US.txt`; per-build "What to Test" notes are
Xcode Cloud's job (`ci_scripts/select_what_to_test.sh`).

  python3 testflight.py show
  python3 testflight.py set              # dry run: was / now
  python3 testflight.py set --confirm    # PATCH en-US (classifier-blocked in auto mode — stage for Kev)

Signed: Kev + claude-opus-5.5, 2026-10-01, Confidence 0.8 (the PATCH shape is
  the ASC API's betaAppLocalizations; the first live write is Kev's).
Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    s = sub.add_parser("set")
    s.add_argument("--confirm", action="store_true")
    args = ap.parse_args()
    return show() if args.cmd == "show" else set_description(args.confirm)


if __name__ == "__main__":
    sys.exit(main())
