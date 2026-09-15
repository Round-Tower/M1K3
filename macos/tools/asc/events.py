"""App Store in-app events for the app.m1k3 record — create a DRAFT, list, inspect.

In-app events show on iPhone and iPad only (Apple's own nomination form says
so; the Mac App Store has no event surface). They still matter for a Mac-first
app: the card surfaces in iOS search and on the Today tab, and an approved or
published event can be ATTACHED to a featuring nomination — Apple asks for
that "as early as possible".

  python3 events.py list
  python3 events.py create --spec ../../fastlane/events/waking-up/event.json --art-dir <dir> [--dry-run]
  python3 events.py update --event 6811192045 --spec ... [--dry-run]   # fix a DRAFT in place

`update` rewrites a DRAFT's attributes (badge, dates, purpose) and every
localization's copy from the spec's `localizations` table, keeping the art
already uploaded — for the draft that was created with over-cap copy and a
past start date. Neither command submits — submission stays a human click in App Store Connect
(events review in their own queue and LOCK while in review). `--dry-run`
prints every payload and touches nothing.

API gotchas (each one cost real time on the Lexy event, 2026-08-20):
- territorySchedules[].territories must list >= 1 territory EXPLICITLY; there
  is no "all" — every id is fetched from /v1/territories (paginated, ~175).
- appEventScreenshots PATCH takes {uploaded: true} ONLY; sourceFileChecksum
  belongs to appScreenshots and 409s here.
- Copy caps: name <= 30, shortDescription <= 50, longDescription <= 120.
- Media: card 1920x1080 (16:9), details 1080x1920 (9:16). Apple overlays the
  event name on the card — keep text in the art minimal.

Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 (a port of the
  proven Lexy script; the M1K3 record's first event is verify-by-run).
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: dyslexia-ai/ios/marketing/tools/events/create_event.py (Kev +
  claude-fable-5, 2026-08-20), ported with a spec file + dry run.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, bail, call, paginate  # noqa: E402

CARD_FILE = "event-card-1920x1080.jpg"  # EVENT_CARD, 16:9
DETAILS_FILE = "event-details-1080x1920.jpg"  # EVENT_DETAILS_PAGE, 9:16
COPY_CAPS = (("name", 30), ("shortDescription", 50), ("longDescription", 120))
BADGES = ("CHALLENGE", "COMPETITION", "LIVE_EVENT", "MAJOR_UPDATE", "NEW_SEASON", "PREMIERE", "SPECIAL_EVENT")
PURPOSES = ("APPROPRIATE_FOR_ALL_USERS", "ATTRACT_NEW_USERS", "KEEP_ACTIVE_USERS_INFORMED", "BRING_BACK_LAPSED_USERS")


# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def copy_problems(copy: dict[str, str]) -> list[str]:
    """Every cap the copy breaks, as 'field: n/cap' lines; empty when clean."""
    out = []
    for field, cap in COPY_CAPS:
        n = len(copy.get(field, ""))
        if n == 0:
            out.append(f"{field}: empty")
        elif n > cap:
            out.append(f"{field}: {n}/{cap}")
    return out


def event_payload(spec: dict[str, Any], territories: list[str]) -> dict[str, Any]:
    """The appEvents POST body from a spec file (see fastlane/events/*/event.json)."""
    if spec["badge"] not in BADGES:
        raise ValueError(f"badge {spec['badge']!r} not in {BADGES}")
    if spec["purpose"] not in PURPOSES:
        raise ValueError(f"purpose {spec['purpose']!r} not in {PURPOSES}")
    attrs: dict[str, Any] = {
        "referenceName": spec["referenceName"],
        "badge": spec["badge"],
        "purchaseRequirement": spec.get("purchaseRequirement", "NO_COST_ASSOCIATED"),
        "primaryLocale": spec.get("locale", "en-US"),
        "priority": spec.get("priority", "HIGH"),
        "purpose": spec["purpose"],
        "territorySchedules": [{
            "territories": territories,
            "publishStart": spec["publishStart"],
            "eventStart": spec["eventStart"],
            "eventEnd": spec["eventEnd"],
        }],
    }
    if spec.get("deepLink"):
        attrs["deepLink"] = spec["deepLink"]
    return {"data": {"type": "appEvents", "attributes": attrs,
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}


def localization_payload(spec: dict[str, Any], event_id: str) -> dict[str, Any]:
    copy = {k: spec["copy"][k] for k, _ in COPY_CAPS}
    return {"data": {"type": "appEventLocalizations",
                     "attributes": {"locale": spec.get("locale", "en-US"), **copy},
                     "relationships": {"appEvent": {"data": {"type": "appEvents", "id": event_id}}}}}


def attributes_patch(spec: dict[str, Any], event_id: str, territories: list[str]) -> dict[str, Any]:
    """The appEvents PATCH body: everything but the app relationship."""
    body = event_payload(spec, territories)["data"]
    return {"data": {"type": "appEvents", "id": event_id, "attributes": body["attributes"]}}


def localization_patch(loc_id: str, copy: dict[str, str]) -> dict[str, Any]:
    return {"data": {"type": "appEventLocalizations", "id": loc_id,
                     "attributes": {k: copy[k] for k, _ in COPY_CAPS}}}


def localization_problems(spec: dict[str, Any]) -> list[str]:
    """Cap breaks across the spec's `localizations` table, prefixed by locale."""
    out = []
    for locale, copy in spec.get("localizations", {}).items():
        out += [f"{locale}: {p}" for p in copy_problems(copy)]
    return out


# --------------------------------------------------------------------------- #
# Live
# --------------------------------------------------------------------------- #


def all_territories() -> list[str]:
    return [t["id"] for t in paginate("/v1/territories?limit=200")]


def upload_screenshots(loc_id: str, art_dir: Path) -> None:
    import requests  # lazy

    for fname, asset_type in ((CARD_FILE, "EVENT_CARD"), (DETAILS_FILE, "EVENT_DETAILS_PAGE")):
        blob = (art_dir / fname).read_bytes()
        shot = call("POST", "/v1/appEventScreenshots", json={"data": {
            "type": "appEventScreenshots",
            "attributes": {"fileName": fname, "fileSize": len(blob), "appEventAssetType": asset_type},
            "relationships": {"appEventLocalization": {"data": {"type": "appEventLocalizations", "id": loc_id}}},
        }})
        if "_error" in shot:
            bail(f"reserve {asset_type}", shot)
        shot_id = shot["data"]["id"]
        for op in shot["data"]["attributes"]["uploadOperations"]:
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            chunk = blob[op["offset"]:op["offset"] + op["length"]]
            r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=300)
            if r.status_code >= 400:
                bail(f"upload bytes {asset_type}", {"_error": r.status_code, "_body": r.text[:400]})
        done = call("PATCH", f"/v1/appEventScreenshots/{shot_id}", json={"data": {
            "type": "appEventScreenshots", "id": shot_id, "attributes": {"uploaded": True}}})
        if "_error" in done:
            bail(f"commit {asset_type}", done)
        state = done["data"]["attributes"].get("assetDeliveryState", {}).get("state")
        print(f"{asset_type}: uploaded ({len(blob)} bytes) -> {state}")


def create(spec_path: Path, art_dir: Path, dry_run: bool) -> int:
    spec = json.loads(spec_path.read_text())
    if problems := copy_problems(spec["copy"]):
        raise SystemExit("copy breaks caps: " + "; ".join(problems))
    for field, cap in COPY_CAPS:
        print(f"{field}: {len(spec['copy'][field])}/{cap} ok")
    for fname in (CARD_FILE, DETAILS_FILE):
        if not (art_dir / fname).exists():
            raise SystemExit(f"missing art: {art_dir / fname}")
    territories = ["<all ~175 from /v1/territories>"] if dry_run else all_territories()
    print(f"territories: {len(territories)}")
    payload = event_payload(spec, territories)
    if dry_run:
        print(json.dumps(payload, indent=2))
        print(json.dumps(localization_payload(spec, "<event id>"), indent=2))
        print("dry run: nothing sent")
        return 0
    ev = call("POST", "/v1/appEvents", json=payload)
    if "_error" in ev:
        bail("create appEvent", ev)
    event_id = ev["data"]["id"]
    print("event created:", event_id, ev["data"]["attributes"].get("eventState"))
    loc = call("POST", "/v1/appEventLocalizations", json=localization_payload(spec, event_id))
    if "_error" in loc:
        bail("create localization", loc)
    print("localization created:", loc["data"]["id"])
    upload_screenshots(loc["data"]["id"], art_dir)
    final = call("GET", f"/v1/appEvents/{event_id}")
    print("final eventState:", final["data"]["attributes"].get("eventState"))
    print("event id:", event_id, "— submit for review by hand in App Store Connect")
    return 0


def update(event_id: str, spec_path: Path, dry_run: bool) -> int:
    spec = json.loads(spec_path.read_text())
    table = spec.get("localizations") or {spec.get("locale", "en-US"): spec["copy"]}
    spec["localizations"] = table
    if problems := localization_problems(spec):
        raise SystemExit("copy breaks caps: " + "; ".join(problems))
    for locale, copy in table.items():
        print(f"{locale:8} " + "  ".join(f"{k} {len(copy[k])}/{cap}" for k, cap in COPY_CAPS))
    territories = ["<all ~175 from /v1/territories>"] if dry_run else all_territories()
    patch = attributes_patch(spec, event_id, territories)
    existing = {l["attributes"]["locale"]: l for l in paginate(f"/v1/appEvents/{event_id}/localizations?limit=50")}
    if dry_run:
        print(json.dumps(patch, indent=2))
        for locale, copy in table.items():
            loc = existing.get(locale)
            print(json.dumps(localization_patch(loc["id"] if loc else "<create>", copy), indent=2, ensure_ascii=False))
        print("dry run: nothing sent")
        return 0
    resp = call("PATCH", f"/v1/appEvents/{event_id}", json=patch)
    if "_error" in resp:
        bail("patch appEvent (not a DRAFT?)", resp)
    print("event:", resp["data"]["attributes"].get("referenceName"), resp["data"]["attributes"].get("badge"))
    for locale, copy in table.items():
        loc = existing.get(locale)
        if loc is None:
            created = call("POST", "/v1/appEventLocalizations", json=localization_payload(
                {**spec, "locale": locale, "copy": copy}, event_id))
            if "_error" in created:
                bail(f"create localization {locale}", created)
            print(f"{locale}: created (no art yet — upload the card + details for it)")
            continue
        done = call("PATCH", f"/v1/appEventLocalizations/{loc['id']}", json=localization_patch(loc["id"], copy))
        if "_error" in done:
            bail(f"patch localization {locale}", done)
        print(f"{locale}: {done['data']['attributes']['name']}")
    for locale in set(existing) - set(table):
        print(f"{locale}: no copy in the spec — left as is")
    print("event id:", event_id, "— submit for review by hand in App Store Connect")
    return 0


def list_events() -> int:
    events = list(paginate(f"/v1/apps/{APP_ID}/appEvents?limit=50"))
    if not events:
        print("no in-app events on the record")
        return 0
    for e in events:
        a = e["attributes"]
        sched = (a.get("territorySchedules") or [{}])[0]
        print(f"{e['id']}  {a.get('eventState'):18} {a.get('badge'):14} {a.get('referenceName')}  "
              f"{sched.get('eventStart', '?')} → {sched.get('eventEnd', '?')}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    c = sub.add_parser("create")
    c.add_argument("--spec", required=True, type=Path, help="event.json (see fastlane/events/)")
    c.add_argument("--art-dir", required=True, type=Path, help=f"holds {CARD_FILE} + {DETAILS_FILE}")
    c.add_argument("--dry-run", action="store_true")
    u = sub.add_parser("update")
    u.add_argument("--event", required=True, help="appEvents id of a DRAFT")
    u.add_argument("--spec", required=True, type=Path)
    u.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.cmd == "list":
        return list_events()
    if args.cmd == "update":
        return update(args.event, args.spec, args.dry_run)
    return create(args.spec, args.art_dir, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
