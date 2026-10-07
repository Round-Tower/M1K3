#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt>=2.8", "cryptography>=42", "requests>=2.31"]
# ///
"""App Store creative assets for the app.m1k3 record — the product page header and the
search results image, through the App Asset Library (iOS / iPadOS 27 only).

  ./creative.py status                     # library assets, their state, spec and placements
  ./creative.py targets                    # iOS versions + custom product pages that can take one
  ./creative.py upload FILE [--name REF] [--poster 00:00:01:00] [--confirm]
  ./creative.py place ASSET --as header|search --on version:ID|cpp:ID|ppo:ID [--locales en-US,en-GB] [--confirm]

Upload once, place many: one asset backs a placement per localization (a textless header
backs them all), and the same asset can sit on a version, a custom product page and a
Product Page Optimization treatment at once. Without `--confirm` every write is a dry run
that prints its payloads. Placements go to review with their parent surface; an asset can
also be submitted on its own from Asset Library in App Store Connect (a review submission
item takes `appAssetLibraryImage` / `appAssetLibraryVideo`), which stays a human click.

API facts (Apple's docs + the live catalogue, 2026-10-07):
- The library's id is the app's id (`GET /v1/apps/{id}/assetLibrary`).
- Reserve → PUT each uploadOperation (no JWT on those URLs) → PATCH `{uploaded: true}` ALONE
  (no sourceFileChecksum, unlike appScreenshots) → poll to PREPARE_FOR_SUBMISSION.
- ASC picks the spec (`specId`); compare it to the catalogue rather than a hard-coded list.
- Header and search are `placementGroup: DEFAULT_PROFILE`, max 1 per localization, on
  versions, custom product pages and PPO treatments alike. A placement can't be edited:
  delete it and place again.
- A placement needs an editable parent: an approved version or CPP version 409s.

Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.65
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: Unknown (new file; payload shapes from Apple's App Asset Library docs, upload
  loop after events.py). The read paths are verified against live ASC; the writes are
  verify-by-run — ASC writes are Kev's, via `!`.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Iterable
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, bail, call, paginate
from submit import is_editable

KINDS = {".png": "image", ".jpg": "image", ".jpeg": "image", ".mp4": "video", ".m4v": "video", ".mov": "video"}
RESOURCE = {"image": "appAssetLibraryImages", "video": "appAssetLibraryVideos"}
PLACEMENT = {"header": "PRODUCT_PAGE_HEADER_ASSET", "search": "APP_STORE_SEARCH_RESULTS_ASSET"}
GROUP = "DEFAULT_PROFILE"
# surface → (parent resource, its localizations relationship, the placement's relationship + type)
SURFACES = {
    "version": ("appStoreVersions", "appStoreVersionLocalizations", "appStoreVersionLocalization"),
    "cpp": ("appCustomProductPageVersions", "appCustomProductPageLocalizations", "appCustomProductPageLocalization"),
    "ppo": ("appStoreVersionExperimentTreatments", "appStoreVersionExperimentTreatmentLocalizations",
            "appStoreVersionExperimentTreatmentLocalization"),
}
PLACEABLE = {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "APPROVED"}
EDITABLE_PARENT = {"cpp": {"PREPARE_FOR_SUBMISSION", "REJECTED"}, "ppo": {"PREPARE_FOR_SUBMISSION"}}
NO_SUCH = "no such localization on this surface"
POLLS, POLL_SECONDS = 120, 5


# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #
def kind_for(path: Path) -> str:
    kind = KINDS.get(path.suffix.lower())
    if not kind:
        raise SystemExit(f"{path.name}: creative assets are .png/.jpg/.jpeg images or .mp4/.m4v/.mov videos")
    return kind


def reserve_payload(kind: str, file_name: str, size: int, library_id: str, name: str | None,
                    poster: str | None = None) -> dict[str, Any]:
    attrs: dict[str, Any] = {"fileName": file_name, "fileSize": size, "category": "CREATIVE_ASSETS"}
    if name:
        attrs["referenceName"] = name
    if poster and kind == "video":
        attrs["previewFrameTimeCode"] = poster
    return {"data": {"type": RESOURCE[kind], "attributes": attrs, "relationships": {
        "assetLibrary": {"data": {"type": "appAssetLibraries", "id": library_id}}}}}


def commit_payload(kind: str, asset_id: str) -> dict[str, Any]:
    return {"data": {"type": RESOURCE[kind], "id": asset_id, "attributes": {"uploaded": True}}}


def parts(blob: bytes, ops: Iterable[dict[str, Any]]) -> list[tuple[dict[str, Any], bytes]]:
    """Each upload operation's slice of the file. Refuses operations that don't tile the file
    exactly: a short list would upload a truncated asset that the commit then rejects."""
    ops = sorted(ops, key=lambda op: op["offset"])
    covered = 0
    for op in ops:
        if op["offset"] != covered:
            raise SystemExit(f"upload operations leave a gap or overlap at byte {covered}")
        covered += op["length"]
    if covered != len(blob):
        raise SystemExit(f"upload operations cover {covered} of {len(blob)} bytes")
    return [(op, blob[op["offset"]:op["offset"] + op["length"]]) for op in ops]


def parse_target(arg: str) -> tuple[str, str]:
    surface, _, ident = arg.partition(":")
    if surface not in SURFACES or not ident:
        raise SystemExit(f"--on {arg!r}: expected version:ID, cpp:ID (a CPP *version*) or ppo:ID (a treatment)")
    return surface, ident


def parse_locales(arg: str | None) -> list[str] | None:
    if not arg:
        return None
    return list(dict.fromkeys(locale.strip() for locale in arg.split(",") if locale.strip()))


def placement_payload(kind: str, asset_id: str, as_: str, surface: str, loc_id: str) -> dict[str, Any]:
    _, loc_type, loc_rel = SURFACES[surface]
    return {"data": {"type": "appAssetLibraryPlacements",
                     "attributes": {"placementType": PLACEMENT[as_], "placementGroup": GROUP},
                     "relationships": {kind: {"data": {"type": RESOURCE[kind], "id": asset_id}},
                                       loc_rel: {"data": {"type": loc_type, "id": loc_id}}}}}


def plan(localizations: list[tuple[str, str]], existing: dict[str, list[str]], as_: str,
         locales: list[str] | None) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """(to create as (loc_id, locale), to skip as (locale, why)). One header and one search
    asset per localization is the cap on every surface."""
    by_locale = {locale: loc_id for loc_id, locale in localizations}
    wanted = locales or [locale for _, locale in localizations]
    create, skip = [], []
    for locale in wanted:
        loc_id = by_locale.get(locale)
        if loc_id is None:
            skip.append((locale, NO_SUCH))
        elif PLACEMENT[as_] in existing.get(loc_id, []):
            skip.append((locale, f"already has a {as_} (max 1)"))
        else:
            create.append((loc_id, locale))
    return create, skip


def state_problem(attrs: dict[str, Any]) -> str | None:
    state = attrs.get("state")
    if state in PLACEABLE:
        return None
    if state in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
        return f"still {state} — wait for processing to finish"
    return f"{state}: {json.dumps(attrs.get('stateDetails'))[:300]}"


def spec_problem(spec_id: str | None, as_: str, specs: dict[str, dict[str, Any]]) -> str | None:
    spec = specs.get(spec_id or "")
    if spec is None:
        return f"unknown spec {spec_id!r} — refresh the catalogue (GET /v1/appAssetLibraryRefData)"
    fits = spec.get("compatiblePlacementTypes", [])
    if PLACEMENT[as_] not in fits:
        return f"{spec.get('shortName', spec_id)} fits {', '.join(fits) or 'nothing listed'}, not {PLACEMENT[as_]}"
    return None


def parent_problem(surface: str, attrs: dict[str, Any]) -> str | None:
    """Placements only land on an editable iPhone/iPad surface; anything else 409s."""
    if surface == "version":
        if attrs.get("platform") != "IOS":
            return f"a {attrs.get('platform')} version — creative assets are iPhone and iPad only"
        state = attrs.get("appVersionState")
        return None if is_editable(state) else f"version is {state}: a placement needs an editable version (the next one)"
    state = attrs.get("state")
    if state in EDITABLE_PARENT[surface]:
        return None
    return f"{'custom product page version' if surface == 'cpp' else 'experiment'} is {state}: placements need it editable"


# --------------------------------------------------------------------------- #
# Network
# --------------------------------------------------------------------------- #
def catalogue(strict: bool = True) -> dict[str, dict[str, Any]]:
    resp = call("GET", "/v1/appAssetLibraryRefData?fields[appAssetLibraryRefData]=imageSpecs,videoSpecs")
    if "_error" in resp or not resp.get("data"):
        if strict:
            bail("read the spec catalogue", resp)
        return {}
    attrs = resp["data"][0]["attributes"]
    return {s["specId"]: s for s in attrs.get("imageSpecs", []) + attrs.get("videoSpecs", [])}


def find_asset(asset_id: str) -> tuple[str, dict[str, Any]]:
    for kind, resource in RESOURCE.items():
        resp = call("GET", f"/v1/{resource}/{asset_id}")
        if "_error" not in resp:
            return kind, resp["data"]["attributes"]
        status = resp["_error"]
        if not isinstance(status, int) or status in (401, 403, 429) or status >= 500:
            raise SystemExit(f"reading {resource}/{asset_id}: {status} {resp.get('_body', '')[:300]}")
    raise SystemExit(f"no library image or video {asset_id}")


def parent_state(surface: str, parent_id: str) -> dict[str, Any] | None:
    if surface == "ppo":
        # Read live 2026-10-07: the included experiment is type appStoreVersionExperiments, with `state`.
        resp = call("GET", f"/v1/appStoreVersionExperimentTreatments/{parent_id}?include=appStoreVersionExperimentV2")
        experiment = next((i for i in resp.get("included") or [] if i.get("type") == "appStoreVersionExperiments"), None)
        if "_error" in resp or experiment is None or "state" not in experiment.get("attributes", {}):
            print("  warning: couldn't read the experiment's state — ASC will refuse if it isn't editable")
            return None
        return experiment["attributes"]
    path = (f"/v1/appStoreVersions/{parent_id}?fields[appStoreVersions]=platform,appVersionState" if surface == "version"
            else f"/v1/appCustomProductPageVersions/{parent_id}")
    resp = call("GET", path)
    if "_error" in resp:
        raise SystemExit(f"reading {surface}:{parent_id}: {resp['_error']} {resp.get('_body', '')[:300]}")
    return resp["data"]["attributes"]


def put_part(op: dict[str, Any], chunk: bytes, tries: int = 3, send: Any = None) -> None:
    """One upload operation (no JWT: these URLs are presigned), retried on a transport error,
    a 5xx, a timeout (408) or throttling (429); any other client error fails at once."""
    if send is None:
        import requests  # lazy, see asc.call

        send = requests.request
    headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
    detail = ""
    for attempt in range(1, tries + 1):
        try:
            r = send(op["method"], op["url"], headers=headers, data=chunk, timeout=600)
        except OSError as exc:            # requests' RequestException is an IOError
            detail = str(exc)[:300]
        else:
            if r.status_code < 400:
                return
            detail = f"{r.status_code} {r.text[:300]}"
            if r.status_code < 500 and r.status_code not in (408, 429):
                break
        if attempt < tries:
            time.sleep(2 * attempt)
    raise SystemExit(f"upload part @{op['offset']} failed: {detail}")


def library(app: str) -> list[tuple[str, dict[str, Any]]]:
    return [(kind, item) for kind in RESOURCE
            for item in paginate(f"/v1/appAssetLibraries/{app}/{'images' if kind == 'image' else 'videos'}"
                                 f"?filter[category]=CREATIVE_ASSETS&limit=200")]


def run_status(app: str) -> int:
    specs = catalogue()
    items = library(app)
    if not items:
        print("no creative assets in the library yet")
    for kind, item in items:
        a = item["attributes"]
        spec = specs.get(a.get("specId") or "", {}).get("shortName", "—")
        placed = list(paginate(f"/v1/{RESOURCE[kind]}/{item['id']}/placements?limit=200"))
        where = ", ".join(sorted({p["attributes"]["placementType"] for p in placed})) or "not placed"
        print(f"{kind:5} {item['id']}  {a.get('state') or '—':24} {spec:18} {a.get('referenceName') or a.get('fileName')}  [{where}]")
    return 0


def run_targets(app: str) -> int:
    print("iOS versions:")
    for v in paginate(f"/v1/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=10"):
        state = v["attributes"].get("appVersionState") or v["attributes"].get("appStoreState")
        print(f"  version:{v['id']}  {v['attributes']['versionString']:8} {state}{'  ← editable' if is_editable(state) else ''}")
    print("custom product pages:")
    for page in paginate(f"/v1/apps/{app}/appCustomProductPages?limit=50"):
        for ver in paginate(f"/v1/appCustomProductPages/{page['id']}/appCustomProductPageVersions?limit=10"):
            state = ver["attributes"].get("state")
            print(f"  cpp:{ver['id']}  {page['attributes'].get('name', '')[:30]:30} {state}"
                  f"{'  ← editable' if state in EDITABLE_PARENT['cpp'] else ''}")
    return 0


def run_upload(app: str, path: Path, name: str | None, poster: str | None, confirm: bool) -> int:
    kind, blob = kind_for(path), path.read_bytes()
    payload = reserve_payload(kind, path.name, len(blob), app, name, poster)
    if not confirm:
        print(json.dumps(payload, indent=2))
        print(f"dry-run — add --confirm to reserve, upload ({len(blob):,} bytes) and commit")
        return 0
    made = call("POST", f"/v1/{RESOURCE[kind]}", json=payload)
    if "_error" in made:
        bail("reserve", made)
    asset_id = made["data"]["id"]
    print(f"{kind} {asset_id}: reserved (if this run dies, `status` shows it AWAITING_UPLOAD; delete it in Asset Library)")
    for op, chunk in parts(blob, made["data"]["attributes"]["uploadOperations"]):
        put_part(op, chunk)
    done = call("PATCH", f"/v1/{RESOURCE[kind]}/{asset_id}", json=commit_payload(kind, asset_id))
    if "_error" in done:
        bail(f"commit {asset_id}", done)
    print(f"{kind} {asset_id}: committed, processing…")
    attrs: dict[str, Any] = {}
    misses = 0
    for _ in range(POLLS):
        resp = call("GET", f"/v1/{RESOURCE[kind]}/{asset_id}")
        if "_error" in resp:
            misses += 1
            if misses >= 5:
                raise SystemExit(f"{kind} {asset_id}: committed, but ASC stopped answering ({resp['_error']}) — check `status`")
        else:
            misses, attrs = 0, resp["data"]["attributes"]
            if attrs.get("state") not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
                break
        time.sleep(POLL_SECONDS)
    else:
        print(f"{kind} {asset_id}: still processing after {POLLS * POLL_SECONDS} s — check later with `status`")
        return 1
    if attrs.get("state") != "PREPARE_FOR_SUBMISSION":
        print(f"{kind} {asset_id}: {state_problem(attrs) or attrs.get('state')}")
        return 1
    spec = catalogue(strict=False).get(attrs.get("specId") or "", {})
    print(f"{kind} {asset_id}: PREPARE_FOR_SUBMISSION  spec {spec.get('shortName', attrs.get('specId'))}"
          f"  fits {', '.join(spec.get('compatiblePlacementTypes', [])) or '—'}")
    return 0


def run_place(asset_id: str, as_: str, target: str, locales: list[str] | None, confirm: bool) -> int:
    surface, parent_id = parse_target(target)
    kind, attrs = find_asset(asset_id)
    for problem in filter(None, (state_problem(attrs), spec_problem(attrs.get("specId"), as_, catalogue()))):
        raise SystemExit(f"{asset_id}: {problem}")
    parent_attrs = parent_state(surface, parent_id)
    if parent_attrs is not None and (problem := parent_problem(surface, parent_attrs)):
        raise SystemExit(f"{target}: {problem}")
    parent, locs_rel, _ = SURFACES[surface]
    locs = [(loc["id"], loc["attributes"]["locale"]) for loc in paginate(f"/v1/{parent}/{parent_id}/{locs_rel}?limit=200")]
    existing = {loc_id: [p["attributes"]["placementType"] for p in paginate(f"/v1/{locs_rel}/{loc_id}/placements?limit=200")]
                for loc_id, _ in locs}
    create, skip = plan(locs, existing, as_, locales)
    for locale, why in skip:
        print(f"  skip {locale}: {why}")
    placed = 0
    for i, (loc_id, locale) in enumerate(create):
        payload = placement_payload(kind, asset_id, as_, surface, loc_id)
        if not confirm:
            if i == 0:
                print(json.dumps(payload, indent=2))
            print(f"  would place {as_} on {locale} ({loc_id})")
            continue
        made = call("POST", "/v1/appAssetLibraryPlacements", json=payload)
        if "_error" in made:
            bail(f"place on {locale} (placements already made stay; a re-run skips them)", made)
        placed += 1
        print(f"  placed {as_} on {locale}: {made['data']['id']} {made['data'].get('attributes', {}).get('state', '')}")
    missing = sum(why == NO_SUCH for _, why in skip)
    if not confirm and create:
        print("dry-run — add --confirm to create these placements")
    print(f"  placed {placed}, skipped {len(skip)} ({missing} not on this surface)")
    return 1 if missing else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", default=APP_ID)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("targets")
    up = sub.add_parser("upload")
    up.add_argument("file", type=Path)
    up.add_argument("--name", help="referenceName, shown only in App Store Connect")
    up.add_argument("--poster", help="video poster frame, HH:MM:SS:FF")
    up.add_argument("--confirm", action="store_true")
    pl = sub.add_parser("place")
    pl.add_argument("asset")
    pl.add_argument("--as", dest="as_", choices=sorted(PLACEMENT), required=True)
    pl.add_argument("--on", required=True, help="version:ID | cpp:ID | ppo:ID")
    pl.add_argument("--locales", help="comma-separated; default every localization on the surface")
    pl.add_argument("--confirm", action="store_true")
    args = parser.parse_args()
    if args.cmd == "status":
        return run_status(args.app)
    if args.cmd == "targets":
        return run_targets(args.app)
    if args.cmd == "upload":
        return run_upload(args.app, args.file, args.name, args.poster, args.confirm)
    return run_place(args.asset, args.as_, args.on, parse_locales(args.locales), args.confirm)


if __name__ == "__main__":
    sys.exit(main())
