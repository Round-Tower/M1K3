#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""App Store accessibility labels (Accessibility Nutrition Labels), per device family.

The claims live in `accessibility_labels.json`, reviewed in git, each with its evidence.
Only `declare` is sent as supported; `pending` and `no` go as not supported. `set` is a
dry run until `--confirm`, and `--confirm` refuses while a chosen family still has a
`pending` claim (#834: declare only what the 1.5 TestFlight walk confirms) unless
`--allow-pending "<why>"`. A write leaves a DRAFT; `--publish` publishes it.

  ./accessibility.py show
  ./accessibility.py set --family MAC,IPHONE,IPAD              # dry run: the plan and payloads
  ./accessibility.py set --family MAC --publish --confirm      # Kev's write, via !

The API (ASC OpenAPI 4.6, read 2026-11-15): POST /v1/accessibilityDeclarations makes one
per deviceFamily; PATCH /v1/accessibilityDeclarations/{id} edits a DRAFT and `publish:
true` publishes it (the previous PUBLISHED one becomes REPLACED). The read path is proven
(2026-11-15: zero declarations); the write path is unproven until its first --confirm.

Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.75 (payloads pinned against the
OpenAPI schema; no write has run yet). Prior: none (new file).
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Context: Kev, 2026-11-15: "We'll also need to update the ASC to reflect the accessibility changes."
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, bail, call

SPEC = Path(__file__).resolve().parent / "accessibility_labels.json"
TYPE = "accessibilityDeclarations"
DEVICE_FAMILIES = ("IPHONE", "IPAD", "APPLE_TV", "APPLE_WATCH", "MAC", "VISION")
STATUSES = ("declare", "pending", "no")
# spec key → API attribute, in App Store Connect's order.
ATTRIBUTE = {
    "voiceover": "supportsVoiceover",
    "voiceControl": "supportsVoiceControl",
    "largerText": "supportsLargerText",
    "darkInterface": "supportsDarkInterface",
    "differentiateWithoutColorAlone": "supportsDifferentiateWithoutColorAlone",
    "sufficientContrast": "supportsSufficientContrast",
    "reducedMotion": "supportsReducedMotion",
    "captions": "supportsCaptions",
    "audioDescriptions": "supportsAudioDescriptions",
}
FEATURES = tuple(ATTRIBUTE)


def load_spec(path: Path = SPEC) -> dict[str, dict[str, dict[str, str]]]:
    """The spec without its `_about`, refused whole if a family, feature or status is off."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    spec = {k: v for k, v in raw.items() if not k.startswith("_")}
    for family, claims in spec.items():
        if family not in DEVICE_FAMILIES:
            raise SystemExit(f"{path.name}: unknown device family {family}")
        missing = [f for f in FEATURES if f not in claims]
        extra = [f for f in claims if f not in ATTRIBUTE]
        if missing or extra:
            raise SystemExit(f"{path.name} {family}: missing {missing} unknown {extra}")
        for feature, claim in claims.items():
            if claim.get("status") not in STATUSES:
                raise SystemExit(f"{path.name} {family}.{feature}: status {claim.get('status')!r}")
    return spec


def attributes(claims: dict[str, dict[str, str]]) -> dict[str, bool]:
    return {ATTRIBUTE[f]: claims[f]["status"] == "declare" for f in FEATURES}


def create_body(family: str, attrs: dict[str, bool]) -> dict[str, Any]:
    return {"data": {"type": TYPE, "attributes": {"deviceFamily": family, **attrs},
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}


def update_body(declaration_id: str, attrs: dict[str, bool], publish: bool) -> dict[str, Any]:
    attributes_ = dict(attrs)
    if publish:
        attributes_["publish"] = True
    return {"data": {"type": TYPE, "id": declaration_id, "attributes": attributes_}}


@dataclass
class Step:
    family: str
    action: str  # create | update | same
    attrs: dict[str, bool]
    draft_id: str | None = None
    pending: list[str] = field(default_factory=list)


def _live_attrs(item: dict[str, Any]) -> dict[str, bool]:
    a = item["attributes"]
    return {ATTRIBUTE[f]: bool(a.get(ATTRIBUTE[f])) for f in FEATURES}


def plan(spec: dict[str, dict[str, dict[str, str]]], live: list[dict[str, Any]], families: list[str]) -> list[Step]:
    """Per family: edit the live DRAFT, else create one, unless the PUBLISHED one already says it."""
    steps = []
    for family in families:
        if family not in spec:
            raise SystemExit(f"{family}: not in the spec")
        attrs = attributes(spec[family])
        pending = [f for f in FEATURES if spec[family][f]["status"] == "pending"]
        mine = [d for d in live if d["attributes"].get("deviceFamily") == family]
        draft = next((d for d in mine if d["attributes"].get("state") == "DRAFT"), None)
        published = next((d for d in mine if d["attributes"].get("state") == "PUBLISHED"), None)
        if draft is not None:
            steps.append(Step(family, "update", attrs, draft["id"], pending))
        elif published is not None and _live_attrs(published) == attrs:
            steps.append(Step(family, "same", attrs, None, pending))
        else:
            steps.append(Step(family, "create", attrs, None, pending))
    return steps


def refusal(steps: list[Step], allow_pending: str | None) -> str | None:
    """Why --confirm must not write, or None."""
    open_claims = [f"{s.family}.{f}" for s in steps for f in s.pending]
    if open_claims and not allow_pending:
        return ("pending claims (walk them on the 1.5 TestFlight build, then flip each to declare or no in "
                f"{SPEC.name}): " + ", ".join(open_claims))
    return None


def fetch_live() -> list[dict[str, Any]]:
    resp = call("GET", f"/v1/apps/{APP_ID}/{TYPE}?limit=50")
    if "_error" in resp:
        bail("read declarations", resp)
    return resp.get("data", [])


def show() -> int:
    live = fetch_live()
    if not live:
        print("no accessibility declarations on the record")
    for item in sorted(live, key=lambda d: (d["attributes"]["deviceFamily"], d["attributes"]["state"])):
        a = item["attributes"]
        yes = [f for f in FEATURES if a.get(ATTRIBUTE[f])]
        print(f"{a['deviceFamily']:8} {a['state']:9} {item['id']}  {', '.join(yes) or '(none supported)'}")
    return 0


def set_labels(families: list[str], publish: bool, confirm: bool, allow_pending: str | None) -> int:
    spec = load_spec()
    steps = plan(spec, fetch_live(), families)
    for s in steps:
        yes = [f for f in FEATURES if s.attrs[ATTRIBUTE[f]]]
        print(f"{s.family}: {s.action}{' ' + s.draft_id if s.draft_id else ''}"
              f"  declare: {', '.join(yes) or '(none)'}  pending: {', '.join(s.pending) or '(none)'}")
    why = refusal(steps, allow_pending)
    if not confirm:
        for s in steps:
            if s.action == "create":
                print(json.dumps(create_body(s.family, s.attrs)))
            elif s.action == "update":
                print(json.dumps(update_body(s.draft_id or "", s.attrs, publish)))
        print(f"(dry run{'; --confirm would refuse: ' + why if why else ''})")
        return 0
    if why:
        print(f"REFUSED: {why}", file=sys.stderr)
        return 3
    for s in steps:
        if s.action == "same":
            continue
        draft_id = s.draft_id
        if s.action == "create":
            resp = call("POST", f"/v1/{TYPE}", json=create_body(s.family, s.attrs))
            if "_error" in resp:
                bail(f"create {s.family}", resp)
            draft_id = resp["data"]["id"]
            if publish:
                resp = call("PATCH", f"/v1/{TYPE}/{draft_id}", json=update_body(draft_id, {}, publish=True))
        else:
            resp = call("PATCH", f"/v1/{TYPE}/{draft_id}", json=update_body(draft_id or "", s.attrs, publish))
        if "_error" in resp:
            bail(f"{'publish' if publish else 'update'} {s.family}", resp)
    print("read back:")
    return show()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    s = sub.add_parser("set")
    s.add_argument("--family", default="MAC,IPHONE,IPAD", help="comma list of device families")
    s.add_argument("--publish", action="store_true", help="publish the draft (else it stays DRAFT)")
    s.add_argument("--confirm", action="store_true")
    s.add_argument("--allow-pending", metavar="WHY", help="write although some claims are still pending")
    args = parser.parse_args(argv)
    if args.cmd == "show":
        return show()
    families = [f.strip() for f in args.family.split(",") if f.strip()]
    return set_labels(families, args.publish, args.confirm, args.allow_pending)


if __name__ == "__main__":
    raise SystemExit(main())
