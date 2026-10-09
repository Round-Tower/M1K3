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
Review: Kev + claude-opus-5-5, 2026-10-09 — the Developer ID lane must carry the keychain group
its Developer ID profile grants (its macOS 27 keychain identity). Confidence 0.85 (verified by
launch: profile embedded, no -34018, MCP listening on 4242).
"""
from __future__ import annotations

import os
import plistlib
import sys

EXPECTED_BUNDLE_ID = "app.m1k3"
STORE_PLATFORMS = {"macOS", "iOS", "visionOS"}
MANIFEST = "PrivacyInfo.xcprivacy"
# ITMS-90474: an iPad-capable app that doesn't opt out of multitasking must
# declare ALL FOUR orientations for iPad, or App Store Connect rejects the
# upload — after the archive and export both succeed (Xcode Cloud run #272).
ALL_ORIENTATIONS = {
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
}

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


def _setting(target: dict, key: str):
    return ((target.get("settings") or {}).get("base") or {}).get(key)


def _info_prop(target: dict, key: str):
    return ((target.get("info") or {}).get("properties") or {}).get(key)


def _as_set(value) -> set[str] | None:
    if value is None:
        return None
    if isinstance(value, str):
        return set(value.split())
    return {str(v) for v in value}


def ipad_orientations(target: dict) -> set[str] | None:
    """The orientations an iPad build ends up declaring, or None if none at all.

    Build settings win over plist properties (that is how Xcode's generated plist
    behaves); the `~ipad`/`_iPad` variant wins over the shared key.
    """
    for value in (
        _setting(target, "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"),
        _info_prop(target, "UISupportedInterfaceOrientations~ipad"),
        _setting(target, "INFOPLIST_KEY_UISupportedInterfaceOrientations"),
        _info_prop(target, "UISupportedInterfaceOrientations"),
    ):
        got = _as_set(value)
        if got:
            return got
    return None


def requires_full_screen(target: dict) -> bool:
    # Escape hatch as accepted by TODAY's ASC upload validator (altool, 2026-09):
    # opting out of iPad multitasking waives the four-orientation rule. App Review
    # has signalled UIRequiresFullScreen is being phased out, so this is not a
    # permanent green light — none of our targets lean on it.
    value = _setting(target, "INFOPLIST_KEY_UIRequiresFullScreen")
    if value is None:
        value = _info_prop(target, "UIRequiresFullScreen")
    return str(value).upper() in {"YES", "TRUE", "1"}


def _carries_manifest(paths: list[str]) -> bool:
    # Mobile targets cherry-pick from M1K3App/, so the manifest ships only if a
    # source entry names it. (The Mac target sweeps its whole directory and is
    # not audited for the manifest at all — see the platform gate in audit().)
    return any(p.endswith(MANIFEST) for p in paths)


def project_archs(project: dict) -> str | None:
    """The project-wide ARCHS base setting, or None."""
    return ((project.get("settings") or {}).get("base") or {}).get("ARCHS")


def audit(project: dict) -> list[str]:
    """Every way the store targets diverge from the one shared record. Empty = aligned."""
    problems: list[str] = []
    archs = project_archs(project)
    if archs != "arm64":
        problems.append(
            f"settings.base.ARCHS is {archs!r}, must be 'arm64' — every brain is Apple-Silicon-only; "
            f"an Intel slice installs but cannot think (#340)"
        )
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
        if t.get("platform") == "iOS" and not requires_full_screen(t):
            got = ipad_orientations(t) or set()
            if got != ALL_ORIENTATIONS:
                problems.append(
                    f"{name}: iPad orientations are {sorted(got) or 'unset'} — ITMS-90474 rejects the upload "
                    f"unless all four are declared (INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad) "
                    f"or the target sets UIRequiresFullScreen"
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


# Entitlements kept to the store lanes on purpose. Until 2026-10-09 the Developer ID lane
# (M1K3App/M1K3.entitlements) had no profile, and AMFI refused to launch an app claiming one of
# these: every DMG and cask install died. Its Developer ID profile ("M1K3", read 2026-10-09)
# grants the App ID's identity, its keychain group and Declared Age Range, but not PCC, so PCC
# would still be killed there; age range stays store-only until that's chosen deliberately.
PROFILE_ONLY_ENTITLEMENTS = (
    "com.apple.developer.private-cloud-compute",
    # Declared Age Range (2026-10-01): an App ID capability, so a profile carries it.
    "com.apple.developer.declared-age-range",
)


def profile_only_leaks(developer_id_entitlements: dict) -> list[str]:
    return [
        f"M1K3.entitlements (Developer ID) claims {key} — store lane only (M1K3-MAS.entitlements)"
        for key in PROFILE_ONLY_ENTITLEMENTS
        if key in developer_id_entitlements
    ]


# The Developer ID lane's keychain identity. macOS 27 routes every keychain call to the
# data-protection keychain ("System Keychain Always"), which secd opens only to a client with a
# profile-backed identity. The Developer ID lane had none, so secd refused the MCP token's save
# (-34018) and the DMG/cask build never started its MCP server (2026-10-08); a team-prefixed app
# group alone was ignored ("incorrect provisioning profile", 2026-10-09). So the lane asks for
# the keychain group its Developer ID profile grants (release-macos.sh embeds the profile). It is
# the store lanes' default group too (their application identifier), so both share one keychain.
DEVELOPER_ID_KEYCHAIN_GROUP = "$(AppIdentifierPrefix)app.m1k3"


def developer_id_keychain_gaps(developer_id_entitlements: dict) -> list[str]:
    if DEVELOPER_ID_KEYCHAIN_GROUP in (developer_id_entitlements.get("keychain-access-groups") or []):
        return []
    return [
        f"M1K3.entitlements (Developer ID) lacks keychain-access-groups {DEVELOPER_ID_KEYCHAIN_GROUP} — on "
        "macOS 27 its keychain is the data-protection one, and without that identity every save fails -34018"
    ]


# Entitlements every store lane must carry: a feature App Review is pointed at
# that silently does nothing without one. Build 375 shipped Content Controls with
# no declared-age-range entitlement, so the Mac's "Set up" never showed a sheet.
STORE_LANE_REQUIRED_ENTITLEMENTS = ("com.apple.developer.declared-age-range",)
STORE_LANE_ENTITLEMENTS = ("M1K3App/M1K3-MAS.entitlements", "M1K3iOSApp/M1K3iOS.entitlements")


def store_lane_gaps(name: str, store_entitlements: dict) -> list[str]:
    return [
        f"{name} (store lane) is missing {key} — the feature it gates does nothing without it"
        for key in STORE_LANE_REQUIRED_ENTITLEMENTS
        if store_entitlements.get(key) is not True
    ]


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
    with open(os.path.join(macos, "M1K3App", "M1K3.entitlements"), "rb") as f:
        developer_id = plistlib.load(f)
    problems += profile_only_leaks(developer_id)
    problems += developer_id_keychain_gaps(developer_id)
    for lane in STORE_LANE_ENTITLEMENTS:
        with open(os.path.join(macos, lane), "rb") as f:
            problems += store_lane_gaps(os.path.basename(lane), plistlib.load(f))
    names = sorted(store_targets(project))
    if not problems:
        print(f"✓ {len(names)} store targets ({', '.join(names)}) all upload into {EXPECTED_BUNDLE_ID!r} "
              f"with a privacy manifest and their own Info.plist; the iOS target declares its iPad orientations.")
        return 0
    print("❌ project.yml store-target drift:")
    for p in problems:
        print(f"   - {p}")
    print("\nFix: see the comments on the M1K3iOS target in macos/project.yml.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
