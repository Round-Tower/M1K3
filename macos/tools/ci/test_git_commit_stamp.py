"""Tests for git_commit_stamp: clean / dirty / no-git / CI_COMMIT."""

import subprocess

import git_commit_stamp as m


def _git(repo, *args):
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t", *args],
        check=True, capture_output=True,
    )


def _repo(tmp_path):
    _git(tmp_path, "init", "-q")
    (tmp_path / "a.txt").write_text("a")
    _git(tmp_path, "add", "a.txt")
    _git(tmp_path, "commit", "-q", "-m", "init")
    return tmp_path


def test_clean_tree_is_the_short_sha(tmp_path):
    repo = _repo(tmp_path)
    sha = m.stamp(repo, env={})
    assert sha and not sha.endswith("-dirty") and sha != "unknown"


def test_dirty_tree_gets_suffix(tmp_path):
    repo = _repo(tmp_path)
    clean = m.stamp(repo, env={})
    (repo / "a.txt").write_text("changed")
    assert m.stamp(repo, env={}) == clean + "-dirty"


def test_untracked_file_counts_as_dirty(tmp_path):
    repo = _repo(tmp_path)
    (repo / "new.txt").write_text("x")
    assert m.stamp(repo, env={}).endswith("-dirty")


def test_no_git_is_unknown(tmp_path):
    assert m.stamp(tmp_path, env={}) == "unknown"


def test_ci_commit_wins_and_is_shortened(tmp_path):
    full = "0123456789abcdef0123456789abcdef01234567"
    assert m.stamp(tmp_path, env={"CI_COMMIT": full}) == full[:8]


def test_blank_ci_commit_falls_through(tmp_path):
    assert m.stamp(tmp_path, env={"CI_COMMIT": "  "}) == "unknown"
