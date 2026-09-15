"""Scan (and fix) the listing's keyword, name and subtitle fields across ALL platforms.

Why: launch day rewrote `GPT`/`AGI` out of fourteen localizations on Apple's
side, but only the Mac + iOS versions were in review — the visionOS 1.0.0
record still carried them, and the tracked `metadata_mac/` had them too until
#345. Guideline 2.3.7 (trademarks) is a rejection, not a nit. `check_store_
metadata.py` guards the tracked Mac files; this scans the LIVE fields the
guard cannot see (iOS and visionOS have no tracked metadata).

  python3 keywords.py scan                        # every platform × locale, read-only
  python3 keywords.py apply --platform VISION_OS --locale en-US --keywords 'a,b,c'
                                                  # PATCH one localization (editable versions only;
                                                  #  keywords LOCK while a submission is in review)

Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85 (scan proven live
  against the three records; apply is the same PATCH launch day used).
Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, PLATFORMS, bail, call, paginate  # noqa: E402

# Third-party marks Apple has rejected keyword fields for (2.3.7). Whole-word,
# case-insensitive. "Llama" stays off the list on purpose: the model family is
# what the app runs, and Apple accepts the noun in descriptions; it has never
# been a keyword here anyway.
TRADEMARK_TERMS = ("GPT", "ChatGPT", "AGI", "OpenAI", "Claude", "Gemini", "Copilot", "Siri", "Alexa")
KEYWORD_CAP = 100
NAME_CAP = 30
SUBTITLE_CAP = 30


def trademark_hits(text: str | None) -> list[str]:
    """The trademark terms present in a comma-separated field, as written."""
    if not text:
        return []
    hits = []
    for term in TRADEMARK_TERMS:
        if re.search(rf"(?<![A-Za-z]){re.escape(term)}(?![A-Za-z])", text, flags=re.IGNORECASE):
            hits.append(term)
    return hits


def field_report(platform: str, locale: str, field: str, value: str | None, cap: int) -> list[str]:
    """Human lines for one field: trademark hits and an over-cap length."""
    lines = []
    for hit in trademark_hits(value):
        lines.append(f"TRADEMARK  {platform:9} {locale:8} {field}: '{hit}'")
    if value is not None and len(value) > cap:
        lines.append(f"OVER-CAP   {platform:9} {locale:8} {field}: {len(value)}/{cap}")
    return lines


def latest_version(platform: str) -> dict[str, Any] | None:
    """The newest appStoreVersion for a platform (ASC lists newest first)."""
    versions = list(paginate(f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]={platform}&limit=5"))
    return versions[0] if versions else None


def version_localizations(version_id: str) -> list[dict[str, Any]]:
    return list(paginate(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50"))


def app_info_localizations() -> list[dict[str, Any]]:
    """Name + subtitle live on the app info (shared by every platform)."""
    infos = list(paginate(f"/v1/apps/{APP_ID}/appInfos"))
    out: list[dict[str, Any]] = []
    for info in infos:
        out += paginate(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50")
    return out


def scan() -> int:
    findings: list[str] = []
    for loc in app_info_localizations():
        a = loc["attributes"]
        findings += field_report("APP", a["locale"], "name", a.get("name"), NAME_CAP)
        findings += field_report("APP", a["locale"], "subtitle", a.get("subtitle"), SUBTITLE_CAP)
    for platform in PLATFORMS:
        version = latest_version(platform)
        if version is None:
            print(f"{platform}: no version")
            continue
        state = version["attributes"].get("appVersionState") or version["attributes"].get("appStoreState")
        print(f"{platform}: {version['attributes']['versionString']} {state} ({version['id']})")
        for loc in version_localizations(version["id"]):
            a = loc["attributes"]
            findings += field_report(platform, a["locale"], "keywords", a.get("keywords"), KEYWORD_CAP)
    print("\n".join(findings) if findings else "clean: no trademark terms, nothing over cap")
    return 1 if findings else 0


def apply(platform: str, locale: str, keywords: str) -> int:
    if len(keywords) > KEYWORD_CAP:
        raise SystemExit(f"keywords are {len(keywords)} chars (cap {KEYWORD_CAP})")
    if hits := trademark_hits(keywords):
        raise SystemExit(f"refusing: trademark terms {hits}")
    version = latest_version(platform)
    if version is None:
        raise SystemExit(f"{platform}: no version")
    target = next((l for l in version_localizations(version["id"]) if l["attributes"]["locale"] == locale), None)
    if target is None:
        raise SystemExit(f"{platform} {locale}: no localization on {version['attributes']['versionString']}")
    resp = call("PATCH", f"/v1/appStoreVersionLocalizations/{target['id']}", json={"data": {
        "type": "appStoreVersionLocalizations", "id": target["id"], "attributes": {"keywords": keywords}}})
    if "_error" in resp:
        bail("patch keywords (locked while in review?)", resp)
    print(f"{platform} {locale}: keywords -> {resp['data']['attributes']['keywords']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    p = sub.add_parser("apply")
    p.add_argument("--platform", required=True, choices=PLATFORMS)
    p.add_argument("--locale", required=True)
    p.add_argument("--keywords", required=True)
    args = ap.parse_args()
    return scan() if args.cmd == "scan" else apply(args.platform, args.locale, args.keywords)


if __name__ == "__main__":
    sys.exit(main())
