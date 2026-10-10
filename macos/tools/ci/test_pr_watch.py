"""Pins for pr_watch's pure core — the landing rules as code, not folklore.

Each fixture is a shape the claude-review bots have actually posted on this
repo (read off PR #293, 2026-09-12) or a CI job list read off the Actions API.
"""
import pr_watch as m


def bot(body, created="2026-09-12T08:00:00Z", updated=None):
    c = {"user": {"login": "claude[bot]"}, "body": body, "created_at": created}
    if updated:
        c["updated_at"] = updated
    return c


GREEN_JOBS = {"Detect compilable changes": "success", "Swift · Mac MVP (swift test)": "success",
              "Swift · App shell (xcodebuild)": "success",
              "Project guards (test scheme · store targets)": "success", "Docs match the code (module map)": "success"}
# Kev's PR, from a branch of this repo: the only origin that lands hands-off.
OURS = {"author": "kpmmmurphy", "head_repo": "Round-Tower/M1K3", "base_repo": "Round-Tower/M1K3"}


# --- comment classification -------------------------------------------------

def test_working_placeholder_is_not_a_pass():
    assert m.classify("**Claude working…** <img src=...>") is m.Kind.PLACEHOLDER


def test_unchecked_checklist_is_still_in_progress():
    body = "**Claude finished @kev's task** ---\n### Second pass — review of final head `abc1234`\n- [x] Fetch\n- [ ] Post findings"
    assert m.classify(body) is m.Kind.PLACEHOLDER


def test_review_in_progress_header_is_a_placeholder():
    # third wording, seen 2026-09-12 on #297 while the summon was running
    assert m.classify('### Review in progress <img src="https://github.com/x.gif" width="14px">') is m.Kind.PLACEHOLDER


def test_older_placeholder_wording_is_a_placeholder():
    assert m.classify("Claude Code is working… I'll analyze this and get back to you.") is m.Kind.PLACEHOLDER


def test_finished_pass_with_a_trailing_optional_checklist_is_still_finished():
    body = ("**Claude finished @kev's task in 51s** —— [View job](x)\n\n---\n### Final pass — review of head `abc1234`\n"
            "- [x] Fetch branch\n- [x] Post findings\n\nNothing blocking. Optional cleanup for later:\n- [ ] rename `x` to `y`")
    assert m.classify(body) is m.Kind.SUMMON


def test_auto_review_quoting_an_unchecked_checklist_in_a_fence_is_a_review():
    # #416, 2026-09-26: the finished auto review quoted the PR body's own
    # unchecked merge-gate list inside a ``` fence, and the any-box fallback
    # read it as the bot's progress list — a done review counted as a
    # placeholder, and the watch reported passes 1/2 on a head with two.
    body = ("## Review: mlx-swift-lm pin bump\n\nThe PR body ships with both checklist items unchecked:\n\n"
            "```\n- [ ] gemma-4 native tool-call smoke on this head (in-app SelfTest)\n"
            "- [ ] Lil tool-use spot check\n```\n\nPlease don't merge until both boxes are checked.")
    assert m.classify(body) is m.Kind.REVIEW


def test_an_unfenced_unchecked_box_without_a_pass_header_is_still_progress():
    # the fallback keeps its job for a progress list with no "### … pass" header
    assert m.classify("Working on it\n- [x] Fetch\n- [ ] Post findings") is m.Kind.PLACEHOLDER


def test_finished_summon_with_all_boxes_ticked_is_a_summon_pass():
    body = "**Claude finished @kev's task in 53s** —— [View job](x)\n\n---\n### Final pass — review of head `64daf36d`\n\n- [x] Fetch branch\n- [x] Post findings\n\nNothing blocking."
    assert m.classify(body) is m.Kind.SUMMON


def test_auto_review_headers_are_reviews():
    assert m.classify("## Review: perf/fanless-idle (#293)\n\nFocused…") is m.Kind.REVIEW
    assert m.classify("**Review: perf(avatar) — unmount hidden RealityViews**") is m.Kind.REVIEW
    assert m.classify("Reviewed the diff (697/-37 across 20 files).") is m.Kind.REVIEW


# --- which head a summon pass reviewed -------------------------------------

def test_named_heads_reads_every_backticked_sha_after_the_word_head():
    assert m.named_heads("### Final pass — review of head `64daf36d`") == ["64daf36d"]
    assert m.named_heads("### Second pass — review of final head `d1e3ac71`\n") == ["d1e3ac71"]
    # the wording seen on #297: no "review of" at all
    body = "### Review — head `77702b02`\n\n- [x] Checked out head `77702b02a1dd3a16a3efe790de5de26a24f11ae4`"
    assert m.named_heads(body) == ["77702b02", "77702b02a1dd3a16a3efe790de5de26a24f11ae4"]


def test_named_heads_reads_a_backticked_sha_in_the_pass_header():
    # the wording seen on #318 (2026-09-14): "Review of `sha`", no word "head"
    body = "**Claude finished @kev's task in 2m 20s** ---\n### Review of `75c23b64` (docs only)\n\n- [x] Gather context"
    assert m.named_heads(body) == ["75c23b64"]
    assert m.summon_passes("75c23b646c682af0c592f59698f6dee0d0ae7034", [bot(body)]) == 1


def test_named_heads_reads_a_parenthesised_sha_after_the_word_head():
    # the wording seen on #347 (2026-09-15): the sha in parentheses, no backticks
    body = ("**Claude finished @kev's task in 1m 37s** ---\n"
            "### Review: link colour, second full pass on final head (3922a21d)\n"
            "**Re-confirmed, both review-1 fixes hold on this head, nothing regressed:**")
    assert m.named_heads(body) == ["3922a21d"]
    assert m.summon_passes("3922a21d80bcf227111348ef6407d20386a8b6d4", [bot(body)]) == 1
    # a parenthesised word that is not a sha names nothing
    assert m.named_heads("### pass on final head (docs only)") == []


