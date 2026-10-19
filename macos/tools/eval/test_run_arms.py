"""Pins run_arms.py: one suite file in, one run_chateval per arm out. On 2026-10-18 eleven
hand-rolled evals*.zsh scripts did this, and zsh reads a script as it runs, so editing one
mid-chain tore the arms still queued. The runner reads its suite ONCE. What it decides — the
suite's shape, each arm's argv, which arms are already done, which live app comes back at the
end — is pinned here; nothing launches (the arm runner and the process reads are seams).

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
Review: Kev + claude-opus-5-5, 2026-10-18 — review folds: the fakes model the Mac (an arm quits the live app, `open`
brings it back), so the relaunch is pinned as seen-at-the-start, opened-at-the-end, proven up; a resumed run still
knows the live app; exit 0 without a scorecard fails and exit 8 is its own line; the driver file appends; an
interrupted or SIGTERMed runner stops run_chateval with SIGTERM; an eval app left running stops the run.
Review: Kev + claude-opus-5-5, 2026-10-19 — a resume re-runs an arm whose JSON doesn't parse.
"""

import json
import re
import signal
import sys
from pathlib import Path

import pytest
import run_arms as ra

APP = "/dd/Build/Products/Debug/M1K3.app"
SHARED = ["--brains", "lil", "--thinking", "always", "--kinds", "reasoning", "--repeats", "2"]


def suite_doc(**over) -> dict:
    doc = {
        "app": APP,
        "outDir": "out",
        "notes": "Budget forcing A/B",
        "args": SHARED,
        "arms": [
            {"name": "force1024", "timeoutMin": 100, "notes": "forced close at 1024 tokens",
             "args": ["--app-arg=-thinkBudgetTokens", "--app-arg=1024"]},
            {"name": "cut4000", "timeoutMin": 110},
        ],
    }
    doc.update(over)
    return doc


def write_suite(tmp_path: Path, doc: dict | None = None) -> Path:
    path = tmp_path / "suite.json"
    path.write_text(json.dumps(suite_doc() if doc is None else doc))
    return path


# ── the suite ────────────────────────────────────────────────────────────────

def test_load_suite_reads_the_app_the_out_dir_and_the_arms(tmp_path):
    suite = ra.load_suite(write_suite(tmp_path))
    assert suite.app == Path(APP)
    assert suite.out_dir == (tmp_path / "out").resolve(), "a relative path resolves against the suite file"
    assert suite.args == tuple(SHARED) and suite.notes == "Budget forcing A/B"
    assert [a.name for a in suite.arms] == ["force1024", "cut4000"]
    assert suite.arms[0].timeout_min == 100
    assert suite.arms[1].args == () and suite.arms[1].notes == ""


def _drop(key):
    doc = suite_doc()
    del doc[key]
    return doc


def _arm(**over):
    arm = {"name": "x", "timeoutMin": 10}
    arm.update(over)
    return suite_doc(arms=[arm])


@pytest.mark.parametrize("doc, why", [
    (_drop("app"), "app"),
    (_drop("outDir"), "outDir"),
    (_drop("arms"), "arms"),
    (suite_doc(arms=[]), "arms"),
    (suite_doc(timeout=5), "timeout"),  # a typo'd key would be silently ignored otherwise
    (_arm(timeout=5), "timeout"),
    (_arm(timeoutMin=0), "timeoutMin"),
    (_arm(timeoutMin="100"), "timeoutMin"),
    (_arm(timeoutMin=True), "timeoutMin"),
    (suite_doc(arms=[{"name": "x"}]), "timeoutMin"),
    (_arm(name="a/b"), "a/b"),
    (_arm(name=".hidden"), ".hidden"),
    (_arm(args="--repeats 2"), "list of strings"),
    (_arm(notes=3), "notes"),
    (suite_doc(arms=[{"name": "x", "timeoutMin": 1}, {"name": "x", "timeoutMin": 2}]), "twice"),
    # one binary per comparison: an arm can't swap the app, the outputs or the relaunch rule
    (_arm(args=["--app", "/other/M1K3.app"]), "--app"),
    (_arm(args=["--save-to=/elsewhere.json"]), "--save-to"),
    (_arm(args=["--no-relaunch"]), "--no-relaunch"),
    (suite_doc(args=["--timeout-min", "5"]), "--timeout-min"),
    (_arm(args=["--dry-run"]), "--dry-run"),
])
def test_a_malformed_suite_is_refused_with_the_reason(tmp_path, doc, why):
    with pytest.raises(ValueError, match=re.escape(why)):
        ra.load_suite(write_suite(tmp_path, doc))


