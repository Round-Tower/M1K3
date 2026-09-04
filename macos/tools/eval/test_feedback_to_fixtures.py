"""Pins the pure helpers of feedback_to_fixtures.py (the SQLite read is a thin mirror of
AnswerFeedbackExport's columns and is exercised by hand against the container)."""

import json

import feedback_to_fixtures as f2f

ROW = f2f.FeedbackRow(
    message_id="9F1C2D3E-0000-4000-8000-000000000000",
    verdict="bad",
    rated_at="2026-09-04 20:14",
    brain="Lil",
    question='Pal - fetch the web site m1k3.app and give your "read" on how we\'re aligning',
    answer="Pal — I just popped open m1k3.app in the review panel. Nothing's running there yet…",
    tools_used=("open_link",),
    comment="Panel open to the app, it rendered - but we didn't pick it up\nwebview analysis needs to be improved",
)


def test_kind_is_a_guess_from_tools_and_words():
    assert f2f.guess_kind("fetch the site", None, ("open_link",)) == "toolUse"
    assert f2f.guess_kind("what's the weather like", "should have searched the web", ()) == "toolUse"
    assert f2f.guess_kind("Write me a haiku about rain", None, ()) == "codeGen"
    assert f2f.guess_kind("how are you today", "too long", ()) == "openChat"


def test_swift_string_escapes_and_folds():
    assert f2f.swift_string('say "hi"\nback\\slash') == '"say \\"hi\\" back\\\\slash"'


def test_bad_row_with_comment_becomes_a_curatable_stub():
    out = f2f.render([ROW])
    assert '"feedback-9f1c2d3e"' in out
    assert "kind: .toolUse" in out and "GUESSED" in out
    assert 'prompt: "Pal - fetch the web site m1k3.app and give your \\"read\\" on how we\'re aligning"' in out
    assert "Kev: \"Panel open to the app, it rendered - but we didn't pick it up webview analysis needs to be improved\"" in out
    assert 'mustCallTool: "TODO"' in out
    assert "1 draft fixture" in out


def test_good_rows_and_silent_dislikes_draft_nothing():
    good = f2f.FeedbackRow(**{**ROW.__dict__, "verdict": "good"})
    silent = f2f.FeedbackRow(**{**ROW.__dict__, "comment": "  "})
    assert f2f.render([good, silent]).startswith("// no bad verdicts")


def test_jsonl_round_trip_matches_the_swift_exporter_shape():
    line = json.dumps(
        {
            "message_id": ROW.message_id,
            "conversation_id": "c",
            "verdict": "bad",
            "rated_at": ROW.rated_at,
            "brain": "Lil",
            "question": ROW.question,
            "answer": ROW.answer,
            "tools_used": ["open_link"],
            "comment": ROW.comment,
        },
        sort_keys=True,
    )
    rows = f2f.rows_from_jsonl(line + "\n\n")
    assert rows == [ROW]