def test_named_heads_reads_a_bare_sha_after_the_word_head():
    body = ("**Claude finished @kev's task in 2m 10s** ---\n"
            "### Reviewing head f10c752c\n"
            "Looking at the changes…")
    assert m.named_heads(body) == ["f10c752c"]
    assert m.summon_passes("f10c752c3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e", [bot(body)]) == 1


def test_named_heads_reads_bare_sha_second_pass():
    body = ("**Claude finished @kev's task** ---\n"
            "### Second pass review — head a9c584f4\n"
            "Everything looks clean.")
    assert m.named_heads(body) == ["a9c584f4"]


def test_named_heads_reads_a_bare_sha_in_the_pass_header():
    # the wording seen on #437 (2026-09-27): "### Reviewing f2dcbc56", no backticks, no word "head" —
    # two finished summons on the head read 1/2
    body = ("**Claude finished @kev's task in 1m 58s** —— [View job](https://github.com/o/r/actions/runs/1)\n\n---\n"
            "### Reviewing f2dcbc56\n\n- [x] Read the diff")
    assert m.named_heads(body) == ["f2dcbc56"]
    assert m.named_heads("### Reviewing f2dcbc56 (round 2)\n") == ["f2dcbc56"]
    assert m.summon_passes("f2dcbc5612345678901234567890123456789012", [bot(body)]) == 1


def test_a_bare_title_word_that_only_looks_hex_names_nothing():
    # hex letters alone make words ("defaced", "effaced"); a sha is told apart by a digit
    assert m.named_heads("### Reviewing the defaced cache\n") == []
    # and a bare sha in body prose, or a later finding header, still names nothing
    assert m.named_heads("### Review\n\nsee commit 1a2b3c4d for context\n#### Old 5e6f7a8b\n") == []


def test_named_heads_is_empty_when_no_sha_named():
    assert m.named_heads("## Review: something\nno sha here") == []
    assert m.named_heads("mentions `cccc333` without the word head") == []
    # a sha in the body prose, not the header, names nothing
    assert m.named_heads("### Review of the docs\n\nsee `cccc333` for the old shape") == []


def test_a_sha_in_a_later_finding_header_names_nothing():
    # review 2 on #318: only the pass's own title header names a head; a finding's
    # "####" subheader quoting an older commit must not be credited as reviewed
    body = ("**Claude finished @kev's task** ---\n### Review of `78fcaeb1` (docs only)\n\n- [x] Gather context\n\n"
            "#### Bug: regression since `e4e2cd6d`\n\nsome text")
    assert m.named_heads(body) == ["78fcaeb1"]
    assert m.summon_passes("e4e2cd6d" + "0" * 32, [bot(body)]) == 0


def test_a_pass_naming_an_old_head_and_this_one_counts_for_this_one():
    head = "bbbb2220000000000000000000000000000000000"
    body = "**Claude finished @kev's task** ---\n### Review — head `bbbb222`\n- [x] no changes since head `aaaa111`"
    assert m.summon_passes(head, [bot(body)]) == 1
    assert m.summon_passes("aaaa1110000000000000000000000000000000000", [bot(body)]) == 1  # it mentions both; counting is per head asked


def test_head_in_parentheses_with_backticks_names_the_head():
    # #452's summon, 2026-09-29: "I read the diff and the current head (`95586c16`)" read 1/2
    body = "**Claude finished @kev's task in 28s** ---\n### Review of #452: model auditions\n\nI read the diff and the current head (`95586c16`). Fine."
    assert m.named_heads(body) == ["95586c16"]


def test_a_finished_summon_naming_no_sha_counts_when_it_started_after_the_head_arrived():
    # #455's summon, 2026-09-30: "### Review of #455 (docs-only, `CLAUDE.md`)" named no sha and
    # read 0/1 on a reviewed head. A summon reviews whatever head is current when its run
    # starts, and the tracking comment is created at that start, so time settles it.
    head = "6029debb" + "0" * 32
    unnamed = "**Claude finished @kev's task in 12s** ---\n### Review of #455 (docs-only, `CLAUDE.md`)\n\nLooks good."
    seen = "2026-09-30T11:50:00Z"
    assert m.summon_passes(head, [bot(unnamed, created="2026-09-30T11:55:00Z")], head_seen_at=seen) == 1
    assert m.summon_passes(head, [bot(unnamed, created="2026-09-30T11:45:00Z")], head_seen_at=seen) == 0  # ran on the old head
    assert m.summon_passes(head, [bot(unnamed, created="2026-09-30T11:55:00Z")]) == 0  # no arrival time: the old rule
    older = "**Claude finished @kev's task** ---\n### Review of head `babfe834`\n\nfine"
    assert m.summon_passes(head, [bot(older, created="2026-09-30T11:55:00Z")], head_seen_at=seen) == 0  # names another head


def test_an_unnamed_summon_shaped_auto_comment_is_one_pass_not_two():
    # #457 review: the auto pass's own comment can be summon-shaped ("**Claude finished…")
    # and name no sha. The time rule now counts it in summon_passes, so the auto credit
    # must not count it again — one review is one pass.
    head = "aaaa111" + "0" * 33
    seen = "2026-09-30T11:50:00Z"
    auto = bot("**Claude finished @kev's task in 20s** ---\n### Review of #457\n\nfine", created="2026-09-30T11:55:00Z")
    jobs = {"Detect compilable changes": "success", "Swift · Mac MVP (swift test)": "success",
            "Project guards (test scheme · store targets)": "success", "Docs match the code (module map)": "success"}
    v = m.verdict(head, ["macos/tools/ci/pr_watch.py"], jobs, [auto], auto_ok=True, passes_needed=2,
                  auto_comment=auto, head_seen_at=seen)
    assert v.passes == 1


