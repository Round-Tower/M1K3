"""Pins for check_wall_clock_bounds — the #296 rule as a guard.

Swift Testing starts every test at once; on the 3-core CI runner a test's
measured wall time is mostly the wait for the shared pool (2026-09-12 master
run: 3,318 of 3,699 tests reported 7-8 s in a 13.4 s run). A bound under 30 s
measures that backlog, not the code.
"""
import check_wall_clock_bounds as m


def test_short_seconds_bound_is_flagged():
    assert m.short_bound("        #expect(clock.now - start < .seconds(4))") == 4.0


def test_milliseconds_bound_is_converted_and_flagged():
    assert m.short_bound("#expect(clock.now - start < .milliseconds(900))") == 0.9


def test_bare_elapsed_number_is_flagged():
    assert m.short_bound("        #expect(elapsed < 10)") == 10.0


def test_thirty_seconds_and_up_passes():
    assert m.short_bound("#expect(start.duration(to: .now) < .seconds(30))") is None
    assert m.short_bound("#expect(elapsed < 300)") is None


def test_allow_marker_exempts_the_line():
    line = '#expect(unwind < .seconds(1)) // wall-clock-ok: opt-in audio test, never in the parallel suite'
    assert m.short_bound(line) is None


def test_comments_and_unrelated_comparisons_are_ignored():
    assert m.short_bound("// the old `< 1.5 s` bound flaked") is None
    assert m.short_bound("#expect(count < 10)") is None
    assert m.short_bound("#expect(pose.elapsed < 10)") is None  # a domain value, not a clock


def test_a_config_value_compared_to_a_duration_is_not_a_clock():
    assert m.short_bound("        #expect(cadence.cadenceCeiling <= .seconds(8))") is None
    assert m.short_bound("#expect(policy.grace < .milliseconds(500))") is None


def test_clock_spellings_on_the_left_are_flagged():
    assert m.short_bound("#expect(ContinuousClock.now - started < .seconds(2), \"closed by the watchdog\")") == 2.0
    assert m.short_bound("#expect(start.duration(to: .now) < .seconds(5))") == 5.0


def test_a_url_in_a_string_does_not_hide_the_bound():
    assert m.short_bound('#expect(clock.now - start < .seconds(2), "see http://example.com")') == 2.0
    assert m.short_bound('#expect(fetch("http://x").elapsed(clock) < .seconds(2))') == 2.0


def test_fully_qualified_duration_is_flagged():
    assert m.short_bound("#expect(clock.now - start < Duration.seconds(2))") == 2.0


def test_clock_named_variables_are_flagged():
    assert m.short_bound("#expect(ContinuousClock.now - startTime < .seconds(3))") == 3.0
    assert m.short_bound("#expect(clockStart.duration(to: .now) < .seconds(3))") == 3.0


def test_a_comparison_split_across_lines_is_judged_whole():
    text = "let x = 1\n#expect(ContinuousClock.now - start\n    < .seconds(2))\nlet y = 2\n"
    assert m.scan({"T.swift": text}) == [("T.swift", 2, 2.0)]


def test_scan_reports_file_and_line():
    hits = m.scan({"Tests/A/ATests.swift": "let a = 1\n#expect(clock.now - start < .seconds(2))\n"})
    assert hits == [("Tests/A/ATests.swift", 2, 2.0)]
