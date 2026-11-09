from pathlib import Path

import launch_check as lc


def test_check_store_reads_version_and_ratings():
    lookup = {"results": [{"version": "1.3", "averageUserRating": 3.0, "userRatingCount": 1}]}
    checks = lc.check_store(lookup)
    assert checks[0].ok and checks[0].actual == "1.3"
    assert checks[1].actual == "1 × 3.0" and checks[1].ok


def test_check_store_flags_a_new_version():
    checks = lc.check_store({"results": [{"version": "1.3.1"}]})
    assert not checks[0].ok


def test_check_issues_requires_open():
    checks = lc.check_issues({"179": "OPEN", "111": "CLOSED"})
    assert [c.ok for c in checks] == [True, False]


def test_check_counts_tolerates_small_test_drift_only():
    ok = lc.check_counts(lc.EXPECTED["tests.count"] + 40, 33, 18)
    assert all(c.ok for c in ok)
    bad = lc.check_counts(lc.EXPECTED["tests.count"] + 400, 32, 17)
    assert [c.ok for c in bad] == [False, False, False]


def test_count_tests_and_targets_and_tools(tmp_path: Path):
    (tmp_path / "A.swift").write_text("@Test func a() {}\n  @Test(\"b\") func b() {}\n// @Test in a comment\n")
    assert lc.count_tests(tmp_path) == 2
    pkg = tmp_path / "Package.swift"
    pkg.write_text(".target(name: \"A\"),\n.executableTarget(name: \"B\"),\n.testTarget(name: \"ATests\"),\n")
    assert lc.count_targets(pkg) == 2
    kit = tmp_path / "kit"; kit.mkdir()
    (kit / "T.swift").write_text('Tool(\n  name: "speak",\n  name: "listen"\n)\nlet x = "name: \\"nope\\""\n')
    assert lc.count_mcp_tools(kit) == 2


def test_render_marks_drift():
    out = lc.render([lc.Check("a", "1", "1", True), lc.Check("bb", "2", "3", False, "note")])
    assert out.splitlines()[0].startswith("✓ a ")
    assert out.splitlines()[1].startswith("✗ bb")
    assert "note" in out


def test_repo_root_is_the_checkout_not_a_tools_folder():
    # The script moved from scratch/ (two levels down) to macos/tools/site/ (three): a wrong depth
    # would count zero tests and report it as drift.
    assert (lc.REPO / "macos" / "Package.swift").is_file()
    assert (lc.REPO / "macos" / "tools" / "asc" / "events.py").is_file()


def test_the_tree_still_matches_what_the_checks_can_read():
    # Not the posts' numbers (those drift by design): only that each reader finds something.
    assert lc.count_tests(lc.REPO / "macos" / "Tests") > 1000
    assert lc.count_targets(lc.REPO / "macos" / "Package.swift") > 10
    assert lc.count_mcp_tools(lc.REPO / "macos" / "Sources" / "M1K3MCPKit") > 5


def test_event_check_reads_the_state_column():
    out = ("6822718507  PAST               SPECIAL_EVENT  halloween-2026  a → b\n"
           "6828149706  PUBLISHED          SPECIAL_EVENT  offline-ai-flight-club-2026  a → b\n")
    assert lc.event_check(0, out).ok
    assert lc.event_check(0, out).actual == "PUBLISHED"
    ended = lc.event_check(0, out.replace("PUBLISHED", "PAST     "))
    assert not ended.ok and ended.actual == "PAST"


def test_event_check_a_failed_read_is_a_skip_and_a_missing_event_is_drift():
    skipped = lc.event_check(1, "")
    assert skipped.ok and skipped.actual == "skipped (exit 1)"
    missing = lc.event_check(0, "6822718507  PAST  SPECIAL_EVENT  halloween-2026\n")
    assert not missing.ok and missing.actual == "not found"
