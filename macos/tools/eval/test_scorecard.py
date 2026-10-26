"""Pins scorecard.py's transcript parser on both shapes a SelfTest prints: the
single-trial fixture line, and the `[trial n/m]`-prefixed one that a repeats > 1
run prints. The 2026-10-18 card-always run timed out with no JSON, and its
transcript parsed to nothing: the fixture regex knew only the first shape.

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.9, Prior: none (new file).
Review: Kev + claude-opus-5-5, 2026-10-18 — review fold: trial numbers on rows, in the Failures list, and every
trial's answer in "What they actually said".
Review: Kev + claude-fable-5.1, 2026-10-26 — `test_format_is_printed_in_full` (#716): the format kind's answers print
whole, beside humour and interview, because the shape verdict is a read.
"""

from pathlib import Path

import pytest
import scorecard as sc

HERE = Path(__file__).resolve().parent
HAND_WRITTEN = HERE / "sample-transcript.txt"
REPEATS = HERE / "sample-transcript-repeats.txt"


def test_hand_written_sample_still_parses():
    brains, rows = sc.parse(HAND_WRITTEN)
    assert brains == {"mini": "Mini", "big": "Big"}
    assert len(rows) == 8
    _, table, _ = sc.summarise(brains, rows)
    assert table["mini"]["instruction-following"] == [0, 1]
    assert table["big"]["interview"] == [0, 1]


def test_trial_prefixed_lines_parse_from_a_repeats_2_transcript():
    # Real lines from the 2026-10-18 card-always run: four fixtures, both trials each.
    brains, rows = sc.parse(REPEATS)
    assert brains == {"lil": "Lil"}
    assert len(rows) == 8, "every trial is a row, the [trial n/m] prefix and all"
    assert [r["fixture"] for r in rows[:4]] == [
        "reason-age", "reason-hard-bat-ball", "tool-search-notes", "tool-recent-activity"]
    kinds, table, latencies = sc.summarise(brains, rows)
    assert kinds == ["reasoning", "tool-use"]
    assert table["lil"]["reasoning"] == [2, 4]
    assert table["lil"]["tool-use"] == [3, 4]
    assert sorted(latencies["lil"])[:2] == [94178, 106815]


def test_a_trial_row_keeps_its_checks_and_answer():
    _, rows = sc.parse(REPEATS)
    first = rows[0]
    assert (first["fixture"], first["kind"], first["passed"], first["ms"]) == ("reason-age", "reasoning", False, 173649)
    assert first["failed_checks"] == ["responsive — 173649ms > ceiling 120000ms (loop thrash?)"]
    assert first["said"].startswith("Mary is 18.")


@pytest.mark.parametrize(("line", "trial"), [
    ("  reason-age [reasoning]: PASS (94178ms)", None),
    ("  [trial 2/2]   reason-age [reasoning]: PASS (94178ms)", "2"),
    ("  [trial 10/12] reason-age [reasoning]: PASS (94178ms)", "10"),
])
def test_fixture_regex_takes_the_line_with_or_without_a_trial_prefix(line, trial):
    m = sc.FIXTURE.match(line)
    assert m is not None
    assert m.groups() == (trial, "reason-age", "reasoning", "PASS", "94178")


def test_every_row_carries_its_trial_number():
    # Repeats of one fixture are separate rows; without the number a reader (and --json) can't tell them apart.
    _, rows = sc.parse(REPEATS)
    assert [r["trial"] for r in rows] == [1, 1, 1, 1, 2, 2, 2, 2]
    _, single = sc.parse(HAND_WRITTEN)
    assert {r["trial"] for r in single} == {None}, "a single-trial run has no trial number"


def _markdown(path):
    brains, rows = sc.parse(path)
    kinds, table, latencies = sc.summarise(brains, rows)
    return sc.markdown(brains, rows, kinds, table, latencies, path.name)


def test_failures_name_the_trial_that_failed():
    md = _markdown(REPEATS)
    assert "- `reason-age` [reasoning] (trial 1) — responsive" in md
    assert "- `tool-search-notes` [tool-use] (trial 2) — responsive" in md
    assert "(trial" not in _markdown(HAND_WRITTEN), "single-trial output is unchanged"


def test_what_they_said_lists_every_trial(tmp_path):
    # The human-judged section took the FIRST trial's answer and dropped the rest without a word.
    transcript = tmp_path / "humour-x2.txt"
    transcript.write_text(
        "• chateval brain lil (Lil)…\n"
        "  [trial 1/2]   wit-sea-pun [humour]: PASS (100ms)\n"
        "    · said: I'm shore that's funny.\n"
        "  [trial 2/2]   wit-sea-pun [humour]: FAIL (120ms)\n"
        "    ✗ length band — 500 > max 30\n"
        "    · said: Let me explain the sea at length.\n",
        encoding="utf-8")
    md = _markdown(transcript)
    assert "- *Lil* (trial 1): I'm shore that's funny." in md
    assert "- *Lil* (trial 2): Let me explain the sea at length." in md
    assert "- *Mini*: I'm shore that's funny." in _markdown(HAND_WRITTEN), "single-trial lines read as before"


def test_fixture_regex_still_refuses_a_line_that_is_not_a_fixture():
    assert sc.FIXTURE.match("  thinking: always (bare on, live always)") is None
    assert sc.FIXTURE.match("  [trial x/2]   reason-age [reasoning]: PASS (94178ms)") is None


def test_format_is_printed_in_full(tmp_path):
    # #716: the format kind's verdict is by feel (did the shape fit the content?), so its answers print whole.
    transcript = tmp_path / "format-x1.txt"
    transcript.write_text(
        "• chateval brain lil (Lil)…\n"
        "  fmt-compare-drinks [format]: PASS (100ms)\n"
        "    · said: | Drink | Caffeine | |---|---| | Tea | less |\n"
        "  fmt-smalltalk-cork [format]: FAIL (90ms)\n"
        "    ✗ excludes forbidden — leaked [\"**\"]\n"
        "    · said: **Cork** in October is grand.\n",
        encoding="utf-8")
    md = _markdown(transcript)
    assert "#### format" in md
    assert "- *Lil*: | Drink | Caffeine | |---|---| | Tea | less |" in md
    assert "- *Lil*: **Cork** in October is grand." in md