def test_an_unparseable_suite_exits_2(tmp_path, capsys):
    bad = tmp_path / "suite.json"
    bad.write_text("{not json")
    assert ra.main([str(bad)]) == 2
    assert "suite.json" in capsys.readouterr().err


# ── argv per arm ─────────────────────────────────────────────────────────────

def test_each_arm_runs_run_chateval_direct_on_the_one_app(tmp_path):
    suite = ra.load_suite(write_suite(tmp_path))
    out = suite.out_dir
    assert ra.arm_argv(suite, suite.arms[0], python="python3") == [
        "python3", "-I", "-u", str(ra.RUN_CHATEVAL),
        "--name", "force1024", "--direct", "--app", APP,
        "--save-to", str(out / "force1024.json"), "--log", str(out / "force1024.log"),
        "--no-relaunch", "--timeout-min", "100",
        *SHARED, "--app-arg=-thinkBudgetTokens", "--app-arg=1024",
        "--notes", "Budget forcing A/B: forced close at 1024 tokens",
    ]
    assert ra.RUN_CHATEVAL == Path(ra.__file__).with_name("run_chateval.py")


def test_notes_are_the_suites_then_the_arms_and_absent_when_neither(tmp_path):
    suite = ra.load_suite(write_suite(tmp_path))
    assert ra.arm_argv(suite, suite.arms[1])[-2:] == ["--notes", "Budget forcing A/B"]
    bare = ra.load_suite(write_suite(tmp_path, suite_doc(notes="", arms=[{"name": "x", "timeoutMin": 1}])))
    assert "--notes" not in ra.arm_argv(bare, bare.arms[0])


# ── the run ──────────────────────────────────────────────────────────────────
# The fakes behave like the Mac does, so the relaunch tests pin what really happens there: an arm quits the
# live app (run_chateval's arm 1 does) and its eval app exits with it; `open` brings the live app back.

HOME_LIVE = str(Path.home() / "Applications/M1K3.app")
LIVE_EXE = HOME_LIVE + "/Contents/MacOS/M1K3"
EVAL_EXE = APP + "/Contents/MacOS/M1K3"


class Recorder:
    """Stands in for the arm runner, the process table and `open`."""

    def __init__(self, monkeypatch, running=(), codes=None, during=None, unsaved=(), leaves=None,
                 open_code=0, comes_back=True):
        self.running = list(running)
        self.argvs: list[list[str]] = []
        self.opened: list[str] = []
        self.codes = codes or {}
        self.during = during
        self.unsaved = set(unsaved)  # arms that exit 0 yet leave no scorecard
        self.leaves = leaves  # the arm whose eval app is still up after it
        self.open_code, self.comes_back = open_code, comes_back
        monkeypatch.setattr(ra, "run_arm", self.run_arm)
        monkeypatch.setattr(ra, "_running", lambda: list(self.running))
        monkeypatch.setattr(ra, "_open", self.open)
        monkeypatch.setattr(ra, "OPEN_RETRY_S", 0)
        monkeypatch.setattr(ra, "REOPEN_WAIT_S", 0)

    def run_arm(self, argv: list[str], driver: Path) -> int:
        name = argv[argv.index("--name") + 1]
        save = Path(argv[argv.index("--save-to") + 1])
        assert driver == save.with_name(f"{name}.driver.txt")
        assert self.opened == [], "the live app comes back at the end, never while arms run"
        self.argvs.append(argv)
        # run_chateval quit the live app, and its eval app exited with it (for `leaves`, it did not)
        self.running = [(77, EVAL_EXE)] if name == self.leaves else []
        if self.during:
            self.during(name)
        code = self.codes.get(name, 0)
        if code in (0, 8) and name not in self.unsaved:  # run_chateval writes the scorecard on 0 and on 8
            save.write_text(json.dumps({"runs": []}))
        return code

    def open(self, app: str) -> int:
        self.opened.append(app)
        if self.open_code == 0 and self.comes_back:
            self.running.append((99, app + "/Contents/MacOS/M1K3"))
        return self.open_code

    @property
    def names(self) -> list[str]:
        return [a[a.index("--name") + 1] for a in self.argvs]


