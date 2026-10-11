"""App Store in-app events for the app.m1k3 record — create a DRAFT, list, inspect.

In-app events show on iPhone and iPad only (Apple's own nomination form says
so; the Mac App Store has no event surface). They still matter for a Mac-first
app: the card surfaces in iOS search and on the Today tab, and an approved or
published event can be ATTACHED to a featuring nomination — Apple asks for
that "as early as possible".

  python3 events.py list
  python3 events.py create --spec ../../fastlane/events/waking-up/event.json --art-dir <dir> [--dry-run]
  python3 events.py create --spec ... --art-dir <dir> --event 6811192045 [--dry-run]   # resume a half-built DRAFT
  python3 events.py update --event 6811192045 --spec ... [--dry-run]   # fix a DRAFT in place

`create` makes the DRAFT and one localization per locale in the spec's
`localizations` table (primary first), uploading the same card + details to
each — the art is textless, so one pair serves every locale. A failure once
the event exists names the DRAFT and the `--event` line that resumes it (a
plain re-run would POST a second event). `create --event <id>` lists the
event's localizations and creates only the missing locales, art and all; a
locale that already exists is skipped and its art is NOT checked.
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
Review: Kev + claude-opus-5.5, 2026-10-11 — `create` posted only the primary
  locale, so an eight-locale spec (halloween) shipped as en-US alone; it now
  creates every locale in the table and uploads the textless art to each, and
  checks every locale's caps first. Confidence 0.75 — the dry run is pinned by
  test; the multi-locale POST loop is verify-by-run (Kev's, via `!`).
Review: Kev + claude-opus-5.5, 2026-10-11 — review fold: a failure after the event
  POST stranded a DRAFT that a re-run duplicated. Every upload bail now names the
  locale and event, the byte PUT's transport errors bail instead of raising, any
  later failure prints the `--event` resume line, and `create --event` creates only
  the missing locales (existing ones skipped, art unchecked: no code here reads a
  localization's screenshots back). `localization_table` no longer needs `copy`
  when the table holds the primary. Confidence 0.75 — the loop and resume are pinned
  against a recorded fake; the live resume is still verify-by-run.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterator
from contextlib import contextmanager
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


def localization_table(spec: dict[str, Any]) -> dict[str, dict[str, str]]:
    """Every locale's copy, primary first: the spec's `localizations` table, with its one
    `copy` block standing in for the primary when the table lacks it."""
    primary = spec.get("locale", "en-US")
    table = dict(spec.get("localizations") or {})
    copy = table.pop(primary, None) or spec.get("copy")
    if not copy:
        raise ValueError(f"no copy for the primary locale {primary}: add it to `localizations` or give a `copy` block")
    return {primary: copy, **table}


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


def existing_localizations(event_id: str) -> dict[str, str]:
    """locale -> appEventLocalizations id, for every locale the event already has."""
    return {l["attributes"]["locale"]: l["id"] for l in paginate(f"/v1/appEvents/{event_id}/localizations?limit=50")}


def put_bytes(op: dict[str, Any], blob: bytes) -> dict[str, Any] | None:
    """PUT one upload operation's slice of `blob`. None when it landed, else an error in
    `call`'s `{'_error', '_body'}` shape — a timeout included, never a bare traceback."""
    import requests  # lazy

    headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
    chunk = blob[op["offset"]:op["offset"] + op["length"]]
    try:
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=300)
    except requests.RequestException as exc:
        return {"_error": "transport", "_body": str(exc)[:400]}
    return {"_error": r.status_code, "_body": r.text[:400]} if r.status_code >= 400 else None


def upload_screenshots(event_id: str, locale: str, loc_id: str, art_dir: Path) -> None:
    where = (f"for {locale} of event {event_id} (localization {loc_id} exists without its full art; "
             "a resume skips it, so add the art in App Store Connect or delete that localization first)")
    for fname, asset_type in ((CARD_FILE, "EVENT_CARD"), (DETAILS_FILE, "EVENT_DETAILS_PAGE")):
        blob = (art_dir / fname).read_bytes()
        shot = call("POST", "/v1/appEventScreenshots", json={"data": {
            "type": "appEventScreenshots",
            "attributes": {"fileName": fname, "fileSize": len(blob), "appEventAssetType": asset_type},
            "relationships": {"appEventLocalization": {"data": {"type": "appEventLocalizations", "id": loc_id}}},
        }})
        if "_error" in shot:
            bail(f"reserve {asset_type} {where}", shot)
        shot_id = shot["data"]["id"]
        for op in shot["data"]["attributes"]["uploadOperations"]:
            if err := put_bytes(op, blob):
                bail(f"upload bytes {asset_type} {where}", err)
        done = call("PATCH", f"/v1/appEventScreenshots/{shot_id}", json={"data": {
            "type": "appEventScreenshots", "id": shot_id, "attributes": {"uploaded": True}}})
        if "_error" in done:
            bail(f"commit {asset_type} {where}", done)
        state = done["data"]["attributes"].get("assetDeliveryState", {}).get("state")
        print(f"{locale} {asset_type}: uploaded ({len(blob)} bytes) -> {state}")


