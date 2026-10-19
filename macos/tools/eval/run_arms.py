#!/usr/bin/env python3
"""run_arms.py — run an A/B suite: one app, one run_chateval per arm, the live app back at the end.

  python3 macos/tools/eval/run_arms.py macos/tools/eval/suites/<suite>.json [--dry-run]

The suite (format and an example: suites/README.md) names ONE app — one binary per comparison,
built by build_eval_app.py; arms differ only by the run_chateval flags they add — an outDir,
and the arms. The file is read ONCE, at the start, so editing it mid-run changes nothing
queued (zsh reads a script as it runs: editing evals*.zsh mid-chain tore the queued arms).

Per arm: skipped when <outDir>/<name>.json exists (a re-run resumes; a saved JSON is final);
otherwise `run_chateval.py --direct --no-relaunch` on the suite's app with --save-to/--log in
outDir, the arm's --timeout-min, the suite's then the arm's args, and the suite's then the arm's
notes. run_chateval's output and exit code are APPENDED to <outDir>/<name>.driver.txt, one
"--- attempt" block per try: the arm's primary evidence. The exit code is not the verdict: an
arm is done when its JSON is there and parses, and a JSON beside a non-zero exit (run_chateval's
8) is kept and named. A failed arm doesn't stop the rest; an eval M1K3 still running from the
suite's app after an arm does (run_chateval should have stopped it): the pid is named, and
nothing more starts beside it.

The live app: every arm runs --no-relaunch and arm 1 quits it, so run_chateval can't know by the
last arm that it was running. This runner notes the copy up before arm 1 (/Applications or
~/Applications) in <outDir>/.run_arms-live-app, which a resumed run reads, and at the end opens
it (once more after a beat if `open` balks) — never while a live copy is still up, never beside
an eval M1K3 — and says "relaunched" only once it is seen running, UNVERIFIED otherwise. The note
goes once the app is seen back. Ctrl-C or SIGTERM stops the arm's run_chateval with SIGTERM (it
reaps the app it launched) and says where the live app was.

Exit 0 when every arm is done and the live app is back (or was never up), 1 when anything needs a
look, 2 on a suite that isn't one. Quitting, the AFM cool-down, blockers and power stamps stay
run_chateval's; there is no lock file and no preflight. `--dry-run` prints each arm's argv and
the relaunch target.

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file; replaces the
scratchpad evals*.zsh chain scripts). The suite parse, argv, skip and relaunch decisions are
pinned in test_run_arms.py with the arm runner mocked; not yet driven against the real app.
Review: Kev + claude-opus-5-5, 2026-10-18 — review folds: the live app survives a resume (the outDir
note) and is proven back, not assumed; the verdict reads the JSON, not the exit code; the driver
file appends; Ctrl-C/SIGTERM forward SIGTERM to run_chateval; an eval app left running stops the
run. The name rule, the live folders and the process table are run_chateval's, imported.
Confidence 0.75: the interrupt path leans on run_chateval reaping its app on SIGTERM.
Review: Kev + claude-opus-5-5, 2026-10-19 — a resume skips an arm only when its JSON parses, as the docs say; a
half-written one is set aside (`.unparsed`) and the arm runs again. Confidence 0.8.
"""

from __future__ import annotations

import argparse
import json
import shlex
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import run_chateval as rc  # the name rule, the live folders, the process table: one copy each

RUN_CHATEVAL = Path(__file__).with_name("run_chateval.py")
LIVE_MARKER = ".run_arms-live-app"  # in outDir: the live copy seen before arm 1, until it is seen back
OPEN_RETRY_S = 3  # `open` returns -600 right after a quit (run_chateval's own launch retries the same way)
REOPEN_WAIT_S = 15
STOP_GRACE_S = 15  # run_chateval's stop_child gives its app 10 s
_SUITE_KEYS = {"app", "outDir", "args", "notes", "arms"}
_ARM_KEYS = {"name", "args", "notes", "timeoutMin"}
# Set by this runner for every arm: an arm that sets one would swap the binary, the outputs or the relaunch rule.
RESERVED = {"--name", "--app", "--direct", "--save-to", "--log", "--no-relaunch", "--timeout-min", "--notes", "--dry-run"}


@dataclass(frozen=True)
class Arm:
    name: str
    args: tuple[str, ...]
    notes: str
    timeout_min: int


@dataclass(frozen=True)
class Suite:
    app: Path
    out_dir: Path
    args: tuple[str, ...]
    notes: str
    arms: tuple[Arm, ...]


