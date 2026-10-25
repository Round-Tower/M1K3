"""Pins for pr_watch's pure core — the landing rules as code, not folklore.

Each fixture is a shape the claude-review bots have actually posted on this
repo (read off PR #293, 2026-09-12) or a CI job list read off the Actions API.
"""

import pr_watch as m
import pytest

# The real gh readers, kept before the autouse stub below replaces them.
_REAL_RULESET_REQUIRED = m.ruleset_required
_REAL_HEAD_CHECKS = m.head_check_conclusions


@pytest.fixture(autouse=True)
def _no_live_ruleset(monkeypatch):
    """main() reads the base branch's ruleset and the head's check runs through gh.
    No test reaches the network: the stub ruleset is ci.yml's six jobs, so nothing
    is read off the head unless a test says so."""
    monkeypatch.setattr(m, "ruleset_required", lambda repo, pr: m.ALWAYS_REQUIRED)
    monkeypatch.setattr(m, "head_check_conclusions", lambda repo, head: {})


def bot(body, created="2026-09-12T08:00:00Z", updated=None):
    c = {"user": {"login": "claude[bot]"}, "body": body, "created_at": created}
    if updated:
        c["updated_at"] = updated
    return c


# A package-only head: ci.yml skips the mobile job on a PR whose diff misses its
# paths, and a skipped job reads green.
GREEN_JOBS = {"Detect compilable changes": "success", "Swift · Mac MVP (swift test)": "success",
              "Swift · App shell (xcodebuild)": "success", "Swift · iOS + visionOS shells (xcodebuild)": "skipped",
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
    v = m.verdict(head, jobs, [auto], auto_ok=True, passes_needed=2,
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
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_MOBILE: "skipped",
            m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, jobs, [review], auto_ok=True, passes_needed=2, auto_comment=review)
    assert v.passes == 1 and not v.ready
    # An auto comment that names no head still adds its one pass.
    plain = bot("## Review: perf pass\nFocused…", created="2026-09-24T18:54:10Z")
    v = m.verdict(head, jobs, [plain], auto_ok=True, passes_needed=2, auto_comment=plain)
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
    summon["body"] += f"\n\nVERDICT: APPROVE @ {head}"
    review = bot(f"## Review: CI tooling pass\nFocused on pr_watch.py…\n\nVERDICT: APPROVE @ {head}", created="2026-09-24T21:09:55Z")
    assert m.auto_pass_comment(head, runs, [summon, review]) is review
    jobs = {m.JOB_SWIFT_TEST: "skipped", m.JOB_APP: "skipped", m.JOB_MOBILE: "skipped",
            m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, jobs, [summon, review], auto_ok=True, passes_needed=2, auto_comment=review,
                  **OURS)
    assert v.passes == 2 and v.ready


def test_an_older_heads_late_review_inside_this_runs_window_is_not_this_runs_comment():
    # #687 (2026-10-25): c4f2f3d8's review run queued 80 min and finished inside
    # 13e58a5f's window; its `gh pr comment` review (VERDICT @ c4f2f3d8) was the
    # first in the window and read as 13e58a5f's auto pass, so a head with an
    # APPROVE naming it in full stayed unlandable. A comment whose verdict names
    # ANOTHER sha is another head's review, whenever it was posted.
    # Signed: Kev + claude-fable-5.1, 2026-10-25 · Prior: Unknown (this file carries no signature)
    old_head = "c4f2f3d8" + "0" * 32
    head = "13e58a5f" + "0" * 32
    runs = [_run(old_head, 111, "2026-10-25T19:48:47Z", "2026-10-25T19:49:45Z"),
            _run(head, 222, "2026-10-25T19:49:20Z", "2026-10-25T19:50:17Z")]
    old = bot(f"Reviewed the diff (tail cache).\n\nVERDICT: APPROVE @ {old_head}", created="2026-10-25T19:49:38Z")
    new = bot(f"Review of the cross-turn tail checkpoint:\n\nVERDICT: APPROVE @ {head}", created="2026-10-25T19:50:10Z")
    assert m.auto_pass_comment(head, runs, [old, new]) is new
    assert m.auto_pass_comment(old_head, runs, [old, new]) is old
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "skipped", m.JOB_MOBILE: "skipped",
            m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, jobs, [old, new], auto_ok=True, passes_needed=1, auto_comment=new, **OURS)
    assert v.passes == 1 and v.ready, v.summary


