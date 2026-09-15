"""The pre-submit checklist — every launch-day hole, read off the API before the click.

On 2026-09-15 a VALID build on a PREPARE_FOR_SUBMISSION version was not
submittable: pricing and availability had never been set, the App Privacy
label had never been published, a PLACEHOLDER iPad screenshot set sat on the
iOS listing, and trademark keywords were in seven locales. None of it was
visible from "build attached". This reads each of those off the API and
prints PASS / FAIL / NOTE lines; read-only, no side effects.

  python3 precheck.py              # all platforms
  python3 precheck.py --platform IOS

Not checkable by API (say so, don't guess): the App Privacy label (the
`appDataUsages` resource is gone — ASC UI only) and the review-notes text.

Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 (the evaluators are
  unit-pinned; the API shapes are the ones launch day drove, proven by a live
  read on the 1.0.0 records — see README).
Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, PLATFORMS, call, paginate  # noqa: E402
from keywords import field_report  # noqa: E402

# What a complete set looks like per platform — one display type each is the
# minimum the store shows; Apple scales the rest.
REQUIRED_DISPLAY_TYPES = {
    "MAC_OS": ("APP_DESKTOP",),
    "IOS": ("APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"),
    "VISION_OS": ("APP_APPLE_VISION_PRO",),
}
SUBMITTABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")
PROMO_CAP = 170


# --------------------------------------------------------------------------- #
# Pure evaluators (unit-pinned)
# --------------------------------------------------------------------------- #


def check_build(version_attrs: dict[str, Any], build: dict[str, Any] | None) -> tuple[str, str]:
    """Is a VALID build attached to this version?"""
    if build is None:
        return "FAIL", "no build attached"
    state = build.get("attributes", {}).get("processingState")
    version = build.get("attributes", {}).get("version", "?")
    return ("PASS" if state == "VALID" else "FAIL"), f"build {version} {state}"


def check_screenshots(platform: str, sets: list[dict[str, Any]]) -> list[tuple[str, str]]:
    """One line per required display type: count of screenshots present."""
    counts = {s["attributes"]["screenshotDisplayType"]: s.get("_count", 0) for s in sets}
    out = []
    for kind in REQUIRED_DISPLAY_TYPES.get(platform, ()):
        n = counts.get(kind, 0)
        out.append(("PASS" if n >= 1 else "FAIL", f"{kind}: {n} screenshot(s)"))
    extras = sorted(set(counts) - set(REQUIRED_DISPLAY_TYPES.get(platform, ())))
    for kind in extras:
        out.append(("NOTE", f"{kind}: {counts[kind]} screenshot(s)"))
    return out


def check_availability(resp: dict[str, Any]) -> tuple[str, str]:
    """appAvailabilityV2: a 404 means it was never set (the launch-day tell)."""
    if resp.get("_error") == 404:
        return "FAIL", "availability never set (Set Up Availability)"
    if "_error" in resp:
        return "NOTE", f"availability read failed: {resp['_error']}"
    new = resp.get("data", {}).get("attributes", {}).get("availableInNewTerritories")
    return "PASS", f"availability set (availableInNewTerritories={new})"


def check_prices(resp: dict[str, Any]) -> tuple[str, str]:
    """manualPrices 404s when no price schedule exists (a free app still needs one)."""
    if resp.get("_error") == 404:
        return "FAIL", "no price schedule (Add Pricing)"
    if "_error" in resp:
        return "NOTE", f"price read failed: {resp['_error']}"
    return "PASS", f"price schedule: {len(resp.get('data', []))} manual price(s)"


def check_localization(platform: str, attrs: dict[str, Any]) -> list[tuple[str, str]]:
    locale = attrs["locale"]
    out = []
    for line in field_report(platform, locale, "keywords", attrs.get("keywords"), 100):
        out.append(("FAIL", line))
    promo = attrs.get("promotionalText") or ""
    if len(promo) > PROMO_CAP:
        out.append(("FAIL", f"{locale}: promotional text {len(promo)}/{PROMO_CAP}"))
    if not attrs.get("supportUrl"):
        out.append(("FAIL", f"{locale}: no support URL"))
    if not (attrs.get("description") or "").strip():
        out.append(("FAIL", f"{locale}: empty description"))
    return out


def render(platform: str, rows: list[tuple[str, str]]) -> str:
    return "\n".join(f"  {status:4} {text}" for status, text in rows)


# --------------------------------------------------------------------------- #
# Live reads
# --------------------------------------------------------------------------- #


def latest_version(platform: str) -> dict[str, Any] | None:
    resp = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]={platform}&limit=1&include=build")
    if "_error" in resp:
        return None
    data = resp.get("data", [])
    if not data:
        return None
    version = data[0]
    build_id = (version.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
    version["_build"] = next((i for i in resp.get("included", []) if i["id"] == build_id), None) if build_id else None
    return version


def screenshot_sets(localization_id: str) -> list[dict[str, Any]]:
    sets = list(paginate(f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?limit=50"))
    for s in sets:
        s["_count"] = sum(1 for _ in paginate(f"/v1/appScreenshotSets/{s['id']}/appScreenshots?limit=50"))
    return sets


def run(platforms: tuple[str, ...]) -> int:
    failed = False
    print("app-level")
    rows = [check_availability(call("GET", f"/v1/apps/{APP_ID}/appAvailabilityV2"))]
    schedule = call("GET", f"/v1/apps/{APP_ID}/appPriceSchedule")
    schedule_id = schedule.get("data", {}).get("id") if "_error" not in schedule else None
    prices = call("GET", f"/v1/appPriceSchedules/{schedule_id}/manualPrices") if schedule_id else {"_error": 404}
    rows.append(check_prices(prices))
    rows.append(("NOTE", "App Privacy label: not readable by API — confirm 'Data Not Collected' is PUBLISHED in ASC"))
    print(render("APP", rows))
    failed |= any(s == "FAIL" for s, _ in rows)
    for platform in platforms:
        version = latest_version(platform)
        if version is None:
            print(f"{platform}: no version")
            continue
        a = version["attributes"]
        state = a.get("appVersionState") or a.get("appStoreState")
        print(f"{platform} {a['versionString']} {state}")
        rows = [check_build(a, version.get("_build"))]
        if state not in SUBMITTABLE_STATES:
            rows.append(("NOTE", f"state {state}: fields are locked until the version is editable again"))
        for loc in paginate(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=50"):
            rows += check_localization(platform, loc["attributes"])
            if loc["attributes"]["locale"] == "en-US":
                rows += check_screenshots(platform, screenshot_sets(loc["id"]))
        print(render(platform, rows))
        failed |= any(s == "FAIL" for s, _ in rows)
    print("RESULT:", "FAIL" if failed else "PASS")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--platform", choices=PLATFORMS)
    args = ap.parse_args()
    return run((args.platform,) if args.platform else PLATFORMS)


if __name__ == "__main__":
    sys.exit(main())