def _flags(value: object, where: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ValueError(f"{where}: a list of strings")
    taken = [v for v in value if v.split("=", 1)[0] in RESERVED]
    if taken:
        raise ValueError(f"{where}: {', '.join(taken)} is set by run_arms for every arm")
    return tuple(value)


def _text(value: object, where: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{where}: a string")  # noqa: TRY004 (one error type for a bad suite; the CLI prints it)
    return value


def _unknown(doc: dict, allowed: set[str], where: str) -> None:
    extra = sorted(set(doc) - allowed)
    if extra:
        raise ValueError(f"{where}: unknown key(s) {', '.join(extra)} (allowed: {', '.join(sorted(allowed))})")


def load_suite(path: Path) -> Suite:
    """The suite, validated; relative paths resolve against the suite file. ValueError says why."""
    doc = json.loads(path.read_text())
    if not isinstance(doc, dict):
        raise ValueError("a suite is a JSON object")  # noqa: TRY004 (one error type for a bad suite; the CLI prints it)
    _unknown(doc, _SUITE_KEYS, "suite")
    for key in ("app", "outDir"):
        if not isinstance(doc.get(key), str) or not doc[key]:
            raise ValueError(f'"{key}": a non-empty path')
    if not isinstance(doc.get("arms"), list) or not doc["arms"]:
        raise ValueError('"arms": a non-empty list')
    arms: list[Arm] = []
    for i, raw in enumerate(doc["arms"]):
        if not isinstance(raw, dict):
            raise ValueError(f"arms[{i}]: an object")  # noqa: TRY004 (one error type for a bad suite; the CLI prints it)
        _unknown(raw, _ARM_KEYS, f"arms[{i}]")
        name = raw.get("name")
        if not isinstance(name, str):
            raise ValueError(f'arms[{i}]: a "name" string')  # noqa: TRY004 (one error type for a bad suite; the CLI prints it)
        rc.validate_name(name)  # run_chateval's rule: the name becomes file names
        if any(arm.name == name for arm in arms):
            raise ValueError(f"arm {name!r} is named twice")
        minutes = raw.get("timeoutMin")
        if type(minutes) is not int or minutes < 1:
            raise ValueError(f"arm {name!r}: timeoutMin, whole minutes ≥ 1")
        arms.append(Arm(name, _flags(raw.get("args", []), f"arm {name!r} args"),
                        _text(raw.get("notes", ""), f"arm {name!r} notes"), minutes))

    def resolve(p: str) -> Path:
        q = Path(p).expanduser()
        return q if q.is_absolute() else (path.parent / q).resolve()
    return Suite(resolve(doc["app"]), resolve(doc["outDir"]), _flags(doc.get("args", []), '"args"'),
                 _text(doc.get("notes", ""), '"notes"'), tuple(arms))


def arm_argv(suite: Suite, arm: Arm, python: str = sys.executable) -> list[str]:
    out = suite.out_dir
    notes = ": ".join(n for n in (suite.notes, arm.notes) if n)
    # -u: the driver file stays in order and `tail -f`-able (-I ignores PYTHONUNBUFFERED)
    return [python, "-I", "-u", str(RUN_CHATEVAL), "--name", arm.name, "--direct", "--app", str(suite.app),
            "--save-to", str(out / f"{arm.name}.json"), "--log", str(out / f"{arm.name}.log"),
            "--no-relaunch", "--timeout-min", str(arm.timeout_min), *suite.args, *arm.args,
            *(["--notes", notes] if notes else [])]


def live_running(running: list[tuple[int, str]], app: Path) -> str | None:
    """The live copy a running M1K3 executes from, or None (run_chateval's rule: an eval build is never live)."""
    return rc.plan_instances(running, live_apps=rc.LIVE_APPS, target_app=str(app)).live_running


def eval_pids(running: list[tuple[int, str]], app: Path) -> list[int]:
    """The M1K3s running from the suite's own app: an eval app still up."""
    return rc.plan_instances(running, live_apps=(), target_app=str(app)).to_quit


def arm_outcome(code: int, save: Path) -> tuple[str, str]:
    """("done" | "check" | "failed", the line that says why). The exit code is not the verdict: an arm is done
    when its JSON is there and parses. A JSON beside a non-zero exit (run_chateval's 8: the app exited non-zero
    after writing it) is "check": final, since a re-run skips the arm, but worth a look."""
    try:
        json.loads(save.read_text())
    except (OSError, ValueError):
        return "failed", f"no scorecard at {save} (exit {code})"
    if code == 0:
        return "done", f"saved → {save}"
    return "check", f"scorecard saved, but the app exited non-zero after writing it (exit {code})"


# ── side effects (seams the tests replace) ──────────────────────────────────

_running = rc.running_instances


def _open(app: str) -> int:
    return subprocess.run(["open", "-a", app], capture_output=True, check=False).returncode


def run_arm(argv: list[str], driver: Path) -> int:
    """One arm: run_chateval's stdout and stderr appended to the driver file under an attempt header, its exit
    code after. Stopped mid-arm (Ctrl-C, SIGTERM), this runner gives run_chateval SIGTERM and STOP_GRACE_S to
    reap the app it launched, then SIGKILL; subprocess.run would SIGKILL it at once."""
    with open(driver, "a") as handle:
        handle.write(f"--- attempt {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n")
        handle.flush()  # before the child writes to the same file
        proc = subprocess.Popen(argv, stdout=handle, stderr=subprocess.STDOUT)
        try:
            code = proc.wait()
        except BaseException:
            stopped = rc.stop_child(proc, STOP_GRACE_S)
            handle.write(f"stopped: run_arms was interrupted; run_chateval exit {stopped}\n")
            raise
        handle.write(f"exit={code}\n")
    return code


def reopen(live: str, app: Path) -> bool:
    """Bring the live app back, and prove it: True once a live copy is seen running."""
    running = _running()
    already = live_running(running, app)
    if already:
        print(f"live app already running: {already}")
        return True
    leftover = eval_pids(running, app)
    if leftover:
        print(f"✗ UNVERIFIED: not opening {live} beside an eval M1K3 (pid {', '.join(map(str, leftover))}): "
              f"stop it, then `open -a {live}`", file=sys.stderr)
        return False
    if _open(live) != 0:
        time.sleep(OPEN_RETRY_S)
        _open(live)
    if rc.wait_until(lambda: live_running(_running(), app) == live, timeout=REOPEN_WAIT_S):
        print(f"live app relaunched: {live}")
        return True
    print(f"✗ UNVERIFIED: opened {live}, but it is not running: `open -a {live}` by hand", file=sys.stderr)
    return False


def _sigterm(signum: int, frame: object) -> None:
    raise SystemExit(128 + signum)  # so a `kill` takes Ctrl-C's path: run_chateval stopped, the live app named


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("suite", type=Path, help="the suite JSON (suites/README.md)")
    ap.add_argument("--dry-run", action="store_true", help="print each arm's argv and the relaunch target; run nothing")
    args = ap.parse_args(argv)
    try:
        suite = load_suite(args.suite)  # once: edits to the file from here on change nothing
    except (OSError, ValueError) as err:
        print(f"✗ {args.suite}: {err}", file=sys.stderr)
        return 2
    marker = suite.out_dir / LIVE_MARKER
    remembered = marker.read_text().strip() if marker.is_file() else ""
    live = live_running(_running(), suite.app) or remembered or None  # up now wins; else a stopped run's note
    if args.dry_run:
        for arm in suite.arms:
            save = suite.out_dir / f"{arm.name}.json"
            print(f"· {arm.name}: skipped, {save} exists" if save.exists() else shlex.join(arm_argv(suite, arm)))
        print(f"then: open {live}" if live else "no live app is running: nothing to reopen")
        return 0

    suite.out_dir.mkdir(parents=True, exist_ok=True)
    if live:
        marker.write_text(live + "\n")
    failed: list[str] = []
    check: list[str] = []
    halted = False
    previous = signal.signal(signal.SIGTERM, _sigterm)
    try:
        for arm in suite.arms:
            save = suite.out_dir / f"{arm.name}.json"
            if save.exists():
                if arm_outcome(0, save)[0] == "done":
                    print(f"· {arm.name}: skipped, {save} exists")
                    continue
                # Not a finished arm: a half-written JSON. Kept beside it, and the arm runs again.
                save.replace(save.with_name(save.name + ".unparsed"))
                print(f"· {arm.name}: {save} doesn't parse — set aside as .unparsed, re-running")
            print(f"▸ {arm.name} · timeout {arm.timeout_min} min · {time.strftime('%H:%M')}", flush=True)
            started = time.monotonic()
            code = run_arm(arm_argv(suite, arm), suite.out_dir / f"{arm.name}.driver.txt")
            verdict, line = arm_outcome(code, save)
            print(f"  {arm.name} exit={code} · {int((time.monotonic() - started) / 60)} min · {line}", flush=True)
            if verdict == "failed":
                failed.append(arm.name)
            elif verdict == "check":
                check.append(arm.name)
            leftover = ", ".join(map(str, eval_pids(_running(), suite.app)))
            if leftover:
                print(f"✗ an eval M1K3 from {suite.app} is still running after {arm.name} (pid {leftover}): "
                      f"starting nothing beside it. Stop it (kill {leftover}), then re-run to resume.", file=sys.stderr)
                halted = True
                break
    except BaseException:
        if live:
            print(f"✗ stopped mid-run. The live app was running at {live}: reopen it yourself (`open -a {live}`) "
                  f"once no eval M1K3 is left; a re-run resumes and still knows it.", file=sys.stderr)
        raise
    finally:
        signal.signal(signal.SIGTERM, previous)

    back = reopen(live, suite.app) if live else True
    if not live:
        print("no live app was running at the start: nothing to reopen")
    elif back:
        marker.unlink(missing_ok=True)
    if failed:
        print(f"✗ no scorecard from {', '.join(failed)}: each .driver.txt says why", file=sys.stderr)
    if check:
        print(f"! {', '.join(check)}: scorecard saved, but the app exited non-zero after writing it. Kept (a re-run "
              f"skips it); read the .log", file=sys.stderr)
    return 1 if failed or check or halted or not back else 0


if __name__ == "__main__":
    sys.exit(main())