def test_a_window_comment_with_no_verdict_still_counts_as_the_runs_own():
    # Summons before 2026-10-10 wrote no VERDICT line; the window rule keeps them.
    head = "13e58a5f" + "0" * 32
    runs = [_run(head, 222, "2026-10-25T19:49:20Z", "2026-10-25T19:50:17Z")]
    review = bot("## Review: docs pass\nNothing to flag.", created="2026-10-25T19:50:10Z")
    assert m.auto_pass_comment(head, runs, [review]) is review


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

# #558: master's ruleset requires eight checks: ci.yml's six (the iOS + visionOS
# shells among them), TruffleHog and CodeQL. GitHub refuses a merge (405) while
# any of them runs, so the gate waits on the same set, read live.
RULES = [  # GET repos/Round-Tower/M1K3/rules/branches/master, 2026-10-13, trimmed
    {"type": "deletion", "ruleset_id": 7},
    {"type": "required_status_checks", "ruleset_id": 7,
     "parameters": {"strict_required_status_checks_policy": False,
                    "required_status_checks": [{"context": "Detect compilable changes"},
                                               {"context": "Swift · iOS + visionOS shells (xcodebuild)"},
                                               {"context": "Secrets · TruffleHog"},
                                               {"context": "CodeQL", "integration_id": 57789}]}},
    {"type": "pull_request", "ruleset_id": 7, "parameters": {}},
]


def test_the_mobile_job_is_always_required_and_a_skipped_one_reads_green():
    # The ruleset requires it whatever the diff. ci.yml skips it on a PR that
    # misses the mobile paths, and skipped reads green, so a package-only head
    # still never waits for the mobile build.
    assert m.JOB_MOBILE in m.required_jobs()
    assert m.ci_verdict(m.required_jobs(), {**GREEN_JOBS, m.JOB_MOBILE: "skipped"}).state == "green"
    running = m.ci_verdict(m.required_jobs(), {**GREEN_JOBS, m.JOB_MOBILE: None})
    assert running.state == "pending" and m.JOB_MOBILE in running.detail


def test_553s_shape_waits_for_the_running_mobile_job():
    # #553: a Mac-shell file outside the old prefix list started the mobile job;
    # the gate read READY and GitHub refused with 405 "is in progress".
    jobs = {**GREEN_JOBS, m.JOB_MOBILE: None}
    v = m.verdict(V_HEAD, jobs, [_summon(V_APPROVE)], auto_ok=False,
                  passes_needed=1, **OURS)
    assert not v.ready and v.ci.state == "pending"


def test_required_contexts_reads_every_status_check_rule():
    assert m.required_contexts(RULES) == {"Detect compilable changes", "Swift · iOS + visionOS shells (xcodebuild)",
                                          "Secrets · TruffleHog", "CodeQL"}
    # two rulesets on one branch both count; a rule without parameters adds nothing
    extra = [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Other"}]}},
             {"type": "required_status_checks"}]
    assert "Other" in m.required_contexts(RULES + extra)
    assert m.required_contexts([]) == frozenset()


def test_ruleset_checks_join_the_required_set():
    req = m.required_jobs(m.required_contexts(RULES))
    assert {"Secrets · TruffleHog", "CodeQL", m.JOB_SWIFT_TEST, m.JOB_MOBILE} <= req


def test_a_running_ruleset_check_outside_ci_yml_holds_the_gate():
    # ci.yml's jobs alone read green here; GitHub would still refuse while TruffleHog runs.
    ruleset = m.required_contexts(RULES)
    jobs = {**GREEN_JOBS, "Secrets · TruffleHog": None, "CodeQL": "success"}
    v = m.ci_verdict(m.required_jobs(ruleset), jobs)
    assert v.state == "pending" and "Secrets · TruffleHog" in v.detail
    jobs["Secrets · TruffleHog"] = "failure"
    assert m.ci_verdict(m.required_jobs(ruleset), jobs).state == "red"


