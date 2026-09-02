#!/usr/bin/env python3
"""Fail loudly if a store-bound app target in project.yml drifts off the shared record.

M1K3 ships to ONE App Store record — bundle ID `app.m1k3`, registered UNIVERSAL —
for macOS + iOS + visionOS (universal purchase: one listing, one rating pool).
Xcode Cloud archives each platform's target and uploads under whatever
PRODUCT_BUNDLE_IDENTIFIER that target declares; an identifier with no record
behind it fails only AT UPLOAD, after the full build, in a message that names
neither file nor line (the 2026-09-01 TestFlight resurrection found 52 days of
exactly this class of silent rot). Separately, Apple rejects any iOS/visionOS
binary without a PrivacyInfo.xcprivacy at the bundle root — and the mobile
targets don't sweep `M1K3App/`, they cherry-pick, so the manifest only ships if
someone lists it. This guard pins both invariants, plus a third that stops the
two mobile targets writing the same generated Info.plist, and exits non-zero on
ANY divergence — seconds in CI instead of a failed cloud run. Sibling of
check_test_scheme.py / check_doc_drift.py.

    python3 check_store_targets.py [PROJECT_YML]

Needs PyYAML (`python3 -m pip install pyyaml`). The pure helpers are unit-tested
in test_check_store_targets.py; the file I/O + exit wiring is verify-by-run.

Signed: Kev + claude-fable-5.1, 2026-09-02, Confidence 0.85 (the invariants are
read off the live ASC record + developer portal via the API the same day;
project.yml's target/template shape is the one xcodegen documents). Prior: none.
"""
from __future__ import annotations

import os
import sys

EXPECTED_BUNDLE_ID = "app.m1k3"
STORE_PLATFORMS = {"macOS", "iOS", "visionOS"}
MANIFEST = "PrivacyInfo.xcprivacy"

# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def store_targets(project: dict) -> dict[str, dict]:
    """The `application` targets on a platform that ships through App Store Connect."""
    return {
        name: t
        for name, t in (project.get("targets") or {}).items()
        if t.get("type") == "application" and t.get("platform") in STORE_PLATFORMS
    }


def _paths(entries) -> list[str]:
    out: list[str] = []
    for e in entries or []:
        if isinstance(e, str):
            out.append(e)
        elif isinstance(e, dict) and e.get("path"):
            out.append(str(e["path"]))
    return out


def effective_sources(project: dict, target: dict) -> list[str]:
    """Source paths a target ends up with: its templates' (in order) then its own."""
    templates = project.get("targetTemplates") or {}
    paths: list[str] = []
    for tname in target.get("templates") or []:
        paths += _paths((templates.get(tname) or {}).get("sources"))
    paths += _paths(target.get("sources"))
    return paths


def bundle_id(target: dict) -> str | None:
    return ((target.get("settings") or {}).get("base") or {}).get("PRODUCT_BUNDLE_IDENTIFIER")


def info_path(target: dict) -> str | None:
    return (target.get("info") or {}).get("path")


def _carries_manifest(paths: list[str]) -> bool:
    # Mobile targets cherry-pick from M1K3App/, so the manifest ships only if a
    # source entry names it. (The Mac target sweeps its whole directory and is
    # not audited for the manifest at all — see the platform gate in audit().)
    return any(p.endswith(MANIFEST) for p in paths)


def audit(project: dict) -> list[str]:
    """Every way the store targets diverge from the one shared record. Empty = aligned."""
    problems: list[str] = []
    targets = store_targets(project)
    for name, t in targets.items():
        bid = bundle_id(t)
        if bid != EXPECTED_BUNDLE_ID:
            problems.append(
                f"{name}: PRODUCT_BUNDLE_IDENTIFIER is {bid!r}, must be {EXPECTED_BUNDLE_ID!r} "
                f"(the one universal App Store record — a per-platform ID has no record to upload into)"
            )
        if t.get("platform") in {"iOS", "visionOS"} and not _carries_manifest(effective_sources(project, t)):
            problems.append(
                f"{name}: no {MANIFEST} in its sources (template or own) — Apple rejects "
                f"iOS/visionOS submissions without a privacy manifest at the bundle root"
            )
    by_plist: dict[str, list[str]] = {}
    for name, t in targets.items():
        p = info_path(t)
        if p:
            by_plist.setdefault(p, []).append(name)
    for p, names in sorted(by_plist.items()):
        if len(names) > 1:
            problems.append(
                f"{' + '.join(sorted(names))} share one generated Info.plist ({p}) — "
                f"whichever xcodegen writes last clobbers the other's keys"
            )
    return problems


# --------------------------------------------------------------------------- #
# I/O (verify-by-run)
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    try:
        import yaml  # type: ignore
    except ImportError:
        print("❌ check_store_targets needs PyYAML: python3 -m pip install pyyaml")
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    macos = os.path.dirname(os.path.dirname(here))
    path = argv[1] if len(argv) > 1 else os.path.join(macos, "project.yml")
    with open(path) as f:
        project = yaml.safe_load(f)
    problems = audit(project)
    names = sorted(store_targets(project))
    if not problems:
        print(f"✓ {len(names)} store targets ({', '.join(names)}) all upload into {EXPECTED_BUNDLE_ID!r} "
              f"with a privacy manifest and their own Info.plist.")
        return 0
    print("❌ project.yml store-target drift:")
    for p in problems:
        print(f"   - {p}")
    print("\nFix: see the comments on the M1K3iOS target in macos/project.yml.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