def marker(tmp_path: Path) -> Path:
    return tmp_path / "out" / ra.LIVE_MARKER


def test_an_arm_whose_json_exists_is_skipped(tmp_path, monkeypatch, capsys):
    path = write_suite(tmp_path)
    (tmp_path / "out").mkdir()
    (tmp_path / "out/force1024.json").write_text("{}")
    rec = Recorder(monkeypatch)
    assert ra.main([str(path)]) == 0
    assert rec.names == ["cut4000"]
    assert "force1024" in capsys.readouterr().out


def test_the_suite_is_read_once_so_editing_it_mid_run_changes_nothing(tmp_path, monkeypatch):
    path = write_suite(tmp_path)

    def edit(name):
        if name == "force1024":
            path.write_text(json.dumps(suite_doc(arms=[{"name": "sneaky", "timeoutMin": 1}])))
    rec = Recorder(monkeypatch, during=edit)
    assert ra.main([str(path)]) == 0
    assert rec.names == ["force1024", "cut4000"]
    assert rec.argvs[1][rec.argvs[1].index("--timeout-min") + 1] == "110"


def test_a_failed_arm_does_not_stop_the_rest_and_the_run_exits_1(tmp_path, monkeypatch, capsys):
    rec = Recorder(monkeypatch, codes={"force1024": 6})
    assert ra.main([str(write_suite(tmp_path))]) == 1
    assert rec.names == ["force1024", "cut4000"]
    captured = capsys.readouterr()
    assert "force1024 exit=6" in captured.out
    assert "force1024" in captured.err and "cut4000" not in captured.err


def test_exit_0_without_a_scorecard_is_a_failed_arm(tmp_path, monkeypatch, capsys):
    # The exit code is not the verdict: an arm is done when its JSON is there and parses.
    Recorder(monkeypatch, unsaved={"force1024"})
    assert ra.main([str(write_suite(tmp_path))]) == 1
    err = capsys.readouterr().err
    assert "force1024" in err and "no scorecard" in err


def test_exit_8_keeps_the_scorecard_says_so_and_a_rerun_skips_it(tmp_path, monkeypatch, capsys):
    # run_chateval's 8: the scorecard is complete, then the app exited non-zero. The JSON is final (a re-run skips
    # the arm), so the run says that instead of calling the arm failed and leaving it silently skipped.
    path = write_suite(tmp_path)
    Recorder(monkeypatch, codes={"force1024": 8})
    assert ra.main([str(path)]) == 1
    captured = capsys.readouterr()
    assert "force1024" in captured.err and "scorecard saved, but the app exited non-zero" in captured.err
    assert "no scorecard" not in captured.err
    rec = Recorder(monkeypatch)
    assert ra.main([str(path)]) == 0
    assert rec.names == []