def test_the_newest_check_run_per_name_wins():
    runs = [{"id": 11, "name": "CodeQL", "conclusion": "failure"},
            {"id": 13, "name": "CodeQL", "conclusion": "success"},  # a re-run supersedes
            {"id": 12, "name": "Secrets · TruffleHog", "conclusion": None},  # still running
            {"id": 14, "conclusion": "success"}]  # nameless: ignored
    assert m.newest_check_conclusions(runs) == {"CodeQL": "success", "Secrets · TruffleHog": None}


def test_a_ci_yml_job_its_newest_run_has_not_registered_reads_pending_not_stale():
    # Pre-push review of #558's fix: a reopened PR re-runs ci.yml on the same head,
    # whose check runs still carry the older run's results. Only ci.yml's newest run
    # speaks for its own jobs, so an unregistered one waits.
    jobs = {k: v for k, v in GREEN_JOBS.items() if k != m.JOB_SWIFT_TEST}
    ruleset = m.ALWAYS_REQUIRED | {"CodeQL"}
    merged = m.merge_ruleset_checks(jobs, {m.JOB_SWIFT_TEST: "cancelled", "CodeQL": "success"}, ruleset)
    assert m.JOB_SWIFT_TEST not in merged and merged["CodeQL"] == "success"
    assert m.ci_verdict(m.required_jobs(ruleset), merged).state == "pending"


def test_head_checks_fill_only_required_names_ci_yml_did_not_report():
    # ci.yml's newest run stays the source for its own jobs, and a check nobody
    # requires (the review job, Slack) never enters the verdict.
    jobs = {m.JOB_SWIFT_TEST: "success"}
    head = {m.JOB_SWIFT_TEST: "failure", "CodeQL": "success", "Claude Code Review": "failure"}
    assert m.merge_ruleset_checks(jobs, head, frozenset({m.JOB_SWIFT_TEST, "CodeQL"})) == {
        m.JOB_SWIFT_TEST: "success", "CodeQL": "success"}


def test_a_skipped_app_shell_job_reads_green_on_a_package_only_head():
    # ci.yml path-gates the App-shell job on PRs (2026-09-24); the watch must
    # not hold a package-only PR hostage to a job that never ran.
    jobs = {m.JOB_GATE: "success", m.JOB_SWIFT_TEST: "success", m.JOB_APP: "skipped", m.JOB_MOBILE: "skipped",
            m.JOB_GUARDS: "success", m.JOB_DOCS: "success"}
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
    v = m.ci_verdict(req, {m.JOB_SWIFT_TEST: "success", "Notify Slack": "failure"})
    assert v.state == "green"
    assert "Notify Slack" in v.advisory


# --- the landing verdict ---------------------------------------------------

def test_ready_needs_green_required_ci_and_enough_passes_on_this_head():
    head = "08eb0c00" + "0" * 32
    comments = [bot("**Claude finished @kev's task in 2m** ---\n### Final pass — review of head `08eb0c00`\n- [x] a\n\n"
                    f"VERDICT: APPROVE @ {head}", created="2026-09-12T08:00:00Z")]
    auto = bot(f"## Review: auto pass\nFine.\n\nVERDICT: APPROVE @ {head}", created="2026-09-12T08:05:00Z")
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_MOBILE: "skipped",
            m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    v = m.verdict(head, jobs, comments + [auto], auto_ok=True, passes_needed=2, auto_comment=auto,
                  **OURS)
    assert v.ready and v.passes == 2
    v = m.verdict(head, jobs, comments, auto_ok=False, passes_needed=2)
    assert not v.ready and v.passes == 1 and "1/2" in v.summary


def test_trivial_head_needs_no_passes():
    head = "aaaaaaaa" + "0" * 32
    jobs = {m.JOB_SWIFT_TEST: "success", m.JOB_APP: "success", m.JOB_MOBILE: "skipped",
            m.JOB_GUARDS: "success", m.JOB_DOCS: "success", m.JOB_GATE: "success"}
    assert m.verdict(head, jobs, [], auto_ok=False, passes_needed=0, **OURS).ready


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
    assert m.downgrade_refused(0, RISKY, why=None)


