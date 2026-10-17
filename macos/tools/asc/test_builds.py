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


class _Git:
    def __init__(self, answers):
        self.answers = answers

    def __call__(self, *args):
        import subprocess

        code, out = self.answers.get(args[0], (0, ""))
        return subprocess.CompletedProcess(args, code, stdout=out, stderr="")


def test_a_short_commit_is_resolved_to_the_full_sha(monkeypatch):
    # #637: ls-remote holds full oids, so a short --commit read as "no release tag".
    full = "07b1cabe36d1eb79a2ce629743a1e8c79765b398"
    monkeypatch.setattr(builds, "git", _Git({"rev-parse": (0, full + "\n")}))
    assert builds.resolve_commit("07b1cabe") == full
    monkeypatch.setattr(builds, "git", _Git({"rev-parse": (128, "")}))
    assert builds.resolve_commit("nope") == ""


def test_a_failed_tag_fetch_is_not_read_as_the_newest_release(monkeypatch):
    monkeypatch.setattr(builds, "git", _Git({"fetch": (1, ""), "tag": (0, "release-old\n")}))
    assert builds.latest_release() is None


def test_the_newest_release_tag_and_its_commit(monkeypatch):
    monkeypatch.setattr(builds, "git", _Git({
        "tag": (0, "release-1.1.0-20261018-aaaa\nrelease-1.1.0-20261017-bbbb\n"),
        "rev-list": (0, "aaaa1111\n"),
    }))
    assert builds.latest_release() == ("release-1.1.0-20261018-aaaa", "aaaa1111")
    monkeypatch.setattr(builds, "git", _Git({"tag": (0, "")}))
    assert builds.latest_release() == ("", "")
