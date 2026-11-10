"""Tests for branch_audit: verdicts by CONTENT, on a throwaway repo with a real origin.

Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.85, Prior: none
Pins the squash-merge case git log and patch-id miss, and that a dirty or locked worktree is never offered.
Review: Kev + claude-opus-5.5, 2026-11-05 — folded the review: CI-proof git config, locked-before-missing,
no global prune, main worktree / empty / local-only archive / open-PR kept, timeouts, gh and render cases. Confidence 0.85.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import branch_audit as m


#: The global hooksPath (format, TDD, MurphySig) runs on every throwaway commit and costs ~3 s each.
#: Signing is pinned off too, so a runner (or a Mac) with commit/tag.gpgsign set still passes.
_NO_HOOKS = ("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false")


def _git(repo: Path, *args: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(repo), *_NO_HOOKS, "-c", "user.email=t@t", "-c", "user.name=t", *args],
        check=True, capture_output=True, text=True,
    )
    return out.stdout


def _commit(repo: Path, name: str, text: str, msg: str) -> None:
    (repo / name).write_text(text)
    _git(repo, "add", name)
    _git(repo, "commit", "-q", "-m", msg)


def _repo(tmp_path: Path) -> Path:
    """A clone of a bare origin, master pushed, with one shared file."""
    origin = tmp_path / "origin.git"
    subprocess.run(["git", *_NO_HOOKS, "init", "-q", "--bare", "-b", "master", str(origin)], check=True)
    repo = tmp_path / "repo"
    subprocess.run(["git", *_NO_HOOKS, "clone", "-q", str(origin), str(repo)], check=True, capture_output=True)
    _git(repo, "symbolic-ref", "HEAD", "refs/heads/master")  # whatever init.defaultBranch says
    _commit(repo, "shared.txt", "one\ntwo\nthree\n", "init")
    _git(repo, "push", "-q", "-u", "origin", "master")
    return repo


def _branch(repo: Path, name: str, file: str, text: str) -> None:
    _git(repo, "checkout", "-q", "-b", name, "master")
    _commit(repo, file, text, f"work on {name}")
    _git(repo, "checkout", "-q", "master")


def _publish_master(repo: Path) -> None:
    _git(repo, "push", "-q", "origin", "master")
    _git(repo, "fetch", "-q", "origin")


def _no_prs(_branch: str) -> list[dict]:
    return []


def _by_name(facts: list[m.BranchFacts]) -> dict[str, m.BranchFacts]:
    return {f.branch: f for f in facts}


# --- end to end on a real repo -------------------------------------------------


def test_squash_merged_branch_is_landed_and_offered(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/squashed", "feature.txt", "the feature\n")
    # Squash: master gets the same content as a NEW commit, so master..branch still lists it.
    _commit(repo, "feature.txt", "the feature\n", "feat: squashed (#1)")
    _commit(repo, "later.txt", "unrelated\n", "later work on master")
    _publish_master(repo)
    assert _git(repo, "log", "--oneline", "origin/master..feat/squashed").strip()  # git log says unmerged

    facts = _by_name(m.gather(repo, "origin/master", _no_prs))
    f = facts["feat/squashed"]
    assert f.landed
    assert m.verdict(f) == "LANDED"
    assert m.is_safe(f) == (True, "")
    assert "git branch -D feat/squashed" in m.cleanup_commands(list(facts.values()))
    assert "master" not in facts


def test_unmerged_branch_is_live_and_kept(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/open", "new.txt", "new\n")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["feat/open"]
    assert (f.ahead, f.behind) == (1, 0)
    assert not f.remote_exists
    assert m.verdict(f) == "LIVE"
    assert m.is_safe(f)[0] is False
    assert m.cleanup_commands([f]) == []


def test_behind_counts_master_commits_the_branch_lacks(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/old", "old.txt", "old\n")
    _commit(repo, "m1.txt", "1\n", "master one")
    _commit(repo, "m2.txt", "2\n", "master two")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["feat/old"]
    assert (f.ahead, f.behind) == (1, 2)
    assert "1 ahead, 2 behind" in m.render([f], "origin/master")


def test_a_branch_with_no_commits_of_its_own_is_not_offered(tmp_path):
    """A placeholder (just created off master, or a workflow's fresh worktree) is empty, not landed work."""
    repo = _repo(tmp_path)
    _git(repo, "branch", "eng/placeholder", "master")
    wt = tmp_path / "wt-placeholder"
    _git(repo, "worktree", "add", "-q", str(wt), "eng/placeholder")
    _publish_master(repo)
    facts = m.gather(repo, "origin/master", _no_prs)
    f = _by_name(facts)["eng/placeholder"]
    assert f.landed and f.ahead == 0
    assert m.verdict(f) == "LANDED (empty: 0 ahead)"
    assert m.is_safe(f)[0] is False
    assert m.cleanup_commands(facts) == []


def test_the_main_worktrees_branch_is_never_offered(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/done", "done.txt", "done\n")
    _commit(repo, "done.txt", "done\n", "feat: done (#2)")
    _publish_master(repo)
    _git(repo, "checkout", "-q", "feat/done")  # the repo itself sits on a landed branch
    facts = m.gather(repo, "origin/master", _no_prs)
    f = _by_name(facts)["feat/done"]
    assert m.verdict(f) == "LANDED"
    assert f.worktree_main
    safe, why = m.is_safe(f)
    assert safe is False and "main worktree" in why
    assert m.cleanup_commands(facts) == []


def test_a_locked_worktree_is_kept_even_when_its_directory_is_gone(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/done", "done.txt", "done\n")
    _commit(repo, "done.txt", "done\n", "feat: done (#2)")
    _publish_master(repo)
    wt = tmp_path / "wt-done"
    _git(repo, "worktree", "add", "-q", str(wt), "feat/done")
    _git(repo, "worktree", "lock", str(wt))
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["feat/done"]
    assert f.worktree_locked and not f.worktree_missing
    assert m.is_safe(f) == (False, "worktree is locked (in use)")
    assert "LOCKED" in m.render([f], "origin/master")

    subprocess.run(["rm", "-rf", str(wt)], check=True)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["feat/done"]
    assert f.worktree_locked and f.worktree_missing
    assert m.is_safe(f) == (False, "worktree is locked (in use)")
    assert m.cleanup_commands([f]) == []


def test_a_gone_worktree_is_removed_by_path_and_no_other_stale_entry_is_touched(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/done", "done.txt", "done\n")
    _commit(repo, "done.txt", "done\n", "feat: done (#2)")
    _branch(repo, "feat/live", "live.txt", "live\n")
    _publish_master(repo)
    gone, other = tmp_path / "wt-done", tmp_path / "wt-live"
    _git(repo, "worktree", "add", "-q", str(gone), "feat/done")
    _git(repo, "worktree", "add", "-q", str(other), "feat/live")
    subprocess.run(["rm", "-rf", str(gone), str(other)], check=True)

    facts = m.gather(repo, "origin/master", _no_prs)
    cmds = m.cleanup_commands(facts)
    assert not any("prune" in c for c in cmds)  # prune is repo-wide: it would drop feat/live's entry too
    assert cmds == [f"git worktree remove {_by_name(facts)['feat/done'].worktree}", "git branch -D feat/done"]
    for c in cmds:  # what Kev would paste, run on the throwaway repo
        _git(repo, *c.split()[1:])
    listed = _git(repo, "worktree", "list", "--porcelain")
    assert "refs/heads/feat/live" in listed and "refs/heads/feat/done" not in listed


def test_a_worktree_whose_parent_is_gone_too_is_unreachable_and_kept(tmp_path):
    """An unmounted volume looks like a deleted directory to git; only a present parent proves deletion."""
    repo = _repo(tmp_path)
    _branch(repo, "feat/done", "done.txt", "done\n")
    _commit(repo, "done.txt", "done\n", "feat: done (#2)")
    _publish_master(repo)
    vol = tmp_path / "Volumes" / "Scratch"
    vol.mkdir(parents=True)
    _git(repo, "worktree", "add", "-q", str(vol / "wt"), "feat/done")
    subprocess.run(["rm", "-rf", str(vol)], check=True)  # the drive is unplugged
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["feat/done"]
    assert f.worktree_unreachable
    safe, why = m.is_safe(f)
    assert safe is False and "unreachable" in why
    assert "unreachable" in m.render([f], "origin/master")


def test_unrelated_history_reports_the_merge_tree_error_and_is_kept(tmp_path):
    repo = _repo(tmp_path)
    _git(repo, "checkout", "-q", "--orphan", "orphan/x")
    _git(repo, "rm", "-rq", "--cached", ".")
    _commit(repo, "solo.txt", "alone\n", "orphan root")
    _git(repo, "checkout", "-q", "-f", "master")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["orphan/x"]
    assert f.merge_error and not f.landed
    assert m.verdict(f) == "LIVE"
    assert "merge-tree failed" in m.render([f], "origin/master")


def test_conflicting_branch_lists_the_files(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "fix/clash", "shared.txt", "one\nBRANCH\nthree\n")
    _commit(repo, "shared.txt", "one\nMASTER\nthree\n", "master edits the same line")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["fix/clash"]
    assert f.conflicts == ["shared.txt"]
    assert m.verdict(f) == "LIVE+CONFLICTS (1 file)"
    assert m.is_safe(f)[0] is False


def test_archive_tag_at_the_tip_is_archived_once_it_is_on_origin(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "spike/old", "spike.txt", "idea\n")
    _git(repo, "tag", "archive/2026-11-05/spike-old", "spike/old")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["spike/old"]
    assert f.archive_tags == ["archive/2026-11-05/spike-old"]
    assert f.archive_remote == []  # a lost tag push: the only copy is on this Mac
    assert m.verdict(f) == "ARCHIVED (local tag only)"
    assert m.is_safe(f)[0] is False
    assert "archive tags: archive/2026-11-05/spike-old (local only)" in m.render([f], "origin/master")

    _git(repo, "push", "-q", "origin", "archive/2026-11-05/spike-old")
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["spike/old"]
    assert f.archive_remote == ["archive/2026-11-05/spike-old"]
    assert m.verdict(f) == "ARCHIVED"
    assert m.is_safe(f) == (True, "")


def test_an_annotated_archive_tag_on_origin_counts(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "spike/old", "spike.txt", "idea\n")
    _git(repo, "tag", "-a", "-m", "parked", "archive/ann", "spike/old")
    _git(repo, "push", "-q", "origin", "archive/ann")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["spike/old"]
    assert m.verdict(f) == "ARCHIVED"


def test_an_archive_tag_on_origin_at_another_commit_does_not_count(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "spike/old", "spike.txt", "idea\n")
    _git(repo, "tag", "archive/moved", "master")
    _git(repo, "push", "-q", "origin", "archive/moved")
    _git(repo, "tag", "-f", "archive/moved", "spike/old")  # moved locally, never re-pushed
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["spike/old"]
    assert m.verdict(f) == "ARCHIVED (local tag only)"


def test_dirty_worktree_is_never_offered(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/done", "done.txt", "done\n")
    _commit(repo, "done.txt", "done\n", "feat: done (#2)")
    _publish_master(repo)
    wt = tmp_path / "wt-done"
    _git(repo, "worktree", "add", "-q", str(wt), "feat/done")
    (wt / "scratch.txt").write_text("unsaved thought\n")
    (wt / "done.txt").write_text("edited\n")

    facts = m.gather(repo, "origin/master", _no_prs)
    f = _by_name(facts)["feat/done"]
    assert Path(f.worktree).resolve() == wt.resolve()
    assert f.dirty == 2
    assert f.size  # du -sh ran
    assert m.verdict(f) == "LANDED"
    safe, why = m.is_safe(f)
    assert safe is False and "dirty" in why
    assert m.cleanup_commands(facts) == []


def test_clean_worktree_of_a_landed_branch_is_removed_first(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/done", "done.txt", "done\n")
    _commit(repo, "done.txt", "done\n", "feat: done (#2)")
    _publish_master(repo)
    wt = tmp_path / "wt-done"
    _git(repo, "worktree", "add", "-q", str(wt), "feat/done")
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["feat/done"]
    cmds = m.cleanup_commands([f])
    assert cmds[0].startswith("git worktree remove ") and cmds[0].endswith(str(f.worktree))
    assert cmds[1] == "git branch -D feat/done"


def test_open_pr_reads_from_gh(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "docs/pr", "doc.md", "words\n")
    _git(repo, "push", "-q", "origin", "docs/pr")
    _publish_master(repo)
    seen: list[str] = []

    def fake_gh(branch: str) -> list[dict]:
        seen.append(branch)
        return [{"number": 778, "state": "OPEN", "mergedAt": None, "title": "docs: a thing"}]

    f = _by_name(m.gather(repo, "origin/master", fake_gh))["docs/pr"]
    assert seen == ["docs/pr"]
    assert f.remote_exists
    assert m.verdict(f) == "OPEN PR #778"
    assert m.is_safe(f)[0] is False


def test_no_gh_skips_the_lookup(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "feat/x", "x.txt", "x\n")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", None))["feat/x"]
    assert f.prs is None
    assert m.verdict(f) == "LIVE"
    assert "skipped" in m.render([f], "origin/master")


def test_report_ends_with_the_cleanup_block(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "spike/old", "spike.txt", "idea\n")
    _git(repo, "tag", "archive/x", "spike/old")
    _git(repo, "push", "-q", "origin", "archive/x")
    _branch(repo, "feat/open", "new.txt", "new\n")
    _publish_master(repo)
    out = m.render(m.gather(repo, "origin/master", _no_prs), "origin/master")
    assert "VERDICT: ARCHIVED (safe to delete)" in out
    assert "VERDICT: LIVE" in out
    tail = out.split("Cleanup")[-1]
    assert "git branch -D spike/old" in tail
    assert "feat/open" not in tail


def test_main_never_runs_a_cleanup_command(tmp_path, capsys):
    repo = _repo(tmp_path)
    _branch(repo, "spike/old", "spike.txt", "idea\n")
    _git(repo, "tag", "archive/x", "spike/old")
    _git(repo, "push", "-q", "origin", "archive/x")
    _publish_master(repo)
    assert m.main(["--repo", str(repo), "--no-gh"]) == 0
    assert "git branch -D spike/old" in capsys.readouterr().out
    assert "spike/old" in _git(repo, "branch", "--list", "spike/old")  # still there


# --- pure: verdict precedence and safety ---------------------------------------


def _facts(**kw) -> m.BranchFacts:
    base = dict(branch="b", remote_exists=False, prs=[], worktree=None, worktree_locked=False,
                worktree_missing=False, dirty=None, ahead=1, behind=0, landed=False,
                conflicts=[], merge_error=None, archive_tags=[], size=None)
    base.update(kw)
    return m.BranchFacts(**base)


def test_verdict_precedence():
    open_pr = [{"number": 9, "state": "OPEN", "mergedAt": None, "title": "t"}]
    assert m.verdict(_facts(landed=True, archive_tags=["archive/a"], prs=open_pr)) == "LANDED"
    assert m.verdict(_facts(archive_tags=["archive/a"], archive_remote=["archive/a"], prs=open_pr)) == "ARCHIVED"
    assert m.verdict(_facts(prs=open_pr, conflicts=["a", "b"])) == "OPEN PR #9"
    assert m.verdict(_facts(conflicts=["a", "b"])) == "LIVE+CONFLICTS (2 files)"
    merged = [{"number": 7, "state": "MERGED", "mergedAt": "2026-11-01T00:00:00Z", "title": "t"}]
    assert m.verdict(_facts(prs=merged)) == "LIVE"  # a merged PR with more on top is still live
    assert m.verdict(_facts(merge_error="fatal: refusing to merge unrelated histories")) == "LIVE"
    assert m.verdict(_facts(archive_tags=["archive/a"], archive_remote=None)) == "ARCHIVED (local tag only)"
    assert m.verdict(_facts(landed=True, ahead=0)) == "LANDED (empty: 0 ahead)"


def test_safety_rules():
    assert m.is_safe(_facts(landed=True)) == (True, "")
    assert m.is_safe(_facts(landed=True, worktree="/w", dirty=0, worktree_locked=True))[0] is False
    assert m.is_safe(_facts(landed=True, worktree="/w", dirty=None))[0] is False  # unknown is not clean
    assert m.is_safe(_facts(archive_tags=["archive/a"], archive_remote=["archive/a"], worktree="/w", dirty=3)) == (
        False, "worktree has 3 dirty files")
    assert m.is_safe(_facts())[0] is False
    # locked wins over missing: git keeps a locked entry whose directory is gone (an unplugged drive)
    assert m.is_safe(_facts(landed=True, worktree="/w", worktree_missing=True, worktree_locked=True)) == (
        False, "worktree is locked (in use)")
    assert m.is_safe(_facts(landed=True, worktree="/w", worktree_main=True, dirty=0))[0] is False
    assert m.is_safe(_facts(landed=True, ahead=None, behind=None)) == (False, "ahead/behind unreadable")


def test_an_open_pr_keeps_a_landed_or_archived_branch():
    open_pr = [{"number": 9, "state": "OPEN", "mergedAt": None, "title": "t"}]
    for f in (_facts(landed=True, prs=open_pr),
              _facts(archive_tags=["archive/a"], archive_remote=["archive/a"], prs=open_pr)):
        assert m.is_safe(f) == (False, "PR #9 is still open")
    out = m.render([_facts(landed=True, prs=open_pr)], "origin/master")
    assert "VERDICT: LANDED (keep: PR #9 is still open)" in out


def test_render_shows_dirty_size_lock_and_unknown_counts():
    out = m.render([_facts(branch="feat/a", worktree="/w", dirty=2, size="1.3G", worktree_locked=True,
                           ahead=None, behind=None)], "origin/master")
    assert "worktree: /w  dirty: 2  size: 1.3G  LOCKED" in out
    assert "vs origin/master: ? ahead, ? behind" in out
    out = m.render([_facts(branch="feat/b", worktree="/gone", worktree_missing=True)], "origin/master")
    assert "worktree: /gone (missing on disk)" in out


def test_a_timeout_is_a_failed_result_not_a_traceback(monkeypatch):
    def slow(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))
    monkeypatch.setattr(m.subprocess, "run", slow)
    p = m._run(["du", "-sh", "/huge"], timeout=1)
    assert p.returncode == 124 and "timed out" in p.stderr and p.stdout == ""


def test_gh_lookup_reads_json_and_raises_the_last_stderr_line(monkeypatch, tmp_path):
    calls: list[list[str]] = []

    def fake_run(cmd, cwd=None, timeout=120):
        calls.append(cmd)
        if cmd[4] == "bad":
            return subprocess.CompletedProcess(cmd, 1, "", "warning\nHTTP 401: Bad credentials\n")
        return subprocess.CompletedProcess(cmd, 0, '[{"number": 5, "state": "MERGED"}]', "")
    monkeypatch.setattr(m, "_run", fake_run)
    lookup = m.gh_lookup(tmp_path)
    assert lookup("feat/a") == [{"number": 5, "state": "MERGED"}]
    assert calls[0][:5] == ["gh", "pr", "list", "--head", "feat/a"]
    try:
        lookup("bad")
    except RuntimeError as e:
        assert str(e) == "HTTP 401: Bad credentials"
    else:
        raise AssertionError("a failed gh lookup must raise")


def test_missing_worktree_is_removed_by_path_never_a_global_prune():
    f = _facts(landed=True, worktree="/gone", worktree_missing=True)
    assert m.is_safe(f) == (True, "")
    assert m.cleanup_commands([f]) == ["git worktree remove /gone", "git branch -D b"]


def test_cleanup_quotes_odd_paths():
    f = _facts(branch="feat/a", landed=True, worktree="/tmp/has space", dirty=0)
    assert m.cleanup_commands([f]) == ["git worktree remove '/tmp/has space'", "git branch -D feat/a"]


def test_parse_worktrees():
    porcelain = (
        "worktree /r\nHEAD abc\nbranch refs/heads/master\n\n"
        "worktree /r/wt1\nHEAD abc\nbranch refs/heads/feat/a\nlocked claude agent x\n\n"
        "worktree /r/wt2\nHEAD def\ndetached\n\n"
        "worktree /gone\nHEAD abc\nbranch refs/heads/old\nprunable gitdir file points to non-existent location\n"
    )
    wts = m.parse_worktrees(porcelain)
    assert wts["master"] == m.Worktree("/r", locked=False, prunable=False, main=True)
    assert wts["feat/a"] == m.Worktree("/r/wt1", locked=True, prunable=False)
    assert wts["old"] == m.Worktree("/gone", locked=False, prunable=True)
    assert len(wts) == 3


def test_parse_merge_tree():
    assert m.parse_merge_tree("t1\n", 0) == ("t1", [])
    out = "t2\nmacos/a.swift\nmacos/b.swift\nmacos/a.swift\n"
    assert m.parse_merge_tree(out, 1) == ("t2", ["macos/a.swift", "macos/b.swift"])
