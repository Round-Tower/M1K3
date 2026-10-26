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
    ]
    assert m.delta_base(HEAD, comments) == A


def test_a_short_sha_or_the_same_head_means_a_full_review():
    assert m.delta_base(HEAD, [bot(review("APPROVE", "abcdef1"), "2026-10-25T13:00:00Z")]) is None
    assert m.delta_base(HEAD, [bot(review("APPROVE", HEAD), "2026-10-25T13:00:00Z")]) is None


def test_delta_only_when_the_head_builds_on_the_base():
    ok = {"status": "ahead", "files": [{"filename": "x.swift"}], "merge_base_commit": {"sha": A}, "commits": []}
    assert m.is_linear(ok, A)
    assert not m.is_linear(dict(ok, status="diverged"), A)  # a force-push
    assert not m.is_linear(dict(ok, status="identical", files=[]), A)
    assert not m.is_linear(dict(ok, files=[]), A)
    assert not m.is_linear(None, A)


def test_outputs_are_github_output_lines():
    assert m.outputs(B, "/w/.review-delta.diff", 3) == (
        f"mode=delta\nbase={B}\ndiff=/w/.review-delta.diff\nfiles=3\n"
    )
    assert m.outputs(None, "", 0) == "mode=full\n"


def test_a_full_page_of_files_may_be_truncated_so_it_means_a_full_review():
    files = [{"filename": f"f{i}.swift"} for i in range(300)]
    assert not m.is_linear({"status": "ahead", "files": files, "merge_base_commit": {"sha": A}, "commits": []}, A)


def test_delta_text_keeps_code_and_names_eval_artifacts_without_their_data():
    files = [
        {"filename": "macos/Sources/M1K3Chat/PrewarmedToolPicker.swift", "status": "modified",
         "additions": 3, "deletions": 1, "patch": "@@ -10,1 +10,3 @@\n-old\n+new\n+newer\n+newest"},
        {"filename": "macos/docs/evals/2026-10-25-picker-lil-cold2.json", "status": "added",
         "additions": 9488, "deletions": 0, "patch": "@@ -0,0 +1,9488 @@\n+{...}"},
        {"filename": "macos/Resources/icon.png", "status": "modified", "additions": 0, "deletions": 0},
    ]
    text, code_files, evals = m.delta_text(files)
    assert code_files == 2
    assert evals == ["macos/docs/evals/2026-10-25-picker-lil-cold2.json (+9488 −0)"]
    assert "+newest" in text and "{...}" not in text
    assert "diff --git a/macos/Sources/M1K3Chat/PrewarmedToolPicker.swift b/macos/Sources/M1K3Chat/PrewarmedToolPicker.swift" in text
    assert "macos/Resources/icon.png: binary" in text
    assert "Eval artifacts (data, not reviewed line by line):" in text


# --- folds from the pre-push review (2026-10-25) ----------------------------- #

def test_a_newer_bot_word_that_is_not_a_clean_approval_means_a_full_review():
    for later in ("Looks good to me.",  # no verdict line
                  "BLOCKING: the lock is dropped early.",
                  f"VERDICT: CHANGES REQUESTED @ {B}",  # unparseable is a blocker at the gate
                  review("APPROVE", "abcdef1")):  # short sha
        comments = [bot(review("APPROVE", A), "2026-10-25T13:00:00Z"), bot(later, "2026-10-25T14:00:00Z")]
        assert m.delta_base(HEAD, comments) is None, later


def test_a_blocker_on_the_base_from_any_pass_means_a_full_review():
    comments = [
        bot(review("CHANGES_REQUESTED", B), "2026-10-25T14:00:00Z"),  # the auto pass
        bot(review("APPROVE", B), "2026-10-25T14:01:00Z"),  # a concurrent summon
    ]
    assert m.delta_base(HEAD, comments) is None


def test_a_tie_at_the_newest_moment_prefers_the_blocker():
    comments = [
        bot(review("APPROVE", A), "2026-10-25T14:00:00Z"),
        bot(review("CHANGES_REQUESTED", B), "2026-10-25T14:00:00Z"),
    ]
    assert m.delta_base(HEAD, comments) is None


def test_only_eval_data_under_macos_docs_evals_is_named_instead_of_inlined():
    assert m.is_eval_data("macos/docs/evals/2026-10-25-speed-baseline-lil.json")
    assert m.is_eval_data("macos/docs/evals/2026-10-25-chatcurve-lil-agent.txt")
    assert not m.is_eval_data("macos/Sources/M1K3Agent/docs/evals/Exfil.swift")
    assert not m.is_eval_data("macos/docs/evals/run_it.py")
    assert not m.is_eval_data("macos/tools/ci/docs/evals/x.json")


def test_a_code_file_without_a_patch_means_a_full_review():
    files = [{"filename": "macos/Sources/M1K3Chat/Huge.swift", "status": "modified", "additions": 4000}]
    assert m.delta_text(files) is None


def test_a_merge_inside_the_delta_or_a_moved_merge_base_means_a_full_review():
    ok = {"status": "ahead", "files": [{"filename": "x.swift"}], "merge_base_commit": {"sha": A},
          "commits": [{"sha": B, "parents": [{"sha": A}]}]}
    assert m.is_linear(ok, A)
    merged = dict(ok, commits=[{"sha": B, "parents": [{"sha": A}, {"sha": "d" * 40}]}])
    assert not m.is_linear(merged, A)
    assert not m.is_linear(dict(ok, merge_base_commit={"sha": "e" * 40}), A)


def test_main_prints_mode_full_and_exits_zero_on_any_failure(capsys, monkeypatch):
    def boom(*_a, **_k):
        raise RuntimeError("gh is down")
    monkeypatch.setattr(m, "_gh", boom)
    assert m.main(["review_delta.py", "1", "--head", HEAD, "--repo", "o/r"]) == 0
    assert capsys.readouterr().out == "mode=full\n"


def test_a_finished_blocker_with_an_unchecked_box_vetoes_the_delta():
    # pr_watch.classify counts it as a pass now (#685/#686), so its blocker is the newest word
    blocker = ("**Claude finished @kev's task** —— [View job](x)\n\n---\n### Review of head `bbbbbbb`\n"
               f"- [ ] Not done: ran no tests\n\nVERDICT: CHANGES_REQUESTED @ {B}")
    comments = [bot(review("APPROVE", A), "2026-10-25T13:00:00Z"), bot(blocker, "2026-10-25T14:00:00Z")]
    assert m.delta_base(HEAD, comments) is None
