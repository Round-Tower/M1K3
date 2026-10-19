"""Pins build_eval_app.py: an eval arm's app is built from a COMMIT, so the commit sha is its
identity. On 2026-10-18 one "03aefb58-dirty" stamp covered two different trees (the untracked
ThinkBudget files came and went), and the pipeline's `grep "^03aefb58"` passed it. The checks
that decide a build is the one the arm claims are pure and pinned here; xcodebuild never runs —
the build itself is a seam (`_run`) the tests replace.

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
Review: Kev + claude-opus-5-5, 2026-10-18 — review folds: the git fixtures drop inherited GIT_* variables (a hook's
GIT_DIR would point them at the real repo); `_run` runs a real child, so "the .app path is the only stdout line"
rests on more than a fake; exit 2, an xcodegen failure, a non-zero xcodebuild beside a good log, and a dry run on
a dirty tree are pinned at main.
Review: Kev + claude-opus-5-5, 2026-10-19 — the build's git environment: `build_env` turns core.fsmonitor off for the
child, appended after any GIT_CONFIG_* entries already set, and a real git under `_run` reads it.
"""

import os
import plistlib
import subprocess
import sys
from pathlib import Path

import build_eval_app as bea
import pytest

HEAD = "03aefb58" + "c0" * 16  # a full 40-character sha
OK_LOG = "CompileSwift normal arm64 ThinkBudget.swift\n** BUILD SUCCEEDED **\n"


# ── the build's git environment (2026-10-19) ─────────────────────────────────


def test_the_build_turns_git_fsmonitor_off_and_keeps_the_rest():
    env = bea.build_env({"PATH": "/bin"})
    assert env["GIT_CONFIG_COUNT"] == "1"
    assert (env["GIT_CONFIG_KEY_0"], env["GIT_CONFIG_VALUE_0"]) == ("core.fsmonitor", "false")
    assert env["PATH"] == "/bin"


def test_build_env_appends_after_git_config_entries_already_set():
    env = bea.build_env({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "x"})
    assert env["GIT_CONFIG_COUNT"] == "2"
    assert (env["GIT_CONFIG_KEY_0"], env["GIT_CONFIG_VALUE_0"]) == ("user.name", "x")
    assert (env["GIT_CONFIG_KEY_1"], env["GIT_CONFIG_VALUE_1"]) == ("core.fsmonitor", "false")


def test_a_git_the_build_runs_reads_fsmonitor_off(tmp_path, monkeypatch):
    """A fresh -derivedDataPath hung at "Resolve Package Graph" with core.fsmonitor on (Kev's global config):
    SwiftPM sat in `git status` on submodule checkouts beside new fsmonitor daemons. The child `_run` starts must
    read the override, so a real git is asked."""
    hermetic_git(monkeypatch)
    global_config = tmp_path / "gitconfig"
    global_config.write_text("[core]\n\tfsmonitor = true\n")  # the global config that hung the build
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(global_config))
    log_path = tmp_path / "eval-build.log"
    with log_path.open("w") as log:
        code = bea._run(["git", "config", "--get", "core.fsmonitor"], tmp_path, log)
    assert code == 0
    assert log_path.read_text().strip() == "false"


# ── verify_build (pure) ──────────────────────────────────────────────────────

def test_verify_passes_a_clean_build_stamped_with_head():
    assert bea.verify_build(OK_LOG, "03aefb58", HEAD) == []
    # git widens `--short` as the repo grows, and Xcode Cloud stamps 8 characters: any hex
    # prefix of 7+ is the same commit. A short head equal to the stamp passes too.
    assert bea.verify_build(OK_LOG, "03aefb5", HEAD) == []
    assert bea.verify_build(OK_LOG, "03aefb58", "03aefb58") == []


def test_verify_refuses_a_dirty_stamp():
    # 2026-10-18: `grep "^03aefb58"` matched "03aefb58-dirty" — a tree nobody can name again.
    problems = bea.verify_build(OK_LOG, "03aefb58-dirty", HEAD)
    assert len(problems) == 1 and "03aefb58-dirty" in problems[0]


@pytest.mark.parametrize("stamp", [None, "", "unknown", "deadbeef", "03aefb", "03AEFB58", "03aefb58 "])
def test_verify_refuses_a_missing_short_or_foreign_stamp(stamp):
    problems = bea.verify_build(OK_LOG, stamp, HEAD)
    assert len(problems) == 1


def test_verify_needs_build_succeeded():
    problems = bea.verify_build("** BUILD FAILED **\n", "03aefb58", HEAD)
    assert problems and "BUILD SUCCEEDED" in problems[0]


