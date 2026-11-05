"""Pins for release.py's pure half: what a release tag left out, and the next runbook step.

Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.85, Prior: none
Build 542 was cut before #776 merged and nothing said what it left out; these pin that answer.
"""
from __future__ import annotations

import release
from release import CD, Excluded, State, Version

TAG = "release-1.3.0-20261105-63446054"
SHA = "634460548c3a93ee5f1c0d2b7e4a9f6c3b2d1e0f"
IN_REVIEW = {"MAC_OS": Version("1.3", "WAITING_FOR_REVIEW", "544"), "IOS": Version("1.3", "IN_REVIEW", "544")}
VALID = {"MAC_OS": "VALID", "IOS": "VALID"}


def _state(**kw: object) -> State:
    base: dict[str, object] = {"tag": TAG, "commit": SHA, "head": SHA, "head_tagged": True, "run": 544,
                               "outcome": "succeeded", "builds": dict(VALID), "stamped": True,
                               "versions": dict(IN_REVIEW)}
    base.update(kw)
    return State(**base)  # type: ignore[arg-type]


# --------------------------------------------------------------------------- #
# parse_prs / classify_docs
# --------------------------------------------------------------------------- #


def test_parse_prs_reads_the_squash_suffix() -> None:
    subjects = [
        "fix(hud): the HUD follows Light and Dark (#779)",
        "docs(store): 1.3 promo text in 12 locales (#777)",
        "chore: a direct push with no PR",
    ]
    assert release.parse_prs(subjects) == [
        (779, "fix(hud): the HUD follows Light and Dark (#779)"),
        (777, "docs(store): 1.3 promo text in 12 locales (#777)"),
    ]


def test_parse_prs_takes_the_last_number_when_a_subject_names_two() -> None:
    # A revert of a PR, squash-merged: the merge's own number is the trailing one.
    assert release.parse_prs(['Revert "x (#12)" (#13)']) == [(13, 'Revert "x (#12)" (#13)')]


def test_parse_prs_ignores_a_number_that_is_not_the_pr_suffix() -> None:
    assert release.parse_prs(["fix: issue #42 stays open"]) == []


def test_docs_only_is_markdown_docs_and_claude() -> None:
    assert release.classify_docs(["README.md", "macos/docs/evals/run.json", ".claude/skills/m1k3/README.md"])
    assert release.classify_docs(["macos/CLAUDE.md"])


def test_store_copy_is_docs_it_never_rides_a_binary() -> None:
    # #777: promo text in fastlane metadata goes live through deliver, never in build 542 or 544.
    assert release.classify_docs(["macos/fastlane/metadata_ios/en-US/promotional_text.txt",
                                  "macos/fastlane/metadata_mac/ja/promotional_text.txt"])


def test_one_source_file_makes_it_code() -> None:
    assert not release.classify_docs(["macos/docs/x.md", "macos/Sources/M1K3Chat/PersonaLeakGuard.swift"])
    assert not release.classify_docs(["macos/TestFlight/notes/ios.en-US.txt"])
    assert not release.classify_docs(["macos/fastlane/Fastfile"])


def test_an_unreadable_or_empty_change_is_not_called_docs() -> None:
    # A failed diff returns no paths: say WARN, never "harmless".
    assert not release.classify_docs([])


def test_a_docs_lookalike_name_is_not_a_docs_directory() -> None:
    assert not release.classify_docs(["macos/Sources/M1K3Knowledge/docsIndex.swift"])


# --------------------------------------------------------------------------- #
# tags
# --------------------------------------------------------------------------- #


def test_parse_tag_refs_peels_annotated_tags() -> None:
    out = (f"{TAG}-r2\tdeadbeef\t{SHA}\n"
           f"{TAG}\tcafef00d\t{SHA}\n"
           "release-light\t1111aaaa\t\n")
    assert release.parse_tag_refs(out) == [(f"{TAG}-r2", SHA), (TAG, SHA), ("release-light", "1111aaaa")]


def test_an_r2_tag_on_the_same_commit_is_an_alias_of_its_base() -> None:
    tags = {TAG: SHA, f"{TAG}-r2": SHA, f"{TAG}-r3": SHA}
    assert release.alias_base(f"{TAG}-r2", tags) == TAG
    assert release.alias_base(f"{TAG}-r3", tags) == TAG
    assert release.alias_base(TAG, tags) == TAG