def test_summon_passes_count_only_finished_passes_naming_this_head():
    head = "64daf36d1234567890abcdef1234567890abcdef"
    comments = [
        bot("**Claude finished @kev's task in 1m** ---\n### Final pass — review of head `7c0383c1`\n- [x] a"),  # old head
        bot("**Claude finished @kev's task in 53s** ---\n### Final pass — review of head `64daf36d`\n- [x] a"),
        bot("**Claude working…**"),
        bot("## Review: auto pass, names no head"),
        {"user": {"login": "kpmmmurphy"}, "body": "@claude review head `64daf36d`", "created_at": "2026-09-12T08:00:00Z"},
    ]
    assert m.summon_passes(head, comments) == 1


# --- the auto pass is the review workflow's run on this head ---------------

def test_auto_pass_ok_needs_a_completed_successful_review_run_on_this_head():
    head = "5d135eadffffffffffffffffffffffffffffffff"
    runs = [
        {"headSha": "64daf36d00000000000000000000000000000000", "status": "completed", "conclusion": "success"},
        {"headSha": head, "status": "in_progress", "conclusion": ""},
    ]
    assert m.auto_pass_ok(head, runs) is False
    runs[1] = {"headSha": head, "status": "completed", "conclusion": "success"}
    assert m.auto_pass_ok(head, runs) is True


def test_auto_pass_uses_the_newest_run_on_the_head():
    head = "5d135eadffffffffffffffffffffffffffffffff"
    runs = [
        {"headSha": head, "status": "completed", "conclusion": "success", "createdAt": "2026-09-12T08:00:00Z"},
        {"headSha": head, "status": "in_progress", "conclusion": "", "createdAt": "2026-09-12T08:30:00Z"},
    ]
    assert m.auto_pass_ok(head, runs) is False


def test_auto_pass_needs_the_comment_its_run_posted():
    # #408, 2026-09-24: the action skips itself when the workflow file differs
    # from master — a 13-second green run that posted nothing. Not a pass.
    head = "572a108e" + "0" * 32
    runs = [{"headSha": head, "status": "completed", "conclusion": "success",
             "createdAt": "2026-09-24T21:36:22Z", "updatedAt": "2026-09-24T21:36:38Z"}]
    assert m.auto_pass_ok(head, runs, comments=[]) is False
    review = bot("**Claude finished @kev's task in 2m** ---\n### Reviewed head `572a108e`\n- [x] a", created="2026-09-24T21:36:30Z")
    assert m.auto_pass_ok(head, runs, comments=[review]) is True
    assert m.auto_pass_comment(head, runs, [review]) is review
    late = bot("## Review: someone else's, after the run", created="2026-09-24T21:40:00Z")
    assert m.auto_pass_ok(head, runs, comments=[late]) is False
    placeholder = bot("**Claude working…**", created="2026-09-24T21:36:30Z")
    assert m.auto_pass_ok(head, runs, comments=[placeholder]) is False


def test_an_auto_review_that_names_the_head_counts_once_not_twice():
    # #404, 2026-09-24: the auto pass's own comment is "Claude finished … Reviewed
    # head `x`" — summon-shaped and naming the head. One review, one pass.
    head = "cd1aa308" + "0" * 32
    review = bot("**Claude finished @kev's task in 1m 47s** ---\n### Reviewed head `cd1aa308` (both commits)\n- [x] a", created="2026-09-24T18:54:10Z")
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, [review], auto_ok=True, passes_needed=2, auto_comment=review)
    assert v.passes == 1 and not v.ready
    # An auto comment that names no head still adds its one pass.
    plain = bot("## Review: perf pass\nFocused…", created="2026-09-24T18:54:10Z")
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, [plain], auto_ok=True, passes_needed=2, auto_comment=plain)
    assert v.passes == 1



def _run(head, run_id, created, updated):
    return {"headSha": head, "status": "completed", "conclusion": "success", "databaseId": run_id,
            "createdAt": created, "updatedAt": updated}


def _tracking(run_id, head8, created):
    # the action's own comment: links its run, names the head it reviewed
    return bot(f"**Claude finished @kev's task in 3m** —— [View job](https://github.com/o/r/actions/runs/{run_id})\n\n---\n"
               f"### Reviewed head `{head8}`\n- [x] a", created=created)


def test_auto_pass_is_the_comment_linking_the_runs_id_not_the_first_in_its_window():
    # #409 (summon 2 on #408): a summon fired in the same breath as the push
    # posts its placeholder seconds later — inside the auto run's window and
    # ahead of the auto run's own comment. Identity beats order.
    head = "95e8dbaf" + "0" * 32
    runs = [_run(head, 222, "2026-09-24T21:08:05Z", "2026-09-24T21:10:05Z")]
    summon = _tracking(111, "95e8dbaf", created="2026-09-24T21:08:35Z")
    auto = _tracking(222, "95e8dbaf", created="2026-09-24T21:09:55Z")
    assert m.auto_pass_comment(head, runs, [summon, auto]) is auto
    assert m.linked_run_id(auto["body"]) == "222"
    assert m.linked_run_id("## Review: posted with gh pr comment") is None


