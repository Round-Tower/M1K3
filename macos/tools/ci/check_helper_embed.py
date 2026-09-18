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
Review: Kev + claude-fable-5.1, 2026-09-18, Confidence 0.9 — a SECOND rule,
`tools_without_embedded_plist`: an embedded tool must put an Info.plist INSIDE
its binary (CREATE_INFOPLIST_SECTION_IN_BINARY + a plist to embed). A sandboxed
command-line tool with no `__TEXT,__info_plist` section has no bundle id for
the sandbox to build a container from, and libsystem_secinit traps before
main() — exit 133, zero bytes of output. Proven on a real distribution
build: 362 (in App Review for 1.0.0, on TestFlight) — its helper died that way on every invocation
(`--help` included), while the unsandboxed DMG copy — the only one ever run —
worked. Required of every embedded tool, sandboxed today or not: the
entitlements are a build-time indirection, so the binary must be safe under
either set.
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


def _is_yes(value: object) -> bool:
    """xcodegen settings arrive as YAML: a bare YES is a bool, a quoted one a str."""
    return value is True or str(value).strip().upper() == "YES"


def tools_without_embedded_plist(project: dict) -> list[str]:
    """Every EMBEDDED tool whose binary would carry no Info.plist section.

    Reports "<tool>: <what is missing>" for each gap: the section flag itself,
    and something for it to embed (a generated plist or an INFOPLIST_FILE).
    Settings are read from `settings.base`, or flat `settings` when there is no
    base block. NOT read: `settings.configs.<Name>` — a tool that set these two
    per configuration would be reported as missing them (a false alarm, never a
    false pass; the trap is per-binary, so `base` is where they belong). A tool
    nobody embeds is not shipped inside an app, so it is not this guard's business.
    """
    targets = project.get("targets") or {}
    tools = {name for name, t in targets.items() if (t or {}).get("type") == "tool"}
    embedded = {
        dep["target"]
        for spec in targets.values()
        for dep in (spec or {}).get("dependencies") or []
        if isinstance(dep, dict) and dep.get("target") in tools and dep.get("embed")
    }
    problems: list[str] = []
    for name in sorted(embedded):
        settings = (targets[name] or {}).get("settings") or {}
        base = settings.get("base") if isinstance(settings.get("base"), dict) else settings
        if not _is_yes(base.get("CREATE_INFOPLIST_SECTION_IN_BINARY")):
            problems.append(f"{name}: CREATE_INFOPLIST_SECTION_IN_BINARY is not YES")
        if not (_is_yes(base.get("GENERATE_INFOPLIST_FILE")) or base.get("INFOPLIST_FILE")):
            problems.append(f"{name}: no Info.plist to embed (GENERATE_INFOPLIST_FILE: YES or an INFOPLIST_FILE)")
    return problems


# --------------------------------------------------------------------------- #
# Wiring (verify-by-run)
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    path = argv[1] if len(argv) > 1 else os.path.join(here, "..", "..", "project.yml")
    with open(path, encoding="utf-8") as fh:
        project = yaml.safe_load(fh) or {}
    failed = False
    problems = misplaced_tool_embeds(project)
    if problems:
        failed = True
        print("✗ command-line tools must be embedded at destination: wrapper, subpath: Contents/Helpers")
        for problem in problems:
            print(f"  - {problem}")
        print("  (Contents/MacOS re-signs the tool as the app itself: the developer-id export aborts")
        print("   and the helper inherits the app's entitlements — see the header of this guard.)")
    else:
        print("✓ every embedded tool lands under Contents/Helpers")
    missing = tools_without_embedded_plist(project)
    if missing:
        failed = True
        print("✗ an embedded command-line tool must carry an Info.plist section in its binary")
        for problem in missing:
            print(f"  - {problem}")
        print("  (a SANDBOXED tool with no bundle id traps in libsystem_secinit before main():")
        print("   exit 133, no output — the 1.0.0 review build's `m1k3` carried exactly this.)")
    else:
        print("✓ every embedded tool carries an Info.plist section")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
