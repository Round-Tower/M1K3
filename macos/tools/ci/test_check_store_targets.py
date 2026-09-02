"""Unit tests for the pure helpers in check_store_targets."""

import check_store_targets as m

TEMPLATE_WITH_MANIFEST = {
    "sources": [
        {"path": "M1K3iOSApp"},
        {"path": "M1K3App/PrivacyInfo.xcprivacy", "buildPhase": "resources"},
    ]
}


def _app(platform, bundle_id, info_path, templates=None, sources=None, type_="application"):
    t = {
        "type": type_,
        "platform": platform,
        "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": bundle_id}},
        "info": {"path": info_path},
    }
    if templates:
        t["templates"] = templates
    if sources:
        t["sources"] = sources
    return t


def _project(targets, templates=None):
    return {"targetTemplates": templates or {}, "targets": targets}


def test_store_targets_keeps_only_store_platform_applications():
    project = _project(
        {
            "M1K3": _app("macOS", "app.m1k3", "M1K3App/Info.generated.plist", sources=[{"path": "M1K3App"}]),
            "M1K3Screensaver": _app("macOS", "app.m1k3.screensaver", "x.plist", type_="bundle"),
            "Helper": _app("watchOS", "app.m1k3", "y.plist"),
        }
    )
    assert set(m.store_targets(project)) == {"M1K3"}


def test_effective_sources_merges_template_and_own_sources_as_paths():
    project = _project(
        {"M1K3iOS": _app("iOS", "app.m1k3", "a.plist", templates=["MobileShell"], sources=["M1K3.icon"])},
        templates={"MobileShell": TEMPLATE_WITH_MANIFEST},
    )
    assert m.effective_sources(project, project["targets"]["M1K3iOS"]) == [
        "M1K3iOSApp",
        "M1K3App/PrivacyInfo.xcprivacy",
        "M1K3.icon",
    ]


def test_bundle_id_drift_is_flagged_by_target_name_and_id():
    project = _project(
        {"M1K3iOS": _app("iOS", "app.m1k3.ios", "a.plist", templates=["MobileShell"])},
        templates={"MobileShell": TEMPLATE_WITH_MANIFEST},
    )
    problems = m.audit(project)
    assert len(problems) == 1
    assert "M1K3iOS" in problems[0] and "app.m1k3.ios" in problems[0] and "app.m1k3" in problems[0]


def test_missing_privacy_manifest_on_a_mobile_target_is_flagged():
    project = _project(
        {"M1K3iOS": _app("iOS", "app.m1k3", "a.plist", templates=["MobileShell"])},
        templates={"MobileShell": {"sources": [{"path": "M1K3iOSApp"}]}},
    )
    problems = m.audit(project)
    assert len(problems) == 1
    assert "PrivacyInfo.xcprivacy" in problems[0] and "M1K3iOS" in problems[0]


def test_mac_target_manifest_is_not_audited():
    # The Mac sweeps its whole directory (the manifest rides along), so the
    # manifest rule is gated to iOS/visionOS — a Mac-only project never trips it.
    project = _project({"M1K3": _app("macOS", "app.m1k3", "m.plist", sources=[{"path": "M1K3App"}])})
    assert m.audit(project) == []


def test_mobile_target_sweeping_the_mac_folder_must_still_name_the_manifest():
    # A wholesale `M1K3App` sweep is never a real mobile config (it would drag
    # every Mac file in), so it earns no exemption: name the manifest or fail.
    project = _project(
        {"M1K3iOS": _app("iOS", "app.m1k3", "a.plist", sources=[{"path": "M1K3App"}])},
    )
    problems = m.audit(project)
    assert len(problems) == 1 and "PrivacyInfo.xcprivacy" in problems[0]


def test_two_targets_sharing_one_generated_info_plist_is_flagged():
    project = _project(
        {
            "M1K3iOS": _app("iOS", "app.m1k3", "M1K3iOSApp/Info.generated.plist", templates=["MobileShell"]),
            "M1K3visionOS": _app("visionOS", "app.m1k3", "M1K3iOSApp/Info.generated.plist", templates=["MobileShell"]),
        },
        templates={"MobileShell": TEMPLATE_WITH_MANIFEST},
    )
    problems = m.audit(project)
    assert len(problems) == 1
    assert "Info.generated.plist" in problems[0]
    assert "M1K3iOS" in problems[0] and "M1K3visionOS" in problems[0]


def test_aligned_project_has_no_problems():
    project = _project(
        {
            "M1K3": _app("macOS", "app.m1k3", "M1K3App/Info.generated.plist", sources=[{"path": "M1K3App"}]),
            "M1K3iOS": _app("iOS", "app.m1k3", "M1K3iOSApp/Info.generated.plist", templates=["MobileShell"]),
            "M1K3visionOS": _app("visionOS", "app.m1k3", "M1K3visionOS/Info.generated.plist", templates=["MobileShell"]),
        },
        templates={"MobileShell": TEMPLATE_WITH_MANIFEST},
    )
    assert m.audit(project) == []
