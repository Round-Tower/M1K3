"""Promotional text — the one listing field that goes live WITHOUT a new build.

170 characters above the description on the product page, editable on a
live version any time. The lever for a featuring window, a press day, or an
event: change the words, no submission. The alternative — `fastlane mac
metadata` — pushes every field of every locale at once, which is the wrong
tool for one sentence.

  python3 promo.py show --platform MAC_OS
  python3 promo.py set --platform MAC_OS --locale en-US --text '...' --confirm

Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85.
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: dyslexia-ai/ios/marketing/tools/push_promo.py (the single-field idea),
  rewritten for one platform + locale at a time.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import PLATFORMS, bail, call  # noqa: E402
from keywords import latest_version, version_localizations  # noqa: E402

PROMO_CAP = 170


def show(platform: str) -> int:
    version = latest_version(platform)
    if version is None:
        raise SystemExit(f"{platform}: no version")
    a = version["attributes"]
    print(f"{platform} {a['versionString']} {a.get('appVersionState') or a.get('appStoreState')}")
    for loc in version_localizations(version["id"]):
        la = loc["attributes"]
        text = la.get("promotionalText") or ""
        print(f"  {la['locale']:8} {len(text):3}/{PROMO_CAP}  {text}")
    return 0


def set_text(platform: str, locale: str, text: str, confirm: bool) -> int:
    if len(text) > PROMO_CAP:
        raise SystemExit(f"promotional text is {len(text)} chars (cap {PROMO_CAP})")
    version = latest_version(platform)
    if version is None:
        raise SystemExit(f"{platform}: no version")
    target = next((l for l in version_localizations(version["id"]) if l["attributes"]["locale"] == locale), None)
    if target is None:
        raise SystemExit(f"{platform} {locale}: no localization")
    print(f"{platform} {version['attributes']['versionString']} {locale}")
    print(f"  was: {target['attributes'].get('promotionalText') or ''}")
    print(f"  now: {text}")
    if not confirm:
        print("(dry run — pass --confirm to write)")
        return 0
    resp = call("PATCH", f"/v1/appStoreVersionLocalizations/{target['id']}", json={"data": {
        "type": "appStoreVersionLocalizations", "id": target["id"], "attributes": {"promotionalText": text}}})
    if "_error" in resp:
        bail("patch promotional text", resp)
    print("written")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show")
    s.add_argument("--platform", required=True, choices=PLATFORMS)
    w = sub.add_parser("set")
    w.add_argument("--platform", required=True, choices=PLATFORMS)
    w.add_argument("--locale", required=True)
    w.add_argument("--text", required=True)
    w.add_argument("--confirm", action="store_true")
    args = ap.parse_args()
    if args.cmd == "show":
        return show(args.platform)
    return set_text(args.platform, args.locale, args.text, args.confirm)


if __name__ == "__main__":
    sys.exit(main())
