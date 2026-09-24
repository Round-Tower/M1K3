"""Pins for pr_watch's pure core — the landing rules as code, not folklore.

Each fixture is a shape the claude-review bots have actually posted on this
repo (read off PR #293, 2026-09-12) or a CI job list read off the Actions API.
"""
import pr_watch as m


def bot(body, created="2026-09-12T08:00:00Z"):
    return {"user": {"login": "claude[bot]"}, "body": body, "created_at": created}


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
    comments = [bot("**Claude finished @kev's task in 2m** ---\n### Final pass — review of head `08eb0c00`\n- [x] a")]
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, comments, auto_ok=True, passes_needed=2)
    assert v.ready and v.passes == 2
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, comments, auto_ok=False, passes_needed=2)
    assert not v.ready and v.passes == 1 and "1/2" in v.summary


def test_trivial_head_needs_no_passes():
    head = "aaaaaaaa" + "0" * 32
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    assert m.verdict(head, ["macos/Sources/A.swift"], jobs, [], auto_ok=False, passes_needed=0).ready


def test_red_ci_is_never_ready_however_many_passes():
    head = "bbbbbbbb" + "0" * 32
    comments = [bot("**Claude finished @kev's task** ---\n### Final pass — review of head `bbbbbbbb`\n- [x] a")] * 3
    jobs = {m.JOB_SWIFT_TEST: "failure", m.JOB_APP: "success", m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, ["macos/Sources/A.swift"], jobs, comments, auto_ok=True, passes_needed=2)
    assert not v.ready and v.ci.state == "red"