def test_any_landing_below_the_inference_needs_a_why_even_off_a_risk_surface():
    # Summon pass 1 on #550: with hands-off landing, a bare --passes 0 is how an agent
    # unblocks itself past the review — the verdict gate reads nothing on a head with no
    # pass. The 2026-10-08 ruling let it through on a diff with no risk surface; it now
    # needs a stated reason like any other downgrade.
    docs = ["macos/docs/GEMMA_1_1_PLAN.md", "macos/docs/evals/x.json"]
    assert m.downgrade_refused(0, ["README.md"], why=None)
    assert m.downgrade_refused(0, docs, why=None)
    assert m.downgrade_refused(0, docs, why="x")  # a reason, not a token
    assert not m.downgrade_refused(0, docs, why="trivial head: comment fold on a passed head")
    assert not m.downgrade_refused(None, docs, why=None)
    assert not m.downgrade_refused(1, docs, why=None)  # the inference itself needs no reason


def test_main_refuses_a_bare_passes_0_off_a_risk_surface_and_names_no_empty_surface(monkeypatch, capsys):
    # #511/#513 printed "risk surface ()" — an empty list — refusing a docs-only head. The
    # refusal is back; the message says what is actually owed.
    snap = ("OPEN", V_HEAD, ["README.md"], GREEN_JOBS, [], None, 0, None, {}, "kpmmmurphy", "o/r")
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: snap)
    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    assert m.main(["9", "--once", "--passes", "0", "--repo", "o/r"]) == 5
    out = capsys.readouterr().out
    assert "--why" in out and "risk surface ()" not in out and "below the 1" in out
    assert m.main(["9", "--once", "--passes", "0", "--why", "trivial head: docs fold", "--repo", "o/r"]) == 0


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
    v = m.verdict(head, jobs, comments, auto_ok=True, passes_needed=2)
    assert not v.ready and v.ci.state == "red"


# --- the review's own verdict (2026-10-10) ----------------------------------
# A pass used to count by author, shape and head alone: one that said
# "BLOCKING: …" still counted, and land.sh merged. Hands-off landing needs the
# gate to read what the review concluded, from the line every prompt now asks
# for: `VERDICT: APPROVE @ <sha>` or `VERDICT: CHANGES_REQUESTED @ <sha>`.

V_HEAD = "c0ffee12" + "0" * 32
V_APPROVE = f"VERDICT: APPROVE @ {V_HEAD}"  # only the full sha approves (Kev, 2026-10-10)


def _summon(verdict_line, created="2026-10-10T10:00:00Z", updated=None, title="### Review of head `c0ffee12`"):
    body = f"**Claude finished @kev's task in 40s** ---\n{title}\n\n- [x] Read the diff\n\nFindings…"
    if verdict_line:
        body += f"\n\n{verdict_line}"
    return bot(body + "\n · branch `fix/x`", created=created, updated=updated)