def test_a_concurrent_summon_in_the_window_does_not_eat_the_auto_runs_gh_pr_comment_review():
    # The mac review posts its findings with `gh pr comment` — no run link. The
    # window fallback skips the summon (it links another run) and finds them,
    # so the thread's two real reviews read as two passes.
    head = "95e8dbaf" + "0" * 32
    runs = [_run(head, 222, "2026-09-24T21:08:05Z", "2026-09-24T21:10:05Z")]
    summon = _tracking(111, "95e8dbaf", created="2026-09-24T21:08:35Z")
    summon["body"] += "\n\nVERDICT: APPROVE @ 95e8dbaf"
    review = bot("## Review: CI tooling pass\nFocused on pr_watch.py…\n\nVERDICT: APPROVE @ 95e8dbaf", created="2026-09-24T21:09:55Z")
    assert m.auto_pass_comment(head, runs, [summon, review]) is review
    jobs = {m.JOB_SWIFT_TEST: "skipped", m.JOB_APP: "skipped", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, ["macos/tools/ci/pr_watch.py"], jobs, [summon, review], auto_ok=True, passes_needed=2, auto_comment=review,
                  **OURS)
    assert v.passes == 2 and v.ready


def test_a_run_that_posted_nothing_is_not_rescued_by_a_summon_in_its_window():
    # #408's validation-skipped run again, now with a summon landing inside its
    # 16-second window: still no pass — that comment belongs to the summon.
    head = "572a108e" + "0" * 32
    runs = [_run(head, 222, "2026-09-24T21:36:22Z", "2026-09-24T21:36:38Z")]
    summon = _tracking(111, "572a108e", created="2026-09-24T21:36:30Z")
    assert m.auto_pass_comment(head, runs, [summon]) is None
    assert m.auto_pass_ok(head, runs, comments=[summon]) is False


def test_a_review_citing_another_runs_url_in_prose_is_still_this_runs_comment():
    # Only the action's own "[View job](…)" anchor is a link. The mac review
    # posts with `gh pr comment` and may quote a run URL in a finding.
    head = "95e8dbaf" + "0" * 32
    runs = [_run(head, 222, "2026-09-24T21:08:05Z", "2026-09-24T21:10:05Z")]
    review = bot("## Review: CI tooling pass\nCompare https://github.com/o/r/actions/runs/111 — that run skipped itself.",
                 created="2026-09-24T21:09:55Z")
    assert m.linked_run_id(review["body"]) is None
    assert m.auto_pass_comment(head, runs, [review]) is review

# --- which CI jobs gate the merge ------------------------------------------

def test_package_only_change_does_not_wait_for_the_mobile_job():
    req = m.required_jobs(["macos/Sources/M1K3Voice/ObservedSignal.swift", "macos/Tests/M1K3VoiceTests/X.swift"])
    assert m.JOB_SWIFT_TEST in req and m.JOB_APP in req and m.JOB_GUARDS in req and m.JOB_DOCS in req
    assert m.JOB_MOBILE not in req


def test_mobile_shell_change_makes_the_mobile_job_required():
    for path in ("macos/M1K3iOSApp/ChatScreen.swift", "macos/M1K3visionOS/Info.generated.plist", "macos/project.yml", "macos/Package.swift", "macos/Package.resolved",
                 "macos/M1K3App/AvatarView.swift", "macos/M1K3App/Phosphor.metal", "macos/M1K3App/Resources/Fonts/Silkscreen-Bold.ttf",
                 "macos/M1K3.icon/icon.json"):
        assert m.JOB_MOBILE in m.required_jobs([path]), path


def test_mac_only_shell_files_and_test_targets_leave_the_mobile_job_advisory():
    # SelfTest.swift is Mac-shell only; UITests/ are test targets no CI job compiles.
    for path in ("macos/M1K3App/SelfTest.swift", "macos/M1K3App/Info.generated.plist", "macos/UITests/ScreengrabiOS/A.swift"):
        assert m.JOB_MOBILE not in m.required_jobs([path]), path


def test_mobile_prefixes_cover_every_mac_shell_file_the_mobile_targets_compile():
    # project.yml is the source of truth: every `path: M1K3App/<file>` entry is a
    # Mac-shell file some mobile target compiles (the Mac target takes the whole
    # directory as `path: M1K3App`). A new shared file must land here too, or a
    # break in it would read as advisory.
    import pathlib
    import re
    spec = (pathlib.Path(__file__).resolve().parents[2] / "project.yml").read_text()
    shared = sorted(set(re.findall(r"^\s*-\s*path:\s*(M1K3App/\S+)", spec, re.MULTILINE)))
    assert shared, "expected shared M1K3App/ files in project.yml"
    for rel in shared:
        assert m.JOB_MOBILE in m.required_jobs([f"macos/{rel}"]), f"macos/{rel} is compiled by a mobile target but not in MOBILE_PATH_PREFIXES"


def test_ci_workflow_change_requires_everything():
    assert m.JOB_MOBILE in m.required_jobs([".github/workflows/ci.yml"])


def test_a_skipped_app_shell_job_reads_green_on_a_package_only_head():
    # ci.yml path-gates the App-shell job on PRs (2026-09-24); the watch must
    # not hold a package-only PR hostage to a job that never ran.
    jobs = {m.JOB_GATE: "success", m.JOB_SWIFT_TEST: "success", m.JOB_APP: "skipped", m.JOB_GUARDS: "success", m.JOB_DOCS: "success"}
    assert m.ci_verdict(m.ALWAYS_REQUIRED, jobs).state == "green"


def test_ci_verdict_treats_skipped_as_green_and_pending_as_pending():
    req = {m.JOB_SWIFT_TEST, m.JOB_GUARDS}
    assert m.ci_verdict(req, {m.JOB_SWIFT_TEST: "skipped", m.JOB_GUARDS: "success"}).state == "green"
    assert m.ci_verdict(req, {m.JOB_SWIFT_TEST: None, m.JOB_GUARDS: "success"}).state == "pending"
    assert m.ci_verdict(req, {m.JOB_GUARDS: "success"}).state == "pending"  # job not registered yet


