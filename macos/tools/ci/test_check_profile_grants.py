"""Pins check_profile_grants: every entitlement an app claims beyond the sandbox family must be
granted by its provisioning profile, or AMFI kills the launch (an ungranted capability) or the
keychain refuses it (-34018). #519's second pass asked for it: the "M1K3" profile's grants are read
off the portal, and a regenerated profile that drops one would otherwise fail on a user's Mac.

Signed: Kev + claude-opus-5-5, 2026-10-09, Confidence 0.9. Prior: none (new file).
"""

import check_profile_grants as m

TEAM = "76DJH43A4P"
PROFILE = {  # the "M1K3" Developer ID profile's Entitlements, read 2026-10-09
    "com.apple.application-identifier": "76DJH43A4P.app.m1k3",
    "com.apple.developer.declared-age-range": True,
    "com.apple.developer.team-identifier": "76DJH43A4P",
    "keychain-access-groups": ["76DJH43A4P.*"],
}


def test_the_developer_id_entitlements_file_is_granted():
    source = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.developer.declared-age-range": True,
        "keychain-access-groups": ["$(AppIdentifierPrefix)app.m1k3"],
    }
    assert m.ungranted(source, PROFILE, TEAM) == []


def test_a_signed_app_with_its_identity_is_granted():
    signed = {
        "com.apple.application-identifier": "76DJH43A4P.app.m1k3",
        "com.apple.developer.team-identifier": "76DJH43A4P",
        "keychain-access-groups": ["76DJH43A4P.app.m1k3"],
        "com.apple.security.cs.allow-jit": True,
    }
    assert m.ungranted(signed, PROFILE, TEAM) == []


def test_a_capability_the_profile_lacks_is_named():
    problems = m.ungranted({"com.apple.developer.private-cloud-compute": True}, PROFILE, TEAM)
    assert len(problems) == 1 and "private-cloud-compute" in problems[0]


def test_a_regenerated_profile_without_age_range_fails():
    profile = {k: v for k, v in PROFILE.items() if k != "com.apple.developer.declared-age-range"}
    problems = m.ungranted({"com.apple.developer.declared-age-range": True}, profile, TEAM)
    assert len(problems) == 1 and "declared-age-range" in problems[0]


def test_a_keychain_group_outside_the_profile_wildcard_fails():
    problems = m.ungranted({"keychain-access-groups": ["OTHERTEAM.app.m1k3"]}, PROFILE, TEAM)
    assert len(problems) == 1 and "OTHERTEAM.app.m1k3" in problems[0]


def test_a_wrong_application_identifier_fails():
    problems = m.ungranted({"com.apple.application-identifier": "76DJH43A4P.app.other"}, PROFILE, TEAM)
    assert len(problems) == 1


def test_the_sandbox_family_is_self_granted():
    assert m.ungranted({"com.apple.security.files.user-selected.read-write": True}, {}, TEAM) == []


def test_identifier_prefixes_expand_to_the_team():
    assert m.expand("$(AppIdentifierPrefix)app.m1k3", TEAM) == "76DJH43A4P.app.m1k3"
    assert m.expand("$(TeamIdentifierPrefix)app.m1k3", TEAM) == "76DJH43A4P.app.m1k3"


def test_an_app_group_is_checked_against_the_profile_not_self_granted():
    # com.apple.security.* is the sandbox family, but an app group only counts on macOS 27 when
    # the profile backs it (#518: secd ignored an unbacked group), so it is checked like the rest.
    problems = m.ungranted({"com.apple.security.application-groups": ["76DJH43A4P.app.m1k3"]}, PROFILE, TEAM)
    assert len(problems) == 1 and "application-groups" in problems[0]


def test_unreadable_entitlements_read_as_none_claimed():
    assert m.parse_plist(b"") == {}