def _gate(comments, passes_needed=1, auto_comment=None, head=V_HEAD, origin=None):
    return m.verdict(head, GREEN_JOBS, comments, auto_ok=auto_comment is not None,
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


def test_an_odd_number_of_fences_makes_the_verdict_unparseable():
    # Summon pass 1 on #550: _outside_fences toggles on every ``` line, so a stray one
    # flips which lines read as quoted. Here it turns the fenced EXAMPLE into the verdict
    # and hides the real CHANGES_REQUESTED inside a "fence".
    promoted = ("Findings: the gate fails open.\n"
                "```\nsome text\n"                                  # stray: never closed
                "```\nVERDICT: APPROVE @ c0ffee12\n```\n"            # the example, fenced
                "VERDICT: CHANGES_REQUESTED @ c0ffee12")            # the real verdict
    assert m.review_verdict(promoted) == ("unparseable", "")
    v = _gate([_summon(promoted)])
    assert not v.ready and "verdict: unparseable on c0ffee12" in v.reasons
    # an unclosed fence before the real line no longer hides it as "missing"
    assert m.review_verdict("```\ncode\nVERDICT: APPROVE @ c0ffee12") == ("unparseable", "")
    # with no verdict-shaped line anywhere, an odd fence count is still just "missing":
    # an older summon with a stray fence is no blocker
    assert m.review_verdict("```\ncode, never closed\nFine.") == ("missing", "")
    # an even count keeps reading fences as before
    assert m.review_verdict("```\nVERDICT: APPROVE @ c0ffee12\n```\nVERDICT: CHANGES_REQUESTED @ c0ffee12") == \
        ("CHANGES_REQUESTED", "c0ffee12")


def test_an_approving_pass_on_the_head_is_ready():
    v = _gate([_summon(V_APPROVE)])
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
    assert "verdict: APPROVE names 7c0383c1, not c0ffee120000" in v.reasons


def test_only_the_heads_full_sha_approves():
    # Kev, 2026-10-10: a 7-char prefix can be ground in ~2^28 tries, so an agent could
    # push a new head that borrows an old approval. Only the full 40-char sha approves
    # (dyslexia-ai #892's review_gate.py reads it the same way).
    for n in (7, 8, 39):
        v = _gate([_summon(f"VERDICT: APPROVE @ {V_HEAD[:n]}")])
        assert not v.ready, n
        assert f"verdict: short sha ({n} chars) on c0ffee120000; the gate needs the full 40-char head sha" in v.reasons
        assert "verdict APPROVE" not in v.summary
    assert _gate([_summon(V_APPROVE)]).ready
    assert _gate([_summon(f"VERDICT: APPROVE @ `{V_HEAD.upper()}`")]).ready  # case doesn't matter
    # a ground collision: the same 8-char prefix, another commit — 12 chars tell them apart
    other = "c0ffee12" + "1" * 32
    v = _gate([_summon(f"VERDICT: APPROVE @ {other}")])
    assert not v.ready
    assert "verdict: APPROVE names c0ffee121111, not c0ffee120000" in v.reasons
    # the auto pass's `gh pr comment` review is held to the same line
    auto = bot(f"## Review\nFine.\n\nVERDICT: APPROVE @ {V_HEAD[:8]}", created="2026-10-10T10:03:00Z")
    assert not _gate([], auto_comment=auto).ready
    # fail closed: a head read short (gh never does) cannot turn a prefix into "the full sha"
    assert m.verdict_refusal("c0ffee12", {"body": "VERDICT: APPROVE @ c0ffee12"}) is not None


def test_a_short_sha_blocker_still_stands_and_a_short_sha_approve_clears_nothing():
    # Strict for approvals, generous for blockers (fail closed): a CHANGES_REQUESTED naming
    # any 7+ prefix of the head is about this head, and only a full-sha APPROVE from a
    # review that started after it finished clears it.
    blocker = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee1", created="2026-10-10T10:00:00Z", updated="2026-10-10T10:01:00Z")
    short_ok = _summon(f"VERDICT: APPROVE @ {V_HEAD[:12]}", created="2026-10-10T10:20:00Z", updated="2026-10-10T10:21:00Z")
    v = _gate([blocker, short_ok])
    assert not v.ready
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons
    full_ok = _summon(V_APPROVE, created="2026-10-10T10:20:00Z", updated="2026-10-10T10:21:00Z")
    assert _gate([blocker, full_ok]).ready


def test_the_newest_pass_overrides_an_older_approve():
    older = _summon(V_APPROVE, created="2026-10-10T10:00:00Z")
    newer = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:20:00Z")
    assert not _gate([older, newer]).ready
    assert not _gate([newer, older]).ready  # newest by time, not by thread order
    # and a re-review on the same head may clear an older CHANGES_REQUESTED
    assert _gate([_summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:00:00Z"),
                  _summon(V_APPROVE, created="2026-10-10T10:20:00Z")]).ready


def test_newest_is_when_the_pass_finished_not_when_its_tracking_comment_was_created():
    # A summon's tracking comment is created when its run starts and updated with
    # the review when it ends (#547: created 16:12:52, updated 16:13:41). The auto
    # review posted between the two (16:13:21) is the older word.
    summon = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T16:12:52Z", updated="2026-10-10T16:13:41Z")
    auto = bot(f"## Review: one embedder\nFine.\n\n{V_APPROVE}", created="2026-10-10T16:13:21Z",
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
    summon_ok = _summon(V_APPROVE, created="2026-10-10T10:00:05Z", updated="2026-10-10T10:04:00Z")
    v = _gate([summon_ok, auto_cr], passes_needed=2, auto_comment=auto_cr)
    assert v.passes == 2 and not v.ready
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons
    auto_ok = bot(f"## Review\nFine.\n\n{V_APPROVE}", created="2026-10-10T10:03:00Z")
    assert _gate([summon_ok, auto_ok], passes_needed=2, auto_comment=auto_ok).ready
    # the mirror: the blocker finishes last
    summon_cr = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:00:05Z", updated="2026-10-10T10:04:00Z")
    assert not _gate([summon_cr, auto_ok], passes_needed=2, auto_comment=auto_ok).ready


def test_a_concurrent_blocker_stands_when_one_pass_is_owed_too():
    # Code review on this PR: the concurrency case is not only a risk-surface
    # one. At the default one pass, a summon fired at push time races the auto
    # pass just the same, and "newest only" let the later APPROVE wave the
    # other's blocker through.
    auto_cr = bot("## Review\nBLOCKING.\n\nVERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:03:00Z")
    summon_ok = _summon(V_APPROVE, created="2026-10-10T10:00:05Z", updated="2026-10-10T10:04:00Z")
    v = _gate([summon_ok, auto_cr], passes_needed=1, auto_comment=auto_cr)
    assert v.passes == 2 and not v.ready
    assert "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons
    # --passes 0 does not wave it through either
    assert not _gate([summon_ok, auto_cr], passes_needed=0, auto_comment=auto_cr).ready


def test_only_a_review_that_started_after_the_blocker_finished_clears_it():
    blocker = _summon("VERDICT: CHANGES_REQUESTED @ c0ffee12", created="2026-10-10T10:00:00Z", updated="2026-10-10T10:01:00Z")
    # a re-summon (its tracking comment is created when its run starts) read the blocker's thread
    resummon = _summon(V_APPROVE, created="2026-10-10T10:20:00Z", updated="2026-10-10T10:21:00Z")
    assert _gate([blocker, resummon]).ready
    # a `gh pr comment` review is created when its run ENDS: when it started is unknown, so it
    # may have run alongside the blocker and cannot clear it, however late it posted
    late_auto = bot(f"## Review\nFine.\n\n{V_APPROVE}", created="2026-10-10T10:30:00Z")
    assert not _gate([blocker, late_auto], auto_comment=late_auto).ready
    # a CHANGES_REQUESTED on a pass counted for this head that names another sha still blocks
    # (pass 1 on #550) — and, like any blocker, a review started after it can clear it
    old = _summon("VERDICT: CHANGES_REQUESTED @ 7c0383c1", created="2026-10-10T09:00:00Z")
    assert _gate([old, resummon]).ready


def test_a_malformed_concurrent_blocker_stands_like_a_well_formed_one():
    # Pass 1 on #550 (VERDICT: CHANGES_REQUESTED): only a well-formed CHANGES_REQUESTED naming
    # the head stood. A concurrent pass that wrote "CHANGES REQUESTED" (a space), or named a
    # wrong sha, counted as nothing, and the summon's later APPROVE landed the head.
    summon_ok = _summon(V_APPROVE, created="2026-10-10T10:00:05Z", updated="2026-10-10T10:04:00Z")
    for line, reason in (("VERDICT: CHANGES REQUESTED @ c0ffee12", "verdict: unparseable on c0ffee12"),
                         ("VERDICT: CHANGES_REQUESTED @ c0ffee", "verdict: unparseable on c0ffee12"),
                         ("VERDICT: CHANGES_REQUESTED @ 7c0383c1", "verdict: CHANGES_REQUESTED names 7c0383c1, not c0ffee120000")):
        auto = bot(f"## Review\nBLOCKING.\n\n{line}", created="2026-10-10T10:03:00Z")
        v = _gate([summon_ok, auto], passes_needed=1, auto_comment=auto)
        assert v.passes == 2 and not v.ready, line
        assert reason in v.reasons, (line, v.reasons)
    # a malformed blocker is cleared the way a well-formed one is: by a review started after it
    blocker = _summon("VERDICT: CHANGES REQUESTED @ c0ffee12", created="2026-10-10T10:00:00Z", updated="2026-10-10T10:01:00Z")
    resummon = _summon(V_APPROVE, created="2026-10-10T10:20:00Z")
    assert _gate([blocker, resummon]).ready
    # a MISSING line on an older pass stays ignorable: summons before 2026-10-10 never wrote one
    assert _gate([_summon(None, created="2026-10-10T10:00:00Z"), resummon]).ready


def test_a_trivial_head_needs_no_verdict_until_a_pass_on_it_says_otherwise():
    # --passes 0 (the trivial-head rule) with nothing posted on the head: CI decides.
    assert _gate([], passes_needed=0).ready
    # but a pass on THIS head that requests changes is not waved through by --passes 0
    v = _gate([_summon("VERDICT: CHANGES_REQUESTED @ c0ffee12")], passes_needed=0)
    assert not v.ready and "verdict: CHANGES_REQUESTED on c0ffee12" in v.reasons
    # nor by a pass on it that never said
    assert "verdict: missing on c0ffee12" in _gate([_summon(None)], passes_needed=0).reasons


def test_an_auto_pass_whose_comment_is_unknown_cannot_approve():
    # the two-argument auto_ok form: a green run with no comment in hand reads no verdict
    v = m.verdict(V_HEAD, GREEN_JOBS, [], auto_ok=True, passes_needed=1)
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
        # and the approving line the prompt asks for is one the gate accepts: the full sha
        approve = next(ln for ln in prompt.splitlines() if "VERDICT: APPROVE @" in ln)
        assert m.verdict_refusal(V_HEAD, {"body": approve}) is None, (workflow, approve)


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
    # the gate approves nothing shorter (2026-10-10), and summons write 8-char shas in their titles
    flat = " ".join(args.split())
    assert "full 40-character headRefOid" in flat and "never a short" in flat
    # shell-quote parses claude_args: a $ would expand to nothing, a " would end the string
    prompt = args.split("--append-system-prompt", 1)[1].strip()
    assert prompt.startswith('"') and prompt.endswith('"') and prompt.count('"') == 2
    assert "$" not in prompt and "\\" not in prompt and "`" not in prompt


# --- who may land hands-off (2026-10-10) -----------------------------------
# M1K3 is public: an outside contributor's green, approved PR must never
# auto-land. Only an allowlisted author's PR from a branch of this repo does.

APPROVED = V_APPROVE


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
    v = m.verdict(V_HEAD, GREEN_JOBS, [_summon(APPROVED)], auto_ok=False, passes_needed=1)
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


# --- the ruleset and the head's check runs, wired (#558) ---------------------

def _snap_ours(jobs=None):
    return ("OPEN", V_HEAD, ["macos/Sources/A/B.swift"], dict(jobs or GREEN_JOBS), [_summon(APPROVED)], None, 0, None,
            {}, "kpmmmurphy", "Round-Tower/M1K3")


def test_main_waits_on_a_ruleset_check_until_it_is_green(monkeypatch, capsys):
    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: _snap_ours())
    monkeypatch.setattr(m, "ruleset_required", lambda repo, pr: m.ALWAYS_REQUIRED | {"Secrets · TruffleHog"})
    monkeypatch.setattr(m, "head_check_conclusions", lambda repo, head: {"Secrets · TruffleHog": None})
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 2
    assert "Secrets · TruffleHog" in capsys.readouterr().out
    monkeypatch.setattr(m, "head_check_conclusions", lambda repo, head: {"Secrets · TruffleHog": "success"})
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 0


def test_main_retries_an_unreadable_ruleset_then_reads_it_once(monkeypatch, capsys):
    # Three polls: the first read fails, the second reads, the third reads nothing.
    answers = iter([None, m.ALWAYS_REQUIRED])  # a third read would raise StopIteration
    reads = []

    def read(repo, pr):
        reads.append(pr)
        return next(answers)

    pending = {**GREEN_JOBS, m.JOB_SWIFT_TEST: None}
    polls = iter([_snap_ours(pending), _snap_ours(pending), _snap_ours()])
    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: next(polls))
    monkeypatch.setattr(m, "ruleset_required", read)
    monkeypatch.setattr(m.time, "sleep", lambda seconds: None)
    assert m.main(["9", "--repo", "Round-Tower/M1K3", "--interval", "1"]) == 0
    assert reads == [9, 9]
    assert capsys.readouterr().out.count("could not read the base branch's ruleset") == 1