def test_ci_verdict_is_red_on_any_required_failure_and_names_it():
    req = {m.JOB_SWIFT_TEST, m.JOB_APP}
    v = m.ci_verdict(req, {m.JOB_SWIFT_TEST: "failure", m.JOB_APP: None})
    assert v.state == "red"
    assert m.JOB_SWIFT_TEST in v.detail


def test_advisory_failure_is_reported_but_does_not_block():
    req = {m.JOB_SWIFT_TEST}
    v = m.ci_verdict(req, {m.JOB_SWIFT_TEST: "success", m.JOB_MOBILE: "failure"})
    assert v.state == "green"
    assert m.JOB_MOBILE in v.advisory


# --- the landing verdict ---------------------------------------------------

def test_ready_needs_green_required_ci_and_enough_passes_on_this_head():
    head = "08eb0c00" + "0" * 32
    comments = [bot("**Claude finished @kev's task in 2m** ---\n### Final pass — review of head `08eb0c00`\n- [x] a\n\n"
                    "VERDICT: APPROVE @ 08eb0c00", created="2026-09-12T08:00:00Z")]
    auto = bot("## Review: auto pass\nFine.\n\nVERDICT: APPROVE @ 08eb0c00", created="2026-09-12T08:05:00Z")
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, comments + [auto], auto_ok=True, passes_needed=2, auto_comment=auto,
                  **OURS)
    assert v.ready and v.passes == 2
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, comments, auto_ok=False, passes_needed=2)
    assert not v.ready and v.passes == 1 and "1/2" in v.summary


def test_trivial_head_needs_no_passes():
    head = "aaaaaaaa" + "0" * 32
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    assert m.verdict(head, ["macos/Sources/A.swift"], jobs, [], auto_ok=False, passes_needed=0, **OURS).ready


def test_one_pass_is_the_default_and_two_is_the_risk_surface_opt_in():
    # 2026-10-04 ruling: a second pass on every substantive PR doubled its
    # push-wait-fold rounds; it is now bought only for risk surfaces.
    assert m.parse_args(["480"]).passes is None  # inferred from the diff
    assert m.required_passes(None, ["macos/Sources/M1K3Heartbeat/HUD.swift"]) == 1
    assert m.parse_args(["480", "--passes", "2"]).passes == 2


# Paths read off the 2026-10-04 audit of #287–#480: of the real bugs only a
# second pass caught on the same head, these are where they lived.
RISKY = [
    "macos/Sources/M1K3AgentTools/ExecuteScriptTool.swift",
    "macos/Sources/M1K3MCPKit/MCPServer.swift",
    "macos/M1K3App/MCPHostController.swift",
    "macos/Sources/M1K3CLICore/MCPAccessToken.swift",
    "macos/M1K3App/KeychainScriptApprovalStore.swift",
    "macos/M1K3App/M1K3.entitlements",
    "macos/M1K3App/PrivacyInfo.xcprivacy",
    "macos/Sources/M1K3Calls/StoredKeyProvider.swift",
    "macos/Sources/M1K3Chat/PrivateCloudTurn.swift",
    "macos/Sources/M1K3Knowledge/SchemaMigrations.swift",
    ".github/workflows/ci.yml",
    "macos/fastlane/Fastfile",
    "macos/project.yml",
    "macos/ci_scripts/ci_post_clone.sh",
    "macos/tools/ci/pr_watch.py",
    # named by the #484 review passes: risk that lives in a directory, not a file name
    "macos/Sources/M1K3MCPKit/LoopbackAccessTokenVault.swift",
    "macos/Sources/M1K3MCPKit/LoopbackRequestGate.swift",
    "macos/Sources/M1K3MCPKit/HTTPWireCodec.swift",
    "macos/M1K3CLI/CLITokenStore.swift",
    "macos/Sources/M1K3CLICore/MCPCallSequence.swift",
    "macos/Sources/M1K3BrainLink/PairedBrainStore.swift",
    "macos/tools/asc/submit.py",
    "macos/Gemfile.lock",
    ".github/actions/setup/action.yml",
    "macos/Config/Release.xcconfig",
    "SECURITY.md",
    ".claude/agents/reviewer.md",
]


def test_a_risk_surface_needs_two_passes_without_being_asked():
    for path in RISKY:
        assert m.required_passes(None, ["README.md", path]) == 2, path
        assert m.risk_surfaces([path]) == [path]


def test_ordinary_code_and_docs_are_not_risk_surfaces():
    plain = ["macos/Sources/M1K3Heartbeat/PulseAskLine.swift", "macos/docs/MCP_SETUP.md",
             "macos/M1K3App/ContentView.swift", "README.md", "macos/Tests/M1K3MCPKitTests/X.swift",
             ".github/workflows/README.md", "macos/tools/ci/test_pr_watch.py"]
    assert m.risk_surfaces(plain) == []
    assert m.required_passes(None, plain) == 1


def test_an_explicit_passes_wins_and_going_below_the_inference_needs_a_why():
    # --passes 0 is the trivial-head rule; landing a risk diff on fewer passes
    # than inferred is allowed only with a stated reason (challenger review, 2026-10-04).
    assert m.required_passes(0, RISKY) == 0
    assert m.required_passes(2, ["README.md"]) == 2
    assert m.downgrade_refused(1, RISKY, why=None)
    assert not m.downgrade_refused(1, RISKY, why="docs-only fold on a reviewed head")
    assert not m.downgrade_refused(None, RISKY, why=None)
    assert not m.downgrade_refused(1, ["README.md"], why=None)
    # #511/#513: a bare --passes 0 on a diff with no risk surface is the trivial-head rule (CLAUDE.md);
    # it was refused with an empty "risk surface ()" message.
    assert not m.downgrade_refused(0, ["README.md"], why=None)
    assert not m.downgrade_refused(0, ["macos/docs/GEMMA_1_1_PLAN.md", "macos/docs/evals/x.json"], why=None)
    assert m.downgrade_refused(0, RISKY, why=None)