def test_verify_counts_error_lines_even_beside_a_success_line():
    # The scratch builds counted `grep -c ' error: '`: a success line beside an error is not a pass.
    log = "a.swift:3:1: error: cannot find 'x' in scope\nld: error: missing symbol\n** BUILD SUCCEEDED **\n"
    problems = bea.verify_build(log, "03aefb58", HEAD)
    assert len(problems) == 1
    assert "2 error lines" in problems[0] and "cannot find 'x'" in problems[0]


def test_the_build_line_is_the_one_the_arms_were_built_with():
    # build10.zsh's line, flag for flag (worktree builds need the two -skip validations).
    gen, build = bea.commands(Path("/dd"))
    assert gen == ["xcodegen", "generate"]
    assert build == ["xcodebuild", "-scheme", "M1K3", "-configuration", "Debug",
                     "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "/dd",
                     "-skipPackagePluginValidation", "-skipMacroValidation",
                     "-onlyUsePackageVersionsFromResolvedFile", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build"]
    assert bea.app_path(Path("/dd")) == Path("/dd/Build/Products/Debug/M1K3.app")


# ── the dirty refusal (a real, hermetic git repo) ───────────────────────────

def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def hermetic_git(monkeypatch) -> None:
    # Run from a git hook, pytest inherits GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE, and `git -C <tmp>` would then
    # read and write the REAL repository's index. Drop every GIT_* first; then no global or system config, so no
    # hooks path, signing or templates leak in.
    for key in [k for k in os.environ if k.startswith("GIT_")]:
        monkeypatch.delenv(key)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")


@pytest.fixture
def repo(tmp_path, monkeypatch):
    hermetic_git(monkeypatch)
    wt = tmp_path / "wt"
    (wt / "macos").mkdir(parents=True)
    (wt / "macos/project.yml").write_text("name: M1K3\n")
    git(wt, "init", "-q")
    git(wt, "add", "-A")
    git(wt, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
    return wt


def test_a_clean_checkout_may_build(repo):
    assert bea.dirty_reason(repo) is None


def test_an_untracked_file_makes_the_tree_dirty(repo):
    # 2026-10-18: ThinkBudget.swift and its tests were `??` — `git diff HEAD` never saw them.
    (repo / "macos/ThinkBudget.swift").write_text("// new\n")
    reason = bea.dirty_reason(repo)
    assert reason and "ThinkBudget.swift" in reason


def test_a_modified_tracked_file_makes_the_tree_dirty(repo):
    (repo / "macos/project.yml").write_text("name: changed\n")
    reason = bea.dirty_reason(repo)
    assert reason and "project.yml" in reason


def test_a_directory_that_is_not_a_checkout_is_refused_with_exit_2(tmp_path, monkeypatch, capsys):
    hermetic_git(monkeypatch)
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path))
    lonely = tmp_path / "lonely"
    lonely.mkdir()
    assert "not a git checkout" in bea.dirty_reason(lonely)
    monkeypatch.setattr(bea, "_run", lambda *a, **k: pytest.fail("a non-checkout was built"))
    assert bea.main([str(lonely), str(tmp_path / "dd")]) == 2
    captured = capsys.readouterr()
    assert captured.out == "" and "not a git checkout" in captured.err


def test_main_refuses_a_dirty_tree_before_building(repo, tmp_path, monkeypatch, capsys):
    (repo / "scratch.txt").write_text("x\n")
    monkeypatch.setattr(bea, "_run", lambda *a, **k: pytest.fail("a dirty tree was built"))
    assert bea.main([str(repo), str(tmp_path / "dd")]) == 3
    assert "scratch.txt" in capsys.readouterr().err


def test_dry_run_refuses_a_dirty_tree_too(repo, tmp_path, monkeypatch, capsys):
    (repo / "scratch.txt").write_text("x\n")
    monkeypatch.setattr(bea, "_run", lambda *a, **k: pytest.fail("a dry run built"))
    assert bea.main([str(repo), str(tmp_path / "dd"), "--dry-run"]) == 3
    captured = capsys.readouterr()
    assert captured.out == "" and "scratch.txt" in captured.err