def test_a_garbled_gh_body_is_a_gh_failure_not_ci_red(monkeypatch, capsys):
    def garbled(repo, pr):
        raise m.json.JSONDecodeError("Expecting value", "<html>", 0)

    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    monkeypatch.setattr(m, "snapshot", garbled)
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 4
    assert "gh failed" in capsys.readouterr().out


def test_the_ruleset_note_names_what_drifted():
    assert m.ruleset_note(m.ALWAYS_REQUIRED | {"CodeQL"}) is None
    assert "could not read" in m.ruleset_note(None)
    assert "requires no checks" in m.ruleset_note(frozenset())
    assert m.JOB_MOBILE in m.ruleset_note(m.ALWAYS_REQUIRED - {m.JOB_MOBILE})


def test_an_unreadable_ruleset_gates_on_ci_yml_and_says_so(monkeypatch, capsys):
    # GitHub still enforces the ruleset at merge (405, nothing merged), so the
    # watch falls back to ci.yml's jobs rather than refusing to watch at all.
    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: _snap_ours())
    monkeypatch.setattr(m, "ruleset_required", lambda repo, pr: None)
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 0
    assert "ruleset" in capsys.readouterr().out


def test_a_gh_failure_reading_the_head_checks_is_a_gh_failure(monkeypatch, capsys):
    def boom(repo, head):
        raise m.subprocess.CalledProcessError(1, ["gh"], stderr="HTTP 502")

    monkeypatch.setattr(m, "migration_files", lambda: {"macos/Sources/X/XStore.swift"})
    monkeypatch.setattr(m, "snapshot", lambda repo, pr: _snap_ours())
    monkeypatch.setattr(m, "ruleset_required", lambda repo, pr: m.ALWAYS_REQUIRED | {"CodeQL"})
    monkeypatch.setattr(m, "head_check_conclusions", boom)
    assert m.main(["9", "--once", "--repo", "Round-Tower/M1K3"]) == 4  # never "CI red"