def test_a_swift_file_whose_patch_github_omitted_fails_closed():
    big = "macos/Sources/M1K3Memory/MemoryStore.swift"
    assert m.risk_surfaces([big], patches={big: None}) == [big]
    assert m.risk_surfaces([big], patches={big: "+    let x = 1"}) == []


def test_a_why_must_be_a_reason_not_a_token():
    assert m.downgrade_refused(1, RISKY, why="x")
    assert not m.downgrade_refused(1, RISKY, why="text-only fold, reviewed head")


def test_a_head_no_auto_pass_will_review_is_named():
    assert not m.auto_pass_expected(["README.md", "macos/docs/MCP_SETUP.md"])
    assert m.auto_pass_expected(["macos/Sources/A/B.swift"])
    assert m.auto_pass_expected(["macos/tools/ci/pr_watch.py"])
    assert m.auto_pass_expected([".github/workflows/ci.yml"])


def test_main_refuses_a_downgrade_without_why_with_exit_5(monkeypatch, capsys):
    snap = ("OPEN", "a" * 40, ["macos/Sources/M1K3MCPKit/LoopbackAccessTokenVault.swift"],
            {}, [], None, 0, None, {}, "kpmmmurphy", "o/r")
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: snap)
    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    assert m.main(["9", "--once", "--passes", "1", "--repo", "o/r"]) == 5
    assert "--why" in capsys.readouterr().out


def test_dependency_and_plist_changes_are_risk_surfaces():
    for path in ["macos/Package.swift", "macos/Package.resolved", "macos/M1K3App/Info.plist"]:
        assert m.risk_surfaces([path]) == [path], path


def test_a_migration_is_caught_by_content_not_file_name():
    # GRDB migrations live inside *Store.swift files (HeartbeatStore, MemoryStore, ...).
    store = "macos/Sources/M1K3Heartbeat/HeartbeatStore.swift"
    assert m.risk_surfaces([store]) == []
    assert m.risk_surfaces([store], migration_files={store}) == [store]
    patch = '+        migrator.registerMigration("v7_pulse_index") { db in'
    assert m.risk_surfaces([store], patches={store: patch}) == [store]
    assert m.risk_surfaces([store], patches={store: "+    kSecAttrAccessible"}) == [store]


def test_every_migration_file_in_the_tree_is_found():
    # Drift guard: the migration list is read from the tree, never hand-kept.
    found = m.migration_files()
    assert "macos/Sources/M1K3Heartbeat/HeartbeatStore.swift" in found
    assert len(found) >= 7


def test_a_rename_is_judged_by_both_names():
    files = m.changed_paths([{"filename": "macos/M1K3App/SecretStore.swift",
                              "previous_filename": "macos/M1K3App/KeychainStore.swift"}])
    assert "macos/M1K3App/KeychainStore.swift" in m.risk_surfaces(files)


def test_red_ci_is_never_ready_however_many_passes():
    head = "bbbbbbbb" + "0" * 32
    comments = [bot("**Claude finished @kev's task** ---\n### Final pass — review of head `bbbbbbbb`\n- [x] a")] * 3
    jobs = {m.JOB_SWIFT_TEST: "failure", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, comments, auto_ok=True, passes_needed=2)
    assert not v.ready and v.ci.state == "red"


# --- the review's own verdict (2026-10-10) ----------------------------------
# A pass used to count by author, shape and head alone: one that said
# "BLOCKING: …" still counted, and land.sh merged. Hands-off landing needs the
# gate to read what the review concluded, from the line every prompt now asks
# for: `VERDICT: APPROVE @ <sha>` or `VERDICT: CHANGES_REQUESTED @ <sha>`.

V_HEAD = "c0ffee12" + "0" * 32


def _summon(verdict_line, created="2026-10-10T10:00:00Z", updated=None, title="### Review of head `c0ffee12`"):
    body = f"**Claude finished @kev's task in 40s** ---\n{title}\n\n- [x] Read the diff\n\nFindings…"
    if verdict_line:
        body += f"\n\n{verdict_line}"
    return bot(body + "\n · branch `fix/x`", created=created, updated=updated)


def _gate(comments, passes_needed=1, auto_comment=None, files=("macos/Sources/A.swift",), head=V_HEAD, origin=None):
    return m.verdict(head, list(files), GREEN_JOBS, comments, auto_ok=auto_comment is not None,
                     passes_needed=passes_needed, auto_comment=auto_comment, **(origin or OURS))


def test_review_verdict_reads_the_closing_verdict_line():
    assert m.review_verdict("Fine.\n\nVERDICT: APPROVE @ c0ffee12") == ("APPROVE", "c0ffee12")
    assert m.review_verdict("Blocker.\n\nVERDICT: CHANGES_REQUESTED @ c0ffee12") == ("CHANGES_REQUESTED", "c0ffee12")
    # markdown dressing and a full sha are the same line
    assert m.review_verdict("**VERDICT: APPROVE @ `C0FFEE12" + "0" * 32 + "`**") == ("APPROVE", "c0ffee12" + "0" * 32)
    # a bolded label is the natural way to dress it (code review on this PR)
    assert m.review_verdict("**VERDICT:** CHANGES_REQUESTED @ c0ffee12") == ("CHANGES_REQUESTED", "c0ffee12")
    assert m.review_verdict("**VERDICT:** **APPROVE** @ `c0ffee12`") == ("APPROVE", "c0ffee12")
    # the action appends " · branch `x`" after a summon's body; the bot may sign off after the line
    assert m.review_verdict("x\nVERDICT: APPROVE @ c0ffee12\n · branch `fix/x`") == ("APPROVE", "c0ffee12")
    assert m.review_verdict("x\nVERDICT: APPROVE @ c0ffee12\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)") == ("APPROVE", "c0ffee12")