def test_dry_run_prints_each_arms_argv_and_runs_nothing(tmp_path, monkeypatch, capsys):
    live = "/Applications/M1K3.app"
    rec = Recorder(monkeypatch, running=[(7, live + "/Contents/MacOS/M1K3")])
    assert ra.main([str(write_suite(tmp_path)), "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert rec.argvs == [] and rec.opened == []
    assert "--name force1024" in out and "--name cut4000" in out
    assert "--app-arg=-thinkBudgetTokens" in out
    assert live in out, "the dry run names the relaunch target"
    assert not (tmp_path / "out").exists()


def test_a_sigterm_to_the_runner_takes_the_same_path_as_ctrl_c(tmp_path, monkeypatch, capsys):
    # `kill <runner pid>` (a stuck chain, a harness stopping the background task) ended the runner with no cleanup.
    # The handler main installs raises instead, so the arm runner stops run_chateval and the closing message runs.
    before = signal.getsignal(signal.SIGTERM)

    def sigterm(name):
        handler = signal.getsignal(signal.SIGTERM)
        assert callable(handler), "main installs a SIGTERM handler while arms run"
        handler(signal.SIGTERM, None)

    rec = Recorder(monkeypatch, running=[(9, LIVE_EXE)], during=sigterm)
    with pytest.raises(SystemExit) as stopped:
        ra.main([str(write_suite(tmp_path))])
    assert stopped.value.code == 143
    assert rec.names == ["force1024"]
    assert HOME_LIVE in capsys.readouterr().err
    assert signal.getsignal(signal.SIGTERM) is before, "and puts the old handler back"


# ── the live app comes back once, at the end, proven back ───────────────────

def test_the_live_app_seen_at_the_start_is_opened_once_at_the_end(tmp_path, monkeypatch, capsys):
    # Every arm runs --no-relaunch, and arm 1 quits the live app, so by the last arm run_chateval no longer knows
    # it was running (the harvest critique's bug): the runner looks before arm 1 and opens THAT copy at the end.
    rec = Recorder(monkeypatch, running=[(9, LIVE_EXE)])
    assert ra.main([str(write_suite(tmp_path))]) == 0
    assert rec.names == ["force1024", "cut4000"]
    assert rec.opened == [HOME_LIVE]
    assert all("--no-relaunch" in a for a in rec.argvs)
    assert f"live app relaunched: {HOME_LIVE}" in capsys.readouterr().out
    assert not marker(tmp_path).exists(), "a verified reopen forgets the target"


def test_a_failed_arm_still_brings_the_live_app_back(tmp_path, monkeypatch):
    rec = Recorder(monkeypatch, running=[(9, LIVE_EXE)], codes={"cut4000": 6})
    assert ra.main([str(write_suite(tmp_path))]) == 1
    assert rec.opened == [HOME_LIVE]


def test_a_live_app_still_running_at_the_end_is_not_opened_again(tmp_path, monkeypatch, capsys):
    # Every arm already done, so nothing quit it: `open` would only steal focus and claim a relaunch.
    path = write_suite(tmp_path)
    (tmp_path / "out").mkdir()
    for name in ("force1024", "cut4000"):
        (tmp_path / f"out/{name}.json").write_text("{}")
    rec = Recorder(monkeypatch, running=[(9, LIVE_EXE)])
    assert ra.main([str(path)]) == 0
    assert rec.opened == []
    out = capsys.readouterr().out
    assert "already running" in out and "relaunched" not in out


def test_nothing_is_opened_when_no_live_app_was_running(tmp_path, monkeypatch, capsys):
    rec = Recorder(monkeypatch, running=[])
    ra.main([str(write_suite(tmp_path))])
    assert rec.opened == []
    assert "nothing to reopen" in capsys.readouterr().out


@pytest.mark.parametrize("open_code, comes_back, opens", [
    (1, False, 2),  # `open` fails (-600 right after a quit): once more after a beat, then give up
    (0, False, 1),  # `open` says yes, but no live M1K3 shows up
])
def test_a_reopen_that_is_not_seen_up_is_unverified(tmp_path, monkeypatch, capsys, open_code, comes_back, opens):
    rec = Recorder(monkeypatch, running=[(9, LIVE_EXE)], open_code=open_code, comes_back=comes_back)
    assert ra.main([str(write_suite(tmp_path))]) == 1
    assert rec.opened == [HOME_LIVE] * opens
    captured = capsys.readouterr()
    assert "relaunched" not in captured.out
    assert "UNVERIFIED" in captured.err and HOME_LIVE in captured.err
    assert marker(tmp_path).read_text().strip() == HOME_LIVE, "kept, so a re-run still knows what to reopen"


def test_an_eval_app_left_running_stops_the_run_and_keeps_the_live_app_closed(tmp_path, monkeypatch, capsys):
    # A run_chateval that died without reaping leaves its eval app up for hours. The next arm would quit it or
    # abort, and the live app would come back beside a second MLX process: the runner stops and names the pid.
    rec = Recorder(monkeypatch, running=[(9, LIVE_EXE)], leaves="force1024")
    assert ra.main([str(write_suite(tmp_path))]) == 1
    assert rec.names == ["force1024"], "cut4000 never started"
    assert rec.opened == []
    err = capsys.readouterr().err
    assert "pid 77" in err and "UNVERIFIED" in err
    assert marker(tmp_path).exists()


def test_a_resumed_run_still_reopens_the_live_app_an_interrupted_run_quit(tmp_path, monkeypatch, capsys):
    # Arm 1 quits the live app, the run is stopped, and the re-run sees no live app: it had "nothing to reopen"
    # and Kev's daily app stayed closed for good. The target stays in outDir until the app is seen back.
    path = write_suite(tmp_path)

    def stop(name):
        raise KeyboardInterrupt

    Recorder(monkeypatch, running=[(9, LIVE_EXE)], during=stop)
    with pytest.raises(KeyboardInterrupt):
        ra.main([str(path)])
    err = capsys.readouterr().err
    assert HOME_LIVE in err and "reopen it yourself" in err
    assert marker(tmp_path).read_text().strip() == HOME_LIVE

    rec = Recorder(monkeypatch, running=[])  # the resume: the live app is still closed
    assert ra.main([str(path)]) == 0
    assert rec.names == ["force1024", "cut4000"]
    assert rec.opened == [HOME_LIVE]
    assert not marker(tmp_path).exists()


def test_a_resume_reruns_an_arm_whose_json_does_not_parse(tmp_path, monkeypatch, capsys):
    # "Done" is a JSON that parses; a half-written one (the run was killed mid-write) is set aside and re-run.
    path = write_suite(tmp_path)
    out = tmp_path / "out"
    out.mkdir()
    (out / "force1024.json").write_text('{"runs": [')
    rec = Recorder(monkeypatch, running=[])
    assert ra.main([str(path)]) == 0
    assert rec.names == ["force1024", "cut4000"]
    assert json.loads((out / "force1024.json").read_text()) == {"runs": []}
    assert (out / "force1024.json.unparsed").read_text() == '{"runs": ['
    assert "doesn't parse" in capsys.readouterr().out


# ── the arm runner itself (a harmless child, never M1K3) ────────────────────

def test_run_arm_keeps_the_drivers_output_and_its_exit_code(tmp_path):
    driver = tmp_path / "x.driver.txt"
    code = ra.run_arm([sys.executable, "-u", "-c", "import sys; print('saved'); print('oops', file=sys.stderr); sys.exit(6)"],
                      driver)
    assert code == 6
    lines = driver.read_text().splitlines()
    assert lines[0].startswith("--- attempt ") and lines[1:] == ["saved", "oops", "exit=6"]


def test_a_retried_arm_appends_to_its_driver_file(tmp_path):
    # The driver file is the arm's primary evidence, and a re-run of a timed-out arm wrote over it.
    driver = tmp_path / "x.driver.txt"
    ra.run_arm([sys.executable, "-c", "print('timed out')"], driver)
    ra.run_arm([sys.executable, "-c", "print('second try')"], driver)
    text = driver.read_text()
    assert text.count("--- attempt ") == 2
    assert text.index("timed out") < text.index("second try")


def test_run_arm_stops_run_chateval_with_sigterm_when_the_runner_is_interrupted(tmp_path):
    # Ctrl-C or a SIGTERM to the runner: run_chateval gets SIGTERM and a grace to reap the app it launched.
    # subprocess.run SIGKILLed it at once (no reap at all).
    driver = tmp_path / "x.driver.txt"

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGALRM, interrupt)
    signal.setitimer(signal.ITIMER_REAL, 1.0)
    try:
        with pytest.raises(KeyboardInterrupt):
            ra.run_arm([sys.executable, "-u", "-c", "import time; print('running'); time.sleep(600)"], driver)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    text = driver.read_text()
    assert "running" in text
    assert f"run_chateval exit {-signal.SIGTERM}" in text, "SIGTERM, not SIGKILL: it gets to reap its app"


# ── the README's example is a suite this runner accepts ─────────────────────

def test_the_readme_example_is_a_valid_suite(tmp_path):
    readme = (Path(ra.__file__).parent / "suites/README.md").read_text()
    blocks = re.findall(r"```json\n(.*?)```", readme, re.DOTALL)
    assert len(blocks) == 1
    path = tmp_path / "example.json"
    path.write_text(blocks[0])
    suite = ra.load_suite(path)
    assert [a.name for a in suite.arms] == [
        "2026-10-18-lil-force1024-always", "2026-10-18-lil-cut4000-always", "2026-10-18-lil-force2048-always"]