def test_dry_run_prints_both_commands_and_builds_nothing(repo, tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(bea, "_run", lambda *a, **k: pytest.fail("a dry run built"))
    dd = tmp_path / "dd"
    assert bea.main([str(repo), str(dd), "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "xcodegen generate" in out
    assert "-onlyUsePackageVersionsFromResolvedFile" in out and "-derivedDataPath " + str(dd) in out
    assert str(repo / "macos") in out, "the commands run in the worktree's macos/"
    assert not dd.exists()


# ── main's glue, with the build replaced by what xcodebuild leaves behind ──

def fake_build(stamp: str | None, log_text: str = OK_LOG, dirty_after_xcodegen: bool = False,
               codes: dict[str, int] | None = None):
    calls: list[list[str]] = []

    def run(cmd: list[str], cwd: Path, log) -> int:
        calls.append(cmd)
        if cmd[0] == "xcodegen" and dirty_after_xcodegen:
            (cwd / "Generated.swift").write_text("// tracked by nobody\n")
        if cmd[0] == "xcodebuild":
            plist = bea.app_path(Path(cmd[cmd.index("-derivedDataPath") + 1])) / "Contents/Info.plist"
            plist.parent.mkdir(parents=True)
            plist.write_bytes(plistlib.dumps({} if stamp is None else {"GitCommitSHA": stamp}))
            log.write(log_text)
        return (codes or {}).get(cmd[0], 0)
    return run, calls


def test_main_prints_the_app_path_after_a_verified_build(repo, tmp_path, monkeypatch, capsys):
    short = git(repo, "rev-parse", "--short", "HEAD").strip()
    run, calls = fake_build(short)
    monkeypatch.setattr(bea, "_run", run)
    dd = tmp_path / "dd"
    assert bea.main([str(repo), str(dd)]) == 0
    assert capsys.readouterr().out.strip() == str(bea.app_path(dd)), "stdout is the app path alone: APP=$(…)"
    assert [c[0] for c in calls] == ["xcodegen", "xcodebuild"]
    assert "BUILD SUCCEEDED" in (dd / "eval-build.log").read_text()


def test_main_fails_a_build_stamped_dirty(repo, tmp_path, monkeypatch, capsys):
    short = git(repo, "rev-parse", "--short", "HEAD").strip()
    run, _ = fake_build(short + "-dirty")
    monkeypatch.setattr(bea, "_run", run)
    assert bea.main([str(repo), str(tmp_path / "dd")]) == 4
    captured = capsys.readouterr()
    assert captured.out == "" and "-dirty" in captured.err


def test_main_fails_a_build_with_no_stamp(repo, tmp_path, monkeypatch, capsys):
    run, _ = fake_build(None)
    monkeypatch.setattr(bea, "_run", run)
    assert bea.main([str(repo), str(tmp_path / "dd")]) == 4
    assert "GitCommitSHA" in capsys.readouterr().err


def test_main_stops_when_xcodegen_dirties_the_tree(repo, tmp_path, monkeypatch, capsys):
    run, calls = fake_build("unused", dirty_after_xcodegen=True)
    monkeypatch.setattr(bea, "_run", run)
    assert bea.main([str(repo), str(tmp_path / "dd")]) == 4
    assert [c[0] for c in calls] == ["xcodegen"], "no xcodebuild on a tree xcodegen dirtied"
    assert "Generated.swift" in capsys.readouterr().err


def test_main_stops_when_xcodegen_fails(repo, tmp_path, monkeypatch, capsys):
    run, calls = fake_build("unused", codes={"xcodegen": 1})
    monkeypatch.setattr(bea, "_run", run)
    assert bea.main([str(repo), str(tmp_path / "dd")]) == 4
    assert [c[0] for c in calls] == ["xcodegen"]
    captured = capsys.readouterr()
    assert captured.out == "" and "xcodegen failed" in captured.err and "eval-build.log" in captured.err


def test_main_fails_a_non_zero_xcodebuild_even_beside_a_good_log_and_stamp(repo, tmp_path, monkeypatch, capsys):
    # The log and the stamp are the verdict, and the exit code still counts: all three must agree.
    short = git(repo, "rev-parse", "--short", "HEAD").strip()
    run, _ = fake_build(short, codes={"xcodebuild": 65})
    monkeypatch.setattr(bea, "_run", run)
    assert bea.main([str(repo), str(tmp_path / "dd")]) == 4
    captured = capsys.readouterr()
    assert captured.out == "" and "xcodebuild exited 65" in captured.err


def test_run_sends_the_childs_output_to_the_log_and_never_to_stdout(tmp_path, capfd):
    # APP=$(build_eval_app.py …) takes stdout whole: one stray xcodebuild line there and APP is garbage.
    log_path = tmp_path / "eval-build.log"
    with open(log_path, "w") as log:
        log.write("header\n")
        script = "import sys; print('to stdout'); print('to stderr', file=sys.stderr); sys.exit(3)"
        code = bea._run([sys.executable, "-c", script], tmp_path, log)
    assert code == 3
    assert log_path.read_text().splitlines()[0] == "header", "what the runner wrote first stays first"
    assert {"to stdout", "to stderr"} <= set(log_path.read_text().splitlines())
    captured = capfd.readouterr()
    assert captured.out == "" and captured.err == ""