def test_the_last_verdict_line_is_the_verdict_and_a_malformed_one_fails_closed():
    assert m.review_verdict("VERDICT: APPROVE @ c0ffee12\n…on reflection…\nVERDICT: CHANGES_REQUESTED @ c0ffee12") == ("CHANGES_REQUESTED", "c0ffee12")
    # a malformed closing line is not rescued by a well-formed earlier one
    assert m.review_verdict("VERDICT: APPROVE @ c0ffee12\nVERDICT: APPROVE") == ("unparseable", "")
    assert m.review_verdict("VERDICT: LGTM @ c0ffee12") == ("unparseable", "")
    assert m.review_verdict("VERDICT: APPROVE @ c0ffee12 (nits only)") == ("unparseable", "")
    assert m.review_verdict("VERDICT: APPROVE @ abc12") == ("unparseable", "")  # under 7 chars names nothing


def test_prose_quotes_and_fences_are_not_a_verdict():
    # the shape reviews already write (#543): prose, not the line
    assert m.review_verdict("**Verdict: looks good to land.** I only read the diff.") == ("missing", "")
    assert m.review_verdict("The prompt asks for `VERDICT: APPROVE @ <head-sha>` at the end.") == ("missing", "")
    fenced = "```\nVERDICT: APPROVE @ c0ffee12\n```\nStill reviewing."
    assert m.review_verdict(fenced) == ("missing", "")
    assert m.review_verdict("") == ("missing", "")


def test_an_approving_pass_on_the_head_is_ready():
    v = _gate([_summon("VERDICT: APPROVE @ c0ffee12")])
    assert v.ready, v.reasons
    assert "verdict APPROVE" in v.summary


def test_changes_requested_on_the_head_is_not_ready():
    v = _gate([_summon("VERDICT: CHANGES_REQUESTED @ c0ffee12")])
    assert not v.ready and v.passes == 1
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.summary  # main prints the summary, not the reasons


def test_a_pass_without_a_verdict_is_not_ready():
    v = _gate([_summon(None)])
    assert not v.ready and v.passes == 1
    assert "verdict: missing on c0ffee12" in v.reasons
    v = _gate([_summon("VERDICT: APPROVE")])
    assert "verdict: unparseable on c0ffee12" in v.reasons


def test_a_verdict_naming_an_older_sha_is_not_ready():
    # the pass counts for this head (its title names it) but its verdict is about another
    v = _gate([_summon("VERDICT: APPROVE @ 7c0383c1")])
    assert not v.ready
    assert "verdict: APPROVE names 7c0383c1, not c0ffee12" in v.reasons


def test_the_newest_pass_overrides_an_older_approve():
    older = _summon("VERDICT: APPROVE @ c0ffee12", created="2026-10-10T10:00:00Z")
    newer = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:20:00Z")
    assert not _gate([older, newer]).ready
    assert not _gate([newer, older]).ready  # newest by time, not by thread order
    # and a re-review on the same head may clear an older CHANGES_REQUESTED
    assert _gate([_summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:00:00Z"),
                  _summon("VERDICT: APPROVE @ c0ffee12", created="2026-10-10T10:20:00Z")]).ready


def test_newest_is_when_the_pass_finished_not_when_its_tracking_comment_was_created():
    # A summon's tracking comment is created when its run starts and updated with
    # the review when it ends (#547: created 16:12:52, updated 16:13:41). The auto
    # review posted between the two (16:13:21) is the older word.
    summon = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T16:12:52Z", updated="2026-10-10T16:13:41Z")
    auto = bot("## Review: one embedder\nFine.\n\nVERDICT: APPROVE @ c0ffee12", created="2026-10-10T16:13:21Z",
               updated="2026-10-10T16:13:21Z")
    v = _gate([summon, auto], passes_needed=1, auto_comment=auto)
    assert v.passes == 2 and not v.ready
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons


def test_every_owed_pass_must_approve_whichever_finished_last():
    # Two passes are owed on a risk surface, and the repo's rule is to push then
    # summon AT ONCE: the auto pass and the summon review the same head
    # concurrently. If only the newest had to approve, a blocker from the
    # other would land or not by which run finished first.
    auto_cr = bot("## Review\nBLOCKING: the gate fails open.\n\nVERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:03:00Z")
    summon_ok = _summon("VERDICT: APPROVE @ c0ffee12", created="2026-10-10T10:00:05Z", updated="2026-10-10T10:04:00Z")
    risky = ("macos/tools/ci/pr_watch.py",)
    v = _gate([summon_ok, auto_cr], passes_needed=2, auto_comment=auto_cr, files=risky)
    assert v.passes == 2 and not v.ready
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons
    auto_ok = bot("## Review\nFine.\n\nVERDICT: APPROVE @ c0ffee12", created="2026-10-10T10:03:00Z")
    assert _gate([summon_ok, auto_ok], passes_needed=2, auto_comment=auto_ok, files=risky).ready


def test_a_trivial_head_needs_no_verdict_until_a_pass_on_it_says_otherwise():
    # --passes 0 (the trivial-head rule) with nothing posted on the head: CI decides.
    assert _gate([], passes_needed=0).ready
    # but a pass on THIS head that requests changes is not waved through by --passes 0
    v = _gate([_summon("VERDICT: CHANGES_REQUESTED @ c0ffee12")], passes_needed=0)
    assert not v.ready and "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons


def test_an_auto_pass_whose_comment_is_unknown_cannot_approve():
    # the two-argument auto_ok form: a green run with no comment in hand reads no verdict
    v = m.verdict(V_HEAD, ["macos/Sources/A.swift"], GREEN_JOBS, [], auto_ok=True, passes_needed=1)
    assert v.passes == 1 and not v.ready
    assert "verdict: missing on c0ffee12" in v.reasons


