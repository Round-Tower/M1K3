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


def test_latest_release_reads_a_failed_peel_as_unreadable(monkeypatch):
    monkeypatch.setattr(builds, "git", _Git({"tag": (0, "release-x\n"), "rev-list": (128, "")}))
    assert builds.latest_release() is None


def _no_run(monkeypatch, tags):
    monkeypatch.setattr(builds, "product_id", lambda: "p")
    monkeypatch.setattr(builds, "recent_runs", lambda _pid: [])
    monkeypatch.setattr(builds, "remote_release_tags_at", lambda _sha: tags)


def test_wait_stops_on_an_untagged_commit_and_on_an_unreadable_origin(monkeypatch, capsys):
    _no_run(monkeypatch, [])
    assert builds.run_wait("07b1cabe36d1eb79a2ce629743a1e8c79765b398", timeout=1) == 4
    assert "release_tag.py cut" in capsys.readouterr().out
    _no_run(monkeypatch, None)
    assert builds.run_wait("07b1cabe36d1eb79a2ce629743a1e8c79765b398", timeout=1) == 4
    assert "could not read release tags" in capsys.readouterr().out


# --------------------------------------------------------------------------- #
# A tag Xcode Cloud never received (2026-11-05: release-1.3.0-20261105-63446054)
# --------------------------------------------------------------------------- #

SHA = "634460544c0a6234be97a6b717a8e62fbe83ae44"
TAG = "release-1.3.0-20261105-63446054"
# The Release workflow's repository listed 100 refs against origin's 101: the new tag was the one short.
XCODE_100 = [f"release-1.2.{i}-20261001-{i:08x}" for i in range(97)] + ["master", "develop", "2026.07.12"]


def test_missed_tags_names_the_tag_xcode_cloud_does_not_list():
    assert len(XCODE_100) == 100
    assert builds.missed_tags(XCODE_100, [TAG]) == [TAG]
    assert builds.missed_tags(XCODE_100 + [TAG], [TAG]) == []
    # a canonical name (refs/tags/...) is the same ref
    assert builds.missed_tags([f"refs/tags/{TAG}"], [TAG]) == []


def test_origin_ref_count_skips_peeled_lines():
    ls = (f"{SHA}\trefs/heads/master\n"
          f"8c3a93ee656ec4703b78edb68285da37edaf5fb1\trefs/tags/{TAG}\n"
          f"{SHA}\trefs/tags/{TAG}^{{}}\n")
    assert builds.ref_count(ls) == 2


def test_the_diagnosis_names_the_tag_the_counts_and_the_retrigger():
    msg = builds.format_diagnosis([TAG], 100, 101, SHA)
    assert TAG in msg
    assert "Xcode Cloud lists 100 refs, origin has 101" in msg
    assert "may cap" in msg  # 100 is a suspiciously round page
    assert (f'git -C ~/Development/m1k3 tag -a {TAG}-r2 {SHA} -m "re-trigger: Xcode Cloud missed {TAG}"'
            f" && git -C ~/Development/m1k3 push origin {TAG}-r2") in msg
    assert f"builds.py wait --commit {SHA}" in msg


def test_the_cap_caveat_only_at_one_hundred():
    assert "may cap" not in builds.format_diagnosis([TAG], 99, 101, SHA)


def test_a_missed_retrigger_bumps_its_suffix():
    msg = builds.format_diagnosis([TAG, f"{TAG}-r2"], 101, 103, SHA)
    assert f"tag -a {TAG}-r3 {SHA}" in msg


def test_nothing_missing_says_the_delay_is_xcode_clouds_own():
    msg = builds.format_diagnosis([], 101, 101, SHA, known=[TAG])
    assert TAG in msg and "knows" in msg
    assert "not a dropped push" in msg
    assert "tag -a" not in msg  # nothing to re-trigger


def test_a_known_retrigger_beside_a_missed_tag_is_not_a_dropped_push():
    # Today's live shape: the -r2 arrived, the original never did. Another -r2 would collide.
    msg = builds.format_diagnosis([TAG], 101, 102, SHA, known=[f"{TAG}-r2"])
    assert f"{TAG}-r2" in msg and f"{TAG} " in msg
    assert "not a dropped push" in msg
    assert "tag -a" not in msg


def test_diagnose_due_after_the_window_once():
    assert not builds.diagnose_due(None, now=1000.0, after=300, done=False)  # a run exists
    assert not builds.diagnose_due(100.0, now=399.9, after=300, done=False)
    assert builds.diagnose_due(100.0, now=400.0, after=300, done=False)
    assert not builds.diagnose_due(100.0, now=900.0, after=300, done=True)


class _Clock:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.t += s


def test_wait_diagnoses_once_and_keeps_waiting(monkeypatch, capsys):
    _no_run(monkeypatch, [TAG])
    monkeypatch.setattr(builds, "time", _Clock())
    calls = []
    monkeypatch.setattr(builds, "diagnose_missed_tag", lambda sha, pid=None: calls.append(sha) or "DIAG")
    assert builds.run_wait(SHA, timeout=900, diagnose_after=300) == 2  # it waited out the timeout
    assert calls == [SHA]
    assert capsys.readouterr().out.count("DIAG") == 1
