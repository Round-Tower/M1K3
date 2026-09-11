#!/usr/bin/env python3
"""Fail loudly if a command-line tool is embedded into an app at Contents/MacOS.

Xcode's Code-Sign-On-Copy treats the `executables` destination (Contents/MacOS)
as part of the app's own product: the copied tool is re-signed with the APP's
identifier and the APP's entitlements. Two consequences, both found on
2026-09-11 with the `m1k3` helper: `xcodebuild -exportArchive` (developer-id)
then sees two items called `app.m1k3`, orphans the screensaver, and aborts with
"Must only have one root item when exporting without packaging" — the nightly
DMG dies; and the helper ships sandboxed, so `m1k3 connect` cannot write a
config it was built to write. At `destination: wrapper` + `subpath:
Contents/Helpers` the copy keeps its own identifier and entitlements
(`--preserve-metadata`), the export succeeds, and the per-target entitlement
indirection works as designed.

    python3 check_helper_embed.py [PROJECT_YML]

Defaults to the repo's macos/project.yml. Read-only. The pure helper is
unit-tested in test_check_helper_embed.py; the file I/O + exit wiring is
verify-by-run.

Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.9 (the rule is the
one the export crash proved; the parser is pinned on fixtures). Prior: Unknown
"""
from __future__ import annotations

import os
import sys

import yaml

HELPERS = "Contents/Helpers"

# --------------------------------------------------------------------------- #
# Pure helper (unit-tested)
# --------------------------------------------------------------------------- #


def misplaced_tool_embeds(project: dict) -> list[str]:
    """Every (app → tool) embed that does not land under Contents/Helpers.

    A `tool`-type target embedded by another target must be copied with
    `destination: wrapper` and a `subpath` under Contents/Helpers. Anything
    else — `executables`, a missing copy block, another subpath — is reported
    as "<app> embeds <tool> at <where>".
    """
    targets = project.get("targets") or {}
    tools = {name for name, t in targets.items() if (t or {}).get("type") == "tool"}
    problems: list[str] = []
    for app, spec in targets.items():
        for dep in (spec or {}).get("dependencies") or []:
            if not isinstance(dep, dict) or dep.get("target") not in tools:
                continue
            if not dep.get("embed"):
                continue
            copy = dep.get("copy") or {}
            destination = copy.get("destination", "(no copy block)")
            subpath = str(copy.get("subpath", ""))
            if destination == "wrapper" and (subpath == HELPERS or subpath.startswith(HELPERS + "/")):
                continue
            where = destination if not subpath else f"{destination}/{subpath}"
            problems.append(f"{app} embeds {dep['target']} at {where}")
    return problems


# --------------------------------------------------------------------------- #
# Wiring (verify-by-run)
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    path = argv[1] if len(argv) > 1 else os.path.join(here, "..", "..", "project.yml")
    with open(path, encoding="utf-8") as fh:
        project = yaml.safe_load(fh) or {}
    problems = misplaced_tool_embeds(project)
    if problems:
        print("✗ command-line tools must be embedded at destination: wrapper, subpath: Contents/Helpers")
        for problem in problems:
            print(f"  - {problem}")
        print("  (Contents/MacOS re-signs the tool as the app itself: the developer-id export aborts")
        print("   and the helper inherits the app's entitlements — see the header of this guard.)")
        return 1
    print("✓ every embedded tool lands under Contents/Helpers")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