def _claude_step(workflow):
    import pathlib

    import yaml
    path = pathlib.Path(__file__).resolve().parents[3] / ".github" / "workflows" / workflow
    doc = yaml.safe_load(path.read_text())
    steps = [s for job in doc["jobs"].values() for s in job["steps"] if "claude-code-action" in s.get("uses", "")]
    assert len(steps) == 1, workflow
    return steps[0]["with"]


def test_every_auto_review_prompt_asks_for_the_line_the_gate_reads():
    # Drift guard: the prompt's example line, with the event's head substituted,
    # must parse as the verdict it names. A reworded prompt that the parser
    # can't read would refuse every PR.
    for workflow in ("claude-code-review-mac.yml", "claude-code-review.yml"):
        prompt = _claude_step(workflow)["prompt"].replace("${{ github.event.pull_request.head.sha }}", V_HEAD)
        for outcome in ("APPROVE", "CHANGES_REQUESTED"):
            lines = [ln for ln in prompt.splitlines() if f"VERDICT: {outcome} @" in ln]
            assert len(lines) == 1, (workflow, outcome)
            assert m.review_verdict(lines[0]) == (outcome, V_HEAD), (workflow, lines[0])


def test_the_summon_asks_for_the_verdict_line_and_stays_in_tag_mode():
    # claude.yml answers @claude: a `prompt` input would switch the action to
    # automation mode and it would stop answering mentions, so the instruction
    # rides --append-system-prompt (the v1 replacement for custom_instructions).
    step = _claude_step("claude.yml")
    assert "prompt" not in step
    args = step["claude_args"]
    assert "--append-system-prompt" in args
    for outcome in ("APPROVE", "CHANGES_REQUESTED"):
        assert f"VERDICT: {outcome} @ <head-sha>" in args
    # shell-quote parses claude_args: a $ would expand to nothing, a " would end the string
    prompt = args.split("--append-system-prompt", 1)[1].strip()
    assert prompt.startswith('"') and prompt.endswith('"') and prompt.count('"') == 2
    assert "$" not in prompt and "\\" not in prompt and "`" not in prompt


# --- who may land hands-off (2026-10-10) -----------------------------------
# M1K3 is public: an outside contributor's green, approved PR must never
# auto-land. Only an allowlisted author's PR from a branch of this repo does.

APPROVED = "VERDICT: APPROVE @ c0ffee12"


def test_an_author_off_the_allowlist_is_never_ready():
    v = _gate([_summon(APPROVED)], origin={**OURS, "author": "outside-dev"})
    assert not v.ready
    assert "author: outside-dev is not on the auto-land list" in v.reasons
    assert "author: outside-dev" in v.summary
    # bots too: dependabot is green and reviewed and still Kev's call
    assert not _gate([_summon(APPROVED)], origin={**OURS, "author": "app/dependabot"}).ready
    assert "kpmmmurphy" in m.AUTO_LAND_AUTHORS


def test_a_fork_head_is_never_ready():
    v = _gate([_summon(APPROVED)], origin={**OURS, "head_repo": "outside-dev/M1K3"})
    assert not v.ready
    assert "fork: head is outside-dev/M1K3, not Round-Tower/M1K3" in v.reasons


def test_an_unknown_origin_fails_closed():
    # a deleted fork has no head repository; a caller that passes nothing gets nothing
    assert not _gate([_summon(APPROVED)], origin={**OURS, "head_repo": None}).ready
    assert not _gate([_summon(APPROVED)], origin={**OURS, "author": None}).ready
    v = m.verdict(V_HEAD, ["macos/Sources/A.swift"], GREEN_JOBS, [_summon(APPROVED)], auto_ok=False, passes_needed=1)
    assert not v.ready and "author: unknown" in v.reasons and "head repo: unknown" in v.reasons


def test_logins_and_repo_names_compare_without_case():
    # both are case-insensitive upstream; `gh repo view` and the PR can disagree on case
    assert _gate([_summon(APPROVED)], origin={"author": "KPMMMurphy", "head_repo": "round-tower/m1k3",
                                              "base_repo": "Round-Tower/M1K3"}).ready


def test_snapshot_reads_the_author_and_head_repo(monkeypatch):
    asked = []

    def fake_gh_json(*args):
        asked.append(args)
        if args[:2] == ("pr", "view"):
            return {"state": "OPEN", "headRefOid": V_HEAD, "author": {"login": "outside-dev"},
                    "headRepository": {"name": "M1K3", "nameWithOwner": "outside-dev/M1K3"}}
        if args[:2] == ("run", "list"):
            return []
        return [[]]  # every paginated --slurp endpoint: one empty page

    monkeypatch.setattr(m, "_gh_json", fake_gh_json)
    snap = m.snapshot("Round-Tower/M1K3", 9)
    assert snap[-2:] == ("outside-dev", "outside-dev/M1K3")
    fields = next(a for a in asked if a[:2] == ("pr", "view"))[-1].split(",")
    assert "author" in fields and "headRepository" in fields


def test_main_will_not_land_a_fork_even_with_green_ci_and_an_approving_pass(monkeypatch, capsys):
    def snap(author, head_repo):
        return ("OPEN", V_HEAD, ["macos/Sources/A/B.swift"], GREEN_JOBS, [_summon(APPROVED)], None, 0, None, {},
                author, head_repo)

    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: snap("kpmmmurphy", "outside-dev/M1K3"))
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 2
    assert "fork: head is outside-dev/M1K3" in capsys.readouterr().out
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: snap("kpmmmurphy", "Round-Tower/M1K3"))
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 0
