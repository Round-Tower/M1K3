"""Tests for branch_audit: verdicts by CONTENT, on a throwaway repo with a real origin.

Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.85, Prior: none
Pins the squash-merge case git log and patch-id miss, and that a dirty or locked worktree is never offered.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import branch_audit as m


#: The global hooksPath (format, TDD, MurphySig) runs on every throwaway commit and costs ~3 s each.
_NO_HOOKS = ("-c", "core.hooksPath=/dev/null")


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
    _git(repo, "checkout", "-q", "-b", "master")
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


def test_conflicting_branch_lists_the_files(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "fix/clash", "shared.txt", "one\nBRANCH\nthree\n")
    _commit(repo, "shared.txt", "one\nMASTER\nthree\n", "master edits the same line")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["fix/clash"]
    assert f.conflicts == ["shared.txt"]
    assert m.verdict(f) == "LIVE+CONFLICTS (1 file)"
    assert m.is_safe(f)[0] is False


def test_archive_tag_at_the_tip_is_archived(tmp_path):
    repo = _repo(tmp_path)
    _branch(repo, "spike/old", "spike.txt", "idea\n")
    _git(repo, "tag", "archive/2026-11-05/spike-old", "spike/old")
    _publish_master(repo)
    f = _by_name(m.gather(repo, "origin/master", _no_prs))["spike/old"]
    assert f.archive_tags == ["archive/2026-11-05/spike-old"]
    assert m.verdict(f) == "ARCHIVED"
    assert m.is_safe(f) == (True, "")


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
    assert m.verdict(_facts(archive_tags=["archive/a"], prs=open_pr)) == "ARCHIVED"
    assert m.verdict(_facts(prs=open_pr, conflicts=["a", "b"])) == "OPEN PR #9"
    assert m.verdict(_facts(conflicts=["a", "b"])) == "LIVE+CONFLICTS (2 files)"
    merged = [{"number": 7, "state": "MERGED", "mergedAt": "2026-11-01T00:00:00Z", "title": "t"}]
    assert m.verdict(_facts(prs=merged)) == "LIVE"  # a merged PR with more on top is still live
    assert m.verdict(_facts(merge_error="fatal: refusing to merge unrelated histories")) == "LIVE"


def test_safety_rules():
    assert m.is_safe(_facts(landed=True)) == (True, "")
    assert m.is_safe(_facts(landed=True, worktree="/w", dirty=0, worktree_locked=True))[0] is False
    assert m.is_safe(_facts(landed=True, worktree="/w", dirty=None))[0] is False  # unknown is not clean
    assert m.is_safe(_facts(archive_tags=["archive/a"], worktree="/w", dirty=3)) == (
        False, "worktree has 3 dirty files")
    assert m.is_safe(_facts())[0] is False


def test_missing_worktree_is_pruned_not_removed():
    f = _facts(landed=True, worktree="/gone", worktree_missing=True)
    assert m.is_safe(f) == (True, "")
    assert m.cleanup_commands([f]) == ["git worktree prune", "git branch -D b"]


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
    assert wts["master"] == m.Worktree("/r", locked=False, prunable=False)
    assert wts["feat/a"] == m.Worktree("/r/wt1", locked=True, prunable=False)
    assert wts["old"] == m.Worktree("/gone", locked=False, prunable=True)
    assert len(wts) == 3


def test_parse_merge_tree():
    assert m.parse_merge_tree("t1\n", 0) == ("t1", [])
    out = "t2\nmacos/a.swift\nmacos/b.swift\nmacos/a.swift\n"
    assert m.parse_merge_tree(out, 1) == ("t2", ["macos/a.swift", "macos/b.swift"])