def test_ruleset_required_reads_the_base_branchs_rules(monkeypatch):
    asked = []

    def fake_gh_json(*args):
        asked.append(args)
        if args[:2] == ("pr", "view"):
            return {"baseRefName": "release/1.1"}
        return [RULES]  # --paginate --slurp: one page

    monkeypatch.setattr(m, "_gh_json", fake_gh_json)
    assert _REAL_RULESET_REQUIRED("Round-Tower/M1K3", 9) == m.required_contexts(RULES)
    rules_call = next(a for a in asked if a[-1] == "repos/Round-Tower/M1K3/rules/branches/release%2F1.1")
    assert "--paginate" in rules_call and "--slurp" in rules_call


def test_an_unexpected_rules_shape_is_unreadable_not_an_empty_ruleset(monkeypatch):
    # Without --slurp the API's single page is a flat list of rules; read as pages,
    # every rule would drop and the gate would quietly lose TruffleHog and CodeQL.
    def flat(*args):
        return {"baseRefName": "master"} if args[:2] == ("pr", "view") else RULES

    monkeypatch.setattr(m, "_gh_json", flat)
    assert _REAL_RULESET_REQUIRED("o/r", 9) is None


def test_ruleset_required_is_none_when_gh_fails(monkeypatch):
    def boom(*args):
        raise m.subprocess.CalledProcessError(1, ["gh"], stderr="HTTP 403")

    monkeypatch.setattr(m, "_gh_json", boom)
    assert _REAL_RULESET_REQUIRED("o/r", 9) is None


def test_head_check_conclusions_reads_every_page(monkeypatch):
    def fake_gh_json(*args):
        assert args[-1] == f"repos/o/r/commits/{V_HEAD}/check-runs?per_page=100"
        return [{"total_count": 2, "check_runs": [{"id": 1, "name": "CodeQL", "conclusion": "success"}]},
                {"total_count": 2, "check_runs": [{"id": 2, "name": "Secrets · TruffleHog", "conclusion": None}]}]

    monkeypatch.setattr(m, "_gh_json", fake_gh_json)
    assert _REAL_HEAD_CHECKS("o/r", V_HEAD) == {"CodeQL": "success", "Secrets · TruffleHog": None}


def test_a_neutral_required_check_reads_green_as_github_reads_it():
    # A required check passes on success, skipped or neutral (GitHub's rule). Code
    # scanning can conclude neutral, and the gate must not wait on it forever.
    assert m.ci_verdict(frozenset({"CodeQL"}), {"CodeQL": "neutral"}).state == "green"
