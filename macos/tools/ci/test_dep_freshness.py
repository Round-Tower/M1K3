"""Unit tests for the pure helpers in dep_freshness (no network: fetchers are injected)."""

import dep_freshness as m

PACKAGE_SWIFT = """
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.15.0"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.4.1"),
    ],
"""

RESOLVED = {
    "pins": [
        {"identity": "swift-transformers", "location": "https://github.com/huggingface/swift-transformers",
         "state": {"revision": "150169bf", "version": "1.1.9"}},
        {"identity": "whisperkit", "location": "https://github.com/argmaxinc/WhisperKit.git",
         "state": {"revision": "aaaa", "version": "0.18.0"}},
        {"identity": "mlx-swift-lm", "location": "https://github.com/ml-explore/mlx-swift-lm",
         "state": {"revision": "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb"}},
    ]
}


def test_identity_matches_swiftpm():
    assert m.identity("https://github.com/argmaxinc/WhisperKit.git") == "whisperkit"
    assert m.identity("https://github.com/groue/GRDB.swift") == "grdb.swift"
    assert m.owner_repo("https://github.com/argmaxinc/WhisperKit.git") == ("argmaxinc", "WhisperKit")


def test_requirements_parse_every_declaration_form():
    reqs = m.parse_requirements(PACKAGE_SWIFT)
    assert reqs["mlx-swift-lm"] == m.Requirement("revision", "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb")
    assert reqs["mlx-swift"] == m.Requirement("upToNextMinor", "0.31.6")
    assert reqs["swift-transformers"] == m.Requirement("upToNextMinor", "1.1.6")
    assert reqs["swift-sdk"] == m.Requirement("upToNextMajor", "0.7.0")  # `from:` is upToNextMajor
    assert reqs["whisperkit"] == m.Requirement("upToNextMajor", "0.15.0")
    assert reqs["grdb.swift"] == m.Requirement("exact", "7.4.1")


def test_versions_compare_numerically_and_skip_prereleases():
    assert m.parse_version("v1.10.0") > m.parse_version("1.9.4")
    assert m.parse_version("1.3.0-beta.1") is None
    assert m.parse_version("nightly") is None


def test_requirement_ceiling_matches_swiftpm_semantics():
    assert m.Requirement("upToNextMinor", "1.1.6").allows("1.1.9")
    assert not m.Requirement("upToNextMinor", "1.1.6").allows("1.2.0")
    assert m.Requirement("upToNextMajor", "0.15.0").allows("0.18.0")
    assert not m.Requirement("upToNextMajor", "0.15.0").allows("1.0.0")
    assert m.Requirement("exact", "7.4.1").allows("7.4.1")
    assert not m.Requirement("exact", "7.4.1").allows("7.4.2")
    assert m.Requirement("revision", "abc").allows("9.9.9") is None  # a revision has no semver range


def test_capped_by_names_the_dependent_that_holds_a_package_back():
    # Ours lets swift-transformers float to 1.1.x; WhisperKit 0.18's own manifest says the same.
    ours = m.parse_requirements(PACKAGE_SWIFT)
    whisperkit_manifest = """
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.1.6")),
    """
    caps = m.capped_by(
        "swift-transformers", "1.3.4", ours=ours,
        dependents={"whisperkit": m.parse_requirements(whisperkit_manifest)},
    )
    assert caps == ["M1K3 (upToNextMinor 1.1.6)", "whisperkit (upToNextMinor 1.1.6)"]
    assert m.capped_by("swift-transformers", "1.1.9", ours=ours, dependents={}) == []


def test_highlights_pick_the_lines_that_matter_from_missed_releases():
    releases = [
        m.Release("1.3.2", "2026-05-06", "Speed up BPE merge with priority-queue algorithm (5-12x on inner loop) (#346)\nDocs typo"),
        m.Release("1.3.4", "2026-09-02", "Fix crash when tokenizer.json has no merges\nBump CI"),
        m.Release("1.1.9", "2026-03-02", "Faster everything"),  # not missed: we're on it
    ]
    lines = m.highlights(releases, current="1.1.9")
    assert lines == [
        "1.3.2: Speed up BPE merge with priority-queue algorithm (5-12x on inner loop) (#346)",
        "1.3.4: Fix crash when tokenizer.json has no merges",
    ]


def test_report_rows_for_a_resolved_tree():
    releases = {
        "swift-transformers": [m.Release("1.3.4", "2026-09-02", ""), m.Release("1.2.0", "2026-03-09", ""),
                               m.Release("1.1.9", "2026-03-02", "")],
        "whisperkit": [m.Release("1.1.0", "2026-08-06", ""), m.Release("0.18.0", "2026-04-01", "")],
        "mlx-swift-lm": [m.Release("3.32.3", "2026-09-30", "")],
    }
    rows = m.build_rows(
        RESOLVED, m.parse_requirements(PACKAGE_SWIFT),
        releases=lambda ident, _url: releases.get(ident, []),
        dependent_manifest=lambda ident, _url, _version: (
            '.package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.1.6"))'
            if ident == "whisperkit" else ""
        ),
        commits_behind=lambda _url, rev: 20 if rev.startswith("ee673d6a") else None,
    )
    by = {r.identity: r for r in rows}
    st = by["swift-transformers"]
    assert (st.current, st.latest, st.behind) == ("1.1.9", "1.3.4", 2)
    assert st.capped == ["M1K3 (upToNextMinor 1.1.6)", "whisperkit (upToNextMinor 1.1.6)"]
    wk = by["whisperkit"]
    assert (wk.current, wk.latest, wk.behind) == ("0.18.0", "1.1.0", 1)
    assert wk.capped == ["M1K3 (upToNextMajor 0.15.0)"]
    lm = by["mlx-swift-lm"]
    assert lm.current.startswith("ee673d6a") and lm.commits_behind == 20 and lm.latest == "3.32.3"


def test_capped_rows_are_what_fail_if_capped_counts():
    rows = [
        m.Row("a", "1.0.0", "1.0.0", 0, [], [], None),
        m.Row("b", "1.0.0", "2.0.0", 3, ["M1K3 (upToNextMajor 1.0.0)"], [], None),
    ]
    assert [r.identity for r in m.capped_rows(rows)] == ["b"]


def test_markdown_puts_capped_packages_first_with_their_blocker_and_notes():
    rows = [
        m.Row("swift-log", "1.13.1", "1.16.0", 5, [], [], None),
        m.Row("swift-transformers", "1.1.9", "1.3.4", 7, ["whisperkit (upToNextMinor 1.1.6)"],
              ["1.3.2: Speed up BPE merge (5-12x)"], None),
        m.Row("mlx-swift-lm", "ee673d6a", "3.32.3", 0, [], [], 23),
        m.Row("grdb.swift", "7.11.1", "7.11.1", 0, [], [], None),  # current: left out
    ]
    md = m.render_markdown(rows, generated="2026-10-07")
    lines = md.splitlines()
    table = [ln for ln in lines if ln.startswith("| ") and not ln.startswith("| package") and not ln.startswith("|---")]
    assert [ln.split("|")[1].strip() for ln in table] == ["`swift-transformers`", "`swift-log`", "`mlx-swift-lm`"]
    assert "**whisperkit (upToNextMinor 1.1.6)**" in md
    assert "- `swift-transformers` 1.3.2: Speed up BPE merge (5-12x)" in md
    assert "23 commits" in md
    assert "grdb.swift" not in md
    assert "2026-10-07" in md
