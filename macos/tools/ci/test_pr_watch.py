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


def test_older_placeholder_wording_is_a_placeholder():
    assert m.classify("Claude Code is working… I'll analyze this and get back to you.") is m.Kind.PLACEHOLDER


def test_finished_pass_with_a_trailing_optional_checklist_is_still_finished():
    body = ("**Claude finished @kev's task in 51s** —— [View job](x)\n\n---\n### Final pass — review of head `abc1234`\n"
            "- [x] Fetch branch\n- [x] Post findings\n\nNothing blocking. Optional cleanup for later:\n- [ ] rename `x` to `y`")
    assert m.classify(body) is m.Kind.SUMMON


def test_named_head_takes_the_last_review_of_head_phrase():
    body = "### Final pass — review of head `aaaa111`\n(no changes since review of head `bbbb222`… wait, reversed)"
    assert m.named_head(body) == "bbbb222"
    assert m.named_head("mentions head `cccc333` without the phrase") is None


def test_finished_summon_with_all_boxes_ticked_is_a_summon_pass():
    body = "**Claude finished @kev's task in 53s** —— [View job](x)\n\n---\n### Final pass — review of head `64daf36d`\n\n- [x] Fetch branch\n- [x] Post findings\n\nNothing blocking."
    assert m.classify(body) is m.Kind.SUMMON


def test_auto_review_headers_are_reviews():
    assert m.classify("## Review: perf/fanless-idle (#293)\n\nFocused…") is m.Kind.REVIEW
    assert m.classify("**Review: perf(avatar) — unmount hidden RealityViews**") is m.Kind.REVIEW
    assert m.classify("Reviewed the diff (697/-37 across 20 files).") is m.Kind.REVIEW


# --- which head a summon pass reviewed -------------------------------------

def test_named_head_reads_the_backticked_sha():
    assert m.named_head("### Final pass — review of head `64daf36d`") == "64daf36d"
    assert m.named_head("### Second pass — review of final head `d1e3ac71`\n") == "d1e3ac71"


def test_named_head_is_none_when_no_sha_named():
    assert m.named_head("## Review: something\nno sha here") is None


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


# --- which CI jobs gate the merge ------------------------------------------

def test_package_only_change_does_not_wait_for_the_mobile_job():
    req = m.required_jobs(["macos/Sources/M1K3Voice/ObservedSignal.swift", "macos/Tests/M1K3VoiceTests/X.swift"])
    assert m.JOB_SWIFT_TEST in req and m.JOB_APP in req and m.JOB_GUARDS in req and m.JOB_DOCS in req
    assert m.JOB_MOBILE not in req


def test_mobile_shell_change_makes_the_mobile_job_required():
    for path in ("macos/M1K3iOSApp/ChatScreen.swift", "macos/M1K3visionOS/Info.generated.plist", "macos/project.yml", "macos/UITests/ScreengrabiOS/A.swift"):
        assert m.JOB_MOBILE in m.required_jobs([path]), path


def test_ci_workflow_change_requires_everything():
    assert m.JOB_MOBILE in m.required_jobs([".github/workflows/ci.yml"])


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
