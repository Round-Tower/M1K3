"""Pins ratings_report.py: the off-phone read of answer ratings (Kev, 2026-10-13).

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9. Prior: none (new file).
"""

import json
import os

import ratings_report as rr


def _line(verdict, brain="Lil", tools=(), comment=None, question="Q?", rated_at="2026-10-13T20:00:00Z"):
    row = {"message_id": f"id-{question}-{rated_at}", "conversation_id": "c", "verdict": verdict,
           "rated_at": rated_at, "brain": brain, "question": question, "answer": "A.", "tools_used": list(tools)}
    if comment is not None:
        row["comment"] = comment
    return json.dumps(row, sort_keys=True)


EXPORT = "\n".join([
    _line("good", brain="Lil", tools=["web_search"], question="Weather in Cork?", rated_at="2026-10-13T19:00:00Z"),
    _line("bad", brain="Lil", comment="should have searched the web", question="Who won last night?",
          rated_at="2026-10-13T21:00:00Z"),
    _line("bad", brain="Mini", question="What's 2+2?", rated_at="2026-10-13T20:00:00Z"),
    _line("bad", brain="Lil", tools=["web_search"], comment="wrong source", question="Price of BTC?",
          rated_at="2026-10-13T22:00:00Z"),
])


def test_summary_counts_and_rates():
    s = rr.summarise(rr.f2f.rows_from_jsonl(EXPORT))
    assert (s.total, s.good, s.bad) == (4, 1, 3)
    assert s.first == "2026-10-13T19:00:00Z" and s.last == "2026-10-13T22:00:00Z"


def test_by_brain_puts_the_worst_first():
    rows = rr.by_brain(rr.f2f.rows_from_jsonl(EXPORT))
    assert rows[0] == ("Mini", 1, 0, 1)  # 100% bad sorts above Lil's 2 of 3
    assert rows[1] == ("Lil", 3, 1, 2)


def test_bad_answers_where_no_tool_fired_are_the_tell():
    rows = rr.f2f.rows_from_jsonl(EXPORT)
    assert [r.question for r in rr.bad_without_tools(rows)] == ["Who won last night?", "What's 2+2?"]


def test_report_lists_notes_newest_first_and_points_at_fixtures():
    report = rr.render(rr.f2f.rows_from_jsonl(EXPORT), source="ratings.jsonl")
    notes = report[report.index("## Notes on bad answers"):]
    assert notes.index("Price of BTC?") < notes.index("Who won last night?")
    assert "should have searched the web" in report and "wrong source" in report
    assert "1 bad answer without a note" in report
    assert "feedback_to_fixtures.py --jsonl ratings.jsonl" in report


def test_an_empty_export_says_so():
    assert "No ratings" in rr.render([], source="x.jsonl")


def test_newest_export_in_a_folder(tmp_path):
    old = tmp_path / "m1k3-answer-ratings.jsonl"
    new = tmp_path / "m1k3-answer-ratings 2.jsonl"
    other = tmp_path / "notes.jsonl"
    for i, p in enumerate((old, new, other)):
        p.write_text(EXPORT)
        os.utime(p, (1_000 + i, 1_000 + i))
    os.utime(other, (9_999, 9_999))  # newest file, but not an export
    assert rr.newest_export(tmp_path) == new
    assert rr.newest_export(tmp_path / "missing") is None


def test_the_fixtures_hint_survives_a_path_with_spaces():
    # AirDrop names a repeat "m1k3-answer-ratings 2.jsonl": the hint must paste as one argument.
    report = rr.render(rr.f2f.rows_from_jsonl(EXPORT), source="/Users/k/Downloads/m1k3-answer-ratings 2.jsonl")
    assert "--jsonl '/Users/k/Downloads/m1k3-answer-ratings 2.jsonl'" in report


def test_a_unicode_line_separator_inside_an_answer_does_not_split_its_row():
    # Apple's JSONSerialization writes U+2028/U+2029/U+0085 raw; str.splitlines() broke a row on them.
    ls, ps, nel = chr(0x2028), chr(0x2029), chr(0x85)
    raw = json.dumps({"message_id": "m", "verdict": "bad", "question": f"Wrapped{ps}question{nel}here",
                      "comment": f"odd{ls}text", "tools_used": []}, ensure_ascii=False)
    assert ls in raw  # a raw separator, as the phone writes it
    rows = rr.f2f.rows_from_jsonl(raw + "\n" + _line("good"))
    assert len(rows) == 2 and rows[0].comment == f"odd{ls}text"


def test_markdown_in_questions_and_notes_is_escaped():
    line = _line("bad", brain="Lil|Pro", comment="- not a list <think>", question="what does **kwargs do?")
    report = rr.render(rr.f2f.rows_from_jsonl(line), source="x.jsonl")
    assert "what does \\*\\*kwargs do?" in report
    assert "\\- not a list &lt;think&gt;" in report
    assert "| Lil\\|Pro |" in report
