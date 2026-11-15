#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""App Store accessibility labels (Accessibility Nutrition Labels), per device family.

The claims live in `accessibility_labels.json`, reviewed in git, each with its evidence.
Only `declare` is sent as supported; `pending` and `no` go as not supported, and `n/a`
(a feature ASC refuses for that device family, e.g. Larger Text on MAC) is left out. `set` is a
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
Review: Kev + claude-opus-5.5, 2026-11-15 — the first --confirm (Kev: "Please run it pal")
published IPHONE and IPAD and read them back; MAC drew a 409 (supportsLargerText cannot be
set for MAC), so a fourth status, n/a, leaves an attribute out of the body. Confidence 0.85:
the write path is proven on two families; MAC's other eight attributes are unproven until
its write.
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
from asc import APP_ID, bail, call, paginate

SPEC = Path(__file__).resolve().parent / "accessibility_labels.json"
TYPE = "accessibilityDeclarations"
DEVICE_FAMILIES = ("IPHONE", "IPAD", "APPLE_TV", "APPLE_WATCH", "MAC", "VISION")
STATUSES = ("declare", "pending", "no", "n/a")
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


def load_spec(path: Path | None = None) -> dict[str, dict[str, dict[str, str]]]:
    """The spec without its `_about`, refused whole if a family, feature or status is off."""
    path = path or SPEC
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
    """Every applicable feature as supported or not. `n/a` is absent: ASC refuses the
    attribute for that family even as false (409, supportsLargerText on MAC, 2026-11-15)."""
    return {ATTRIBUTE[f]: claims[f]["status"] == "declare" for f in FEATURES if claims[f]["status"] != "n/a"}


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


def _live_attrs(item: dict[str, Any], keys: dict[str, bool]) -> dict[str, bool]:
    """The live declaration over the same attributes the spec sends (n/a ones dropped)."""
    a = item["attributes"]
    return {k: bool(a.get(k)) for k in keys}


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
        elif published is not None and _live_attrs(published, attrs) == attrs:
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


NEW_ID = "<new draft id>"


def requests_for(step: Step, publish: bool) -> list[tuple[str, str, dict[str, Any]]]:
    """The writes one step makes, in order: what the dry run prints and --confirm sends.
    A create that publishes PATCHes the new draft with the full attributes plus publish,
    so the second request never relies on a partial body."""
    if step.action == "same":
        return []
    if step.action == "create":
        reqs = [("POST", f"/v1/{TYPE}", create_body(step.family, step.attrs))]
        if publish:
            reqs.append(("PATCH", f"/v1/{TYPE}/{NEW_ID}", update_body(NEW_ID, step.attrs, publish=True)))
        return reqs
    draft = step.draft_id or ""
    return [("PATCH", f"/v1/{TYPE}/{draft}", update_body(draft, step.attrs, publish))]


def fetch_live() -> list[dict[str, Any]]:
    try:
        items = list(paginate(f"/v1/apps/{APP_ID}/{TYPE}?limit=50"))
    except RuntimeError as exc:
        raise SystemExit(f"FAILED at read declarations: {exc}") from exc
    return [d for d in items if d.get("attributes", {}).get("deviceFamily") and d["attributes"].get("state")]


def show() -> int:
    live = fetch_live()
    if not live:
        print("no accessibility declarations on the record")
    for item in sorted(live, key=lambda d: (d["attributes"]["deviceFamily"], d["attributes"]["state"])):
        a = item["attributes"]
        yes = [f for f in FEATURES if a.get(ATTRIBUTE[f])]
        print(f"{a['deviceFamily']:8} {a['state']:9} {item['id']}  {', '.join(yes) or '(none supported)'}")
    return 0


def describe(step: Step) -> str:
    yes = [f for f in FEATURES if step.attrs.get(ATTRIBUTE[f])]
    what = {"create": "create a draft", "update": f"edit draft {step.draft_id}",
            "same": "already published as the spec says; nothing to send"}[step.action]
    return f"{step.family}: {what}  declare: {', '.join(yes) or '(none)'}  pending: {', '.join(step.pending) or '(none)'}"


def set_labels(families: list[str], publish: bool, confirm: bool, allow_pending: str | None) -> int:
    if not families:
        raise SystemExit("--family names no device family")
    steps = plan(load_spec(), fetch_live(), families)
    for s in steps:
        print(describe(s))
    why = refusal(steps, allow_pending)
    if not confirm:
        for s in steps:
            for method, path, body in requests_for(s, publish):
                print(f"{method} {path} {json.dumps(body)}")
        print(f"(dry run{'; --confirm would refuse: ' + why if why else ''})")
        return 0
    if why:
        print(f"REFUSED: {why}", file=sys.stderr)
        return 3
    for s in steps:
        new_id: str | None = None
        for method, path, body in requests_for(s, publish):
            if new_id is not None:
                path = path.replace(NEW_ID, new_id)
                body = json.loads(json.dumps(body).replace(NEW_ID, new_id))
            resp = call(method, path, json=body)
            if "_error" in resp:
                left = f" (draft {new_id} was created and is left as DRAFT; a rerun edits it)" if new_id else ""
                bail(f"{method} {s.family}{left}", resp)
            if method == "POST":
                new_id = resp["data"]["id"]
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
