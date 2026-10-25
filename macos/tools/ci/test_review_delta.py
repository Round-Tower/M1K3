"""Unit tests for the pure helpers in review_delta."""

import review_delta as m

A = "a" * 40
B = "b" * 40
HEAD = "c" * 40


def bot(body: str, at: str, login: str = "claude[bot]") -> dict:
    return {"user": {"login": login}, "body": body, "created_at": at, "updated_at": at}


def review(verdict: str, sha: str) -> str:
    return f"Review of the diff.\n\n- fine\n\nVERDICT: {verdict} @ {sha}"


def test_no_earlier_review_means_a_full_review():
    assert m.delta_base(HEAD, []) is None


def test_the_newest_approved_head_is_the_base():
    comments = [
        bot(review("APPROVE", A), "2026-10-25T13:00:00Z"),
        bot(review("APPROVE", B), "2026-10-25T14:00:00Z"),
    ]
    assert m.delta_base(HEAD, comments) == B


def test_a_newer_blocker_means_a_full_review():
    comments = [
        bot(review("APPROVE", A), "2026-10-25T13:00:00Z"),
        bot(review("CHANGES_REQUESTED", B), "2026-10-25T14:00:00Z"),
    ]
    assert m.delta_base(HEAD, comments) is None


def test_newest_is_by_when_the_pass_finished_not_list_order():
    late = bot(review("APPROVE", A), "2026-10-25T13:00:00Z")
    late["updated_at"] = "2026-10-25T15:00:00Z"  # a summon's tracking comment, filled in at the end
    comments = [late, bot(review("CHANGES_REQUESTED", B), "2026-10-25T14:00:00Z")]
    assert m.delta_base(HEAD, comments) == A


def test_only_the_bot_and_only_real_verdicts_count():
    comments = [
        bot(review("APPROVE", A), "2026-10-25T13:00:00Z"),
        bot(review("APPROVE", B), "2026-10-25T14:00:00Z", login="kpmmmurphy"),  # a human pasting one
        bot("**Claude working…**\n\n- [ ] Read the diff", "2026-10-25T15:00:00Z"),  # placeholder
        bot("Looks good to me.", "2026-10-25T16:00:00Z"),  # no verdict line
    ]
    assert m.delta_base(HEAD, comments) == A


def test_a_short_sha_or_the_same_head_means_a_full_review():
    assert m.delta_base(HEAD, [bot(review("APPROVE", "abcdef1"), "2026-10-25T13:00:00Z")]) is None
    assert m.delta_base(HEAD, [bot(review("APPROVE", HEAD), "2026-10-25T13:00:00Z")]) is None


def test_delta_only_when_the_head_builds_on_the_base():
    assert m.is_linear({"status": "ahead", "files": [{"filename": "x.swift"}]})
    assert not m.is_linear({"status": "diverged", "files": [{"filename": "x.swift"}]})  # a force-push
    assert not m.is_linear({"status": "identical", "files": []})
    assert not m.is_linear({"status": "ahead", "files": []})
    assert not m.is_linear(None)


def test_outputs_are_github_output_lines():
    assert m.outputs(B, "/w/.review-delta.diff", 3) == (
        f"mode=delta\nbase={B}\ndiff=/w/.review-delta.diff\nfiles=3\n"
    )
    assert m.outputs(None, "", 0) == "mode=full\n"


def test_a_full_page_of_files_may_be_truncated_so_it_means_a_full_review():
    assert not m.is_linear({"status": "ahead", "files": [{"filename": f"f{i}.swift"} for i in range(300)]})


def test_delta_text_keeps_code_and_names_eval_artifacts_without_their_data():
    files = [
        {"filename": "macos/Sources/M1K3Chat/PrewarmedToolPicker.swift", "status": "modified",
         "additions": 3, "deletions": 1, "patch": "@@ -10,1 +10,3 @@\n-old\n+new\n+newer\n+newest"},
        {"filename": "macos/docs/evals/2026-10-25-picker-lil-cold2.json", "status": "added",
         "additions": 9488, "deletions": 0, "patch": "@@ -0,0 +1,9488 @@\n+{...}"},
        {"filename": "macos/Resources/big.bin", "status": "modified", "additions": 0, "deletions": 0},
    ]
    text, code_files, evals = m.delta_text(files)
    assert code_files == 2
    assert evals == ["macos/docs/evals/2026-10-25-picker-lil-cold2.json (+9488 −0)"]
    assert "+newest" in text and "{...}" not in text
    assert "diff --git a/macos/Sources/M1K3Chat/PrewarmedToolPicker.swift b/macos/Sources/M1K3Chat/PrewarmedToolPicker.swift" in text
    assert "macos/Resources/big.bin: no patch (binary or too large)" in text
    assert "Eval artifacts (data, not reviewed line by line):" in text
