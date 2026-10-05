"""Pins for builds.py's pure half: which Xcode Cloud run built a commit, and
when its builds are ready. Hand-written four times on 2026-10-04/05."""
from __future__ import annotations

import builds


def _run(number, sha, progress="COMPLETE", status="SUCCEEDED"):
    return {"attributes": {"number": number, "executionProgress": progress, "completionStatus": status,
                           "sourceCommit": {"commitSha": sha}}}


RUNS = [_run(453, "982e3061aa"), _run(452, "cef1da6fbb"), _run(449, "7ad239c2cc", status="CANCELED")]


def test_a_run_is_found_by_commit_prefix():
    assert builds.run_for_commit(RUNS, "982e3061")["attributes"]["number"] == 453
    assert builds.run_for_commit(RUNS, "deadbeef") is None


def test_a_superseded_run_says_so():
    # Two merges seconds apart: Xcode Cloud cancels the first run; the next one carries both.
    assert builds.run_outcome(RUNS[2]) == "canceled"
    assert builds.run_outcome(RUNS[0]) == "succeeded"
    assert builds.run_outcome(_run(454, "x", progress="RUNNING", status=None)) == "running"


def test_ready_only_when_every_platform_is_valid():
    assert builds.ready({"MAC_OS": "VALID", "IOS": "VALID"}, ("MAC_OS", "IOS"))
    assert not builds.ready({"MAC_OS": "VALID", "IOS": "PROCESSING"}, ("MAC_OS", "IOS"))
    assert not builds.ready({"MAC_OS": "VALID"}, ("MAC_OS", "IOS"))


def test_an_empty_or_missing_commit_matches_nothing():
    # `git rev-parse` failing returned "" and "".startswith("") matched the newest run.
    assert builds.run_for_commit(RUNS, "") is None
    assert builds.run_for_commit([{"attributes": {"number": 1}}], "982e3061") is None


def test_a_full_sha_matches_a_short_one_both_ways():
    assert builds.run_for_commit([_run(7, "982e3061")], "982e3061aa")["attributes"]["number"] == 7