def test_an_r2_tag_on_another_commit_stands_alone() -> None:
    assert release.alias_base(f"{TAG}-r2", {TAG: "other", f"{TAG}-r2": SHA}) == f"{TAG}-r2"
    assert release.alias_base(f"{TAG}-r2", {f"{TAG}-r2": SHA}) == f"{TAG}-r2"


def test_retag_name_is_the_next_free_suffix() -> None:
    assert release.retag_name(TAG, {TAG: SHA}) == f"{TAG}-r2"
    assert release.retag_name(TAG, {TAG: SHA, f"{TAG}-r2": SHA}) == f"{TAG}-r3"


# --------------------------------------------------------------------------- #
# next_steps: every branch of the chain
# --------------------------------------------------------------------------- #


def test_no_tag_at_all_cuts_one() -> None:
    assert release.next_steps(State()) == [CD + "./release_tag.py cut --confirm"]


def test_code_on_master_past_the_tag_cuts_a_new_one() -> None:
    steps = release.next_steps(_state(head="ffff", head_tagged=False,
                                      excluded=(Excluded(780, "fix: x (#780)", docs=False),)))
    assert steps[0] == CD + "./release_tag.py cut --confirm"
    # The live review is named, so the cut is not mistaken for a free action.
    assert any("cancel" in s and "544" in s for s in steps[1:])


def test_docs_only_past_the_tag_needs_no_new_build() -> None:
    steps = release.next_steps(_state(head="ffff", head_tagged=False,
                                      excluded=(Excluded(781, "docs: y (#781)", docs=True),)))
    assert CD + "./release_tag.py cut --confirm" not in steps
    assert "in review: nothing to do" in steps


def test_no_run_waits_and_names_the_retag() -> None:
    steps = release.next_steps(_state(run=None, outcome=None, builds={}, stamped=False, retag=f"{TAG}-r2"))
    assert steps[0] == CD + "./builds.py wait"
    assert any(f"git tag -a {TAG}-r2 {SHA}" in s and f"git push origin {TAG}-r2" in s for s in steps)


def test_a_running_run_waits() -> None:
    assert release.next_steps(_state(outcome="running", builds={}, stamped=False)) == [CD + "./builds.py wait"]


def test_a_cancelled_run_builds_here() -> None:
    steps = release.next_steps(_state(outcome="canceled", builds={}, stamped=False))
    assert CD + "../release/release-local.sh 544" in steps
    assert any("./testflight.py notes --build 544 --confirm" in s for s in steps)


def test_a_failed_run_says_read_it() -> None:
    steps = release.next_steps(_state(outcome="failed", builds={}, stamped=False))
    assert len(steps) == 1 and "run 544 failed" in steps[0] and not steps[0].startswith(CD)


def test_builds_still_processing_wait() -> None:
    steps = release.next_steps(_state(builds={"MAC_OS": "VALID", "IOS": "PROCESSING"}, stamped=False))
    assert steps == [CD + "./builds.py wait"]


def test_built_not_stamped_installs_relaunches_and_verifies() -> None:
    steps = release.next_steps(_state(stamped=False))
    assert "TestFlight" in steps[0] and "relaunch" in steps[0] and "544" in steps[0]
    assert steps[-1] == CD + "./verify_build.py --build 544"


def test_stamped_not_attached_attaches_and_prechecks() -> None:
    versions = {"MAC_OS": Version("1.3", "PREPARE_FOR_SUBMISSION", "542"),
                "IOS": Version("1.3", "PREPARE_FOR_SUBMISSION", None)}
    assert release.next_steps(_state(versions=versions)) == [
        CD + "./submit.py attach --platform ALL --build 544 --confirm && ./precheck.py"]


def test_a_queued_old_build_is_cancelled_first_only_on_its_platform() -> None:
    # Verified first (stamped), then cancel: the 2026-10-05 order, reversed on purpose.
    versions = {"MAC_OS": Version("1.3", "WAITING_FOR_REVIEW", "542"),
                "IOS": Version("1.3", "WAITING_FOR_REVIEW", "544")}
    assert release.next_steps(_state(versions=versions)) == [
        CD + "./submit.py cancel --platform MAC_OS --confirm --wait",
        CD + "./submit.py attach --platform ALL --build 544 --confirm && ./precheck.py",
    ]