@contextmanager
def draft_guard(event_id: str, spec_path: Path, art_dir: Path) -> Iterator[None]:
    """Once the event exists, any failure says how to resume or clear the DRAFT: a plain
    re-run would POST a second event beside it."""
    hint = (f"event {event_id} exists as a DRAFT — resume with `events.py create --spec {spec_path} "
            f"--art-dir {art_dir} --event {event_id}`, or delete it in App Store Connect")
    try:
        yield
    except SystemExit as exc:
        raise SystemExit(f"{exc.code}\n{hint}") from None
    except BaseException:
        print(hint, file=sys.stderr)
        raise


def post_event(spec: dict[str, Any]) -> str:
    """POST the DRAFT and return its id. A bail here leaves nothing behind."""
    territories = all_territories()
    print(f"territories: {len(territories)}")
    ev = call("POST", "/v1/appEvents", json=event_payload(spec, territories))
    if "_error" in ev:
        bail("create appEvent", ev)
    print("event created:", ev["data"]["id"], ev["data"]["attributes"].get("eventState"))
    return ev["data"]["id"]


def fill_locales(spec: dict[str, Any], table: dict[str, dict[str, str]], art_dir: Path,
                 event_id: str, existing: dict[str, str]) -> None:
    """One localization per locale the event lacks, primary first, each with the same
    textless card + details. A locale that exists is skipped and its art isn't checked:
    no code here reads a localization's screenshots back, so that shape is unproven."""
    for locale, copy in table.items():
        if locale in existing:
            print(f"{locale}: exists ({existing[locale]}), skipped; its art is NOT checked, confirm it in App Store Connect")
            continue
        loc = call("POST", "/v1/appEventLocalizations",
                   json=localization_payload({**spec, "locale": locale, "copy": copy}, event_id))
        if "_error" in loc:
            bail(f"create localization {locale} of event {event_id}", loc)
        print(f"{locale}: localization created:", loc["data"]["id"])
        upload_screenshots(event_id, locale, loc["data"]["id"], art_dir)


def print_dry_run(spec: dict[str, Any], table: dict[str, dict[str, str]], art_dir: Path,
                  event_id: str | None) -> int:
    if event_id is None:
        territories = ["<all ~175 from /v1/territories>"]
        print(f"territories: {len(territories)}")
        print(json.dumps(event_payload(spec, territories), indent=2))
    else:
        print(f"resume: would GET /v1/appEvents/{event_id}/localizations and create only the locales it lacks")
    for locale, copy in table.items():
        body = localization_payload({**spec, "locale": locale, "copy": copy}, event_id or "<event id>")
        print(json.dumps(body, indent=2, ensure_ascii=False))
    print(f"art for each new locale: {CARD_FILE} + {DETAILS_FILE} from {art_dir}")
    print("dry run: nothing sent")
    return 0


def create(spec_path: Path, art_dir: Path, dry_run: bool, event_id: str | None = None) -> int:
    """The DRAFT and every locale, or with `event_id` the locales an earlier run left out."""
    spec = json.loads(spec_path.read_text())
    table = localization_table(spec)
    if problems := localization_problems({"localizations": table}):
        raise SystemExit("copy breaks caps: " + "; ".join(problems))
    for locale, copy in table.items():
        print(f"{locale:8} " + "  ".join(f"{k} {len(copy[k])}/{cap}" for k, cap in COPY_CAPS))
    for fname in (CARD_FILE, DETAILS_FILE):
        if not (art_dir / fname).exists():
            raise SystemExit(f"missing art: {art_dir / fname}")
    if dry_run:
        return print_dry_run(spec, table, art_dir, event_id)
    resuming = event_id is not None
    if event_id is None:
        event_id = post_event(spec)
    with draft_guard(event_id, spec_path, art_dir):
        existing = existing_localizations(event_id) if resuming else {}
        fill_locales(spec, table, art_dir, event_id, existing)
    final = call("GET", f"/v1/appEvents/{event_id}")
    print("final eventState:", final.get("data", {}).get("attributes", {}).get("eventState", "?"))
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
    c.add_argument("--event", help="resume: the appEvents id of a DRAFT an earlier create left half-built")
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
    return create(args.spec, args.art_dir, args.dry_run, args.event)


if __name__ == "__main__":
    sys.exit(main())
