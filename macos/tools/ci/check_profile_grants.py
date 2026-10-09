#!/usr/bin/env python3
"""Fail when an app claims an entitlement its provisioning profile doesn't grant.

Beyond the sandbox family (`com.apple.security.*`, which an app grants itself), every
entitlement needs the profile's say-so: an ungranted capability gets the launch killed by
AMFI, and an ungranted keychain group gets every save refused (-34018). The Developer ID
lane's grants are read off the developer portal (the "M1K3" profile, #518/#519), so a
regenerated profile that drops one would otherwise surface on a user's Mac, after release.

Two call sites, both failing closed:
    # the nightly, right after installing the profile secret: the source entitlements
    check_profile_grants.py --profile P --entitlements macos/M1K3App/M1K3.entitlements --team T
    # release-macos.sh, after export: what was actually signed against what was embedded
    check_profile_grants.py --profile APP/Contents/embedded.provisionprofile --app APP --team T

The pure half (`ungranted`, `expand`) is pinned in test_check_profile_grants.py; the
`security` / `codesign` reads are verify-by-run.

Signed: Kev + claude-opus-5-5, 2026-10-09, Confidence 0.85 (the rule is pinned; that it
matches AMFI's own judgement is checked against the live profile and signed app). Prior: none.
"""
from __future__ import annotations

import argparse
import fnmatch
import plistlib
import subprocess
import sys

SELF_GRANTED_PREFIX = "com.apple.security."
# In the sandbox family by name, but only real when the profile backs it: on macOS 27 secd ignores
# an app group a profile doesn't grant (#518), so it is checked like everything else.
PROFILE_BACKED = {"com.apple.security.application-groups"}


def self_granted(key: str) -> bool:
    return key.startswith(SELF_GRANTED_PREFIX) and key not in PROFILE_BACKED


def expand(value, team: str):
    """Xcode's identifier prefixes as signing expands them."""
    if not isinstance(value, str):
        return value
    return value.replace("$(AppIdentifierPrefix)", f"{team}.").replace("$(TeamIdentifierPrefix)", f"{team}.")


def _granted(value, allowed) -> bool:
    # A boolean claim: False claims nothing, so it always passes; True needs the profile's True.
    # A boolean on only one side (a string claim against a True grant, or the reverse) fails closed.
    if isinstance(value, bool) or isinstance(allowed, bool):
        return value is False or value is allowed
    return isinstance(value, str) and isinstance(allowed, str) and fnmatch.fnmatchcase(value, allowed)


def ungranted(app: dict, profile: dict, team: str) -> list[str]:
    problems = []
    for key, wanted in sorted(app.items()):
        if self_granted(key):
            continue
        if key not in profile:
            problems.append(f"{key}: the profile doesn't grant it")
            continue
        allowed = profile[key] if isinstance(profile[key], list) else [profile[key]]
        for value in wanted if isinstance(wanted, list) else [wanted]:
            value = expand(value, team)
            if not any(_granted(value, a) for a in allowed):
                problems.append(f"{key}: {value!r} isn't granted (the profile allows {allowed})")
    return problems


def parse_plist(data: bytes) -> dict:
    """codesign prints nothing for an app with no entitlements: that claims none."""
    return plistlib.loads(data) if data.strip() else {}


def _plist(command: list[str]) -> dict:
    return parse_plist(subprocess.run(command, check=True, capture_output=True).stdout)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--profile", required=True, help="a .provisionprofile")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", help="a signed .app: check what it was signed with")
    source.add_argument("--entitlements", help="an .entitlements plist: check what it asks for")
    parser.add_argument("--team", required=True, help="the team id the identifier prefixes expand to")
    args = parser.parse_args(argv)

    try:
        profile = _plist(["security", "cms", "-D", "-i", args.profile]).get("Entitlements", {})
        if args.app:
            app = _plist(["codesign", "-d", "--entitlements", "-", "--xml", args.app])
        else:
            with open(args.entitlements, "rb") as f:
                app = plistlib.load(f)
    except subprocess.CalledProcessError as error:
        print(f"✗ couldn't read {error.cmd[0]}'s answer: {error.stderr.decode(errors='replace').strip()}")
        return 2
    except (OSError, plistlib.InvalidFileException) as error:
        print(f"✗ couldn't read the profile or entitlements: {error}")
        return 2
    if problems := ungranted(app, profile, args.team):
        print("✗ the provisioning profile doesn't grant what the app claims:")
        for problem in problems:
            print(f"   - {problem}")
        return 1
    print(f"✓ the profile grants all {sum(not self_granted(k) for k in app)} non-sandbox entitlements")
    return 0


if __name__ == "__main__":
    sys.exit(main())