def test_a_released_version_needs_a_new_one_before_attach() -> None:
    versions = {"MAC_OS": Version("1.2.1", "READY_FOR_SALE", "540"), "IOS": IN_REVIEW["IOS"]}
    steps = release.next_steps(_state(versions=versions))
    assert any("MAC_OS" in s and "1.2.1" in s and "new version" in s for s in steps)
    assert steps[-1] == CD + "./submit.py attach --platform ALL --build 544 --confirm && ./precheck.py"


def test_a_missing_version_needs_one_too() -> None:
    steps = release.next_steps(_state(versions={"MAC_OS": None, "IOS": IN_REVIEW["IOS"]}))
    assert any("MAC_OS" in s and "no version" in s for s in steps)


def test_attached_not_submitted_submits() -> None:
    versions = {"MAC_OS": Version("1.3", "PREPARE_FOR_SUBMISSION", "544"),
                "IOS": Version("1.3", "READY_FOR_REVIEW", "544")}
    assert release.next_steps(_state(versions=versions)) == [CD + "./submit.py submit --platform ALL --confirm"]


def test_one_platform_queued_one_rejected_submits_all() -> None:
    versions = {"MAC_OS": IN_REVIEW["MAC_OS"], "IOS": Version("1.3", "REJECTED", "544")}
    assert release.next_steps(_state(versions=versions)) == [CD + "./submit.py submit --platform ALL --confirm"]


def test_in_review_is_nothing_to_do() -> None:
    assert release.next_steps(_state()) == ["in review: nothing to do"]


def test_approved_waits_on_kev_to_release() -> None:
    versions = {p: Version("1.3", "PENDING_DEVELOPER_RELEASE", "544") for p in ("MAC_OS", "IOS")}
    steps = release.next_steps(_state(versions=versions))
    assert len(steps) == 1 and steps[0].startswith("approved")


def test_live_everywhere_is_done() -> None:
    versions = {p: Version("1.3", "READY_FOR_SALE", "544") for p in ("MAC_OS", "IOS")}
    assert release.next_steps(_state(versions=versions)) == ["live: nothing to do"]


def test_an_unknown_state_is_named_not_guessed() -> None:
    versions = {"MAC_OS": Version("1.3", "INVALID_BINARY", "544"), "IOS": IN_REVIEW["IOS"]}
    steps = release.next_steps(_state(versions=versions))
    assert steps == ["MAC_OS 1.3 is INVALID_BINARY: read it in App Store Connect"]


# --------------------------------------------------------------------------- #
# status_lines
# --------------------------------------------------------------------------- #


def test_status_names_what_the_build_left_out_and_warns_on_code() -> None:
    state = _state(tag="release-1.3.0-20261104-338c75df", commit="338c75df68bf", run=542, head_tagged=True,
                   excluded=(Excluded(776, "1.3.0 freeze round (#776)", docs=False),
                             Excluded(777, "docs(store): promo (#777)", docs=True)))
    text = "\n".join(release.status_lines(state))
    assert "release-1.3.0-20261104-338c75df" in text and "338c75df" in text
    assert "run 542" in text and "build 542" in text
    assert "Merged on origin/master after this tag (NOT in this build)" in text
    assert "#776" in text and "#777" in text
    line_777 = next(ln for ln in text.splitlines() if "#777" in ln)
    assert "docs-only" in line_777
    assert "WARN" in text and "#776" in next(ln for ln in text.splitlines() if ln.startswith("WARN"))


def test_status_with_nothing_left_out_has_no_warn() -> None:
    text = "\n".join(release.status_lines(_state(aliases=(f"{TAG}-r2",))))
    assert "WARN" not in text
    assert f"{TAG}-r2" in text  # the alias is shown beside its base
    assert "WAITING_FOR_REVIEW" in text and "IN_REVIEW" in text
    assert "verified-544.json" in text


def test_status_with_only_docs_left_out_has_no_warn() -> None:
    text = "\n".join(release.status_lines(_state(excluded=(Excluded(777, "docs (#777)", docs=True),))))
    assert "WARN" not in text
