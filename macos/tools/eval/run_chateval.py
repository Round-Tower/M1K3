#!/usr/bin/env python3
"""run_chateval.py — one command from "evaluate model X" to a provenance-stamped
ChatEvalDocument, driven through the REAL app bundle (the only honest runtime:
the sandbox container, the pinned weights store, the live prompt path).

  python3 macos/tools/eval/run_chateval.py --name lil-e2b-tools \\
      --brains lil --model lil=mlx-community/gemma-4-e2b-it-4bit \\
      --kinds tool-use,security --repeats 2 [--app /path/to/M1K3.app]

What it does, in order (each step is one that has bitten a hand-run):
  1. refuses to touch an M1K3 it doesn't own — a running instance that is
     neither the target app nor /Applications/M1K3.app is another session's
     build (the :4242 contention memory); it stops with the pid instead;
  2. quits the live app by path (AppleScript, graceful) and waits for the pid
     to be GONE — launching while the old instance quits kills the new one;
  3. waits out the AFM cool-down (back-to-back launches rate-collapse Apple's
     model daemon and the RAG stage hangs forever);
  4. writes the one-shot trigger (~/Library/Containers/app.m1k3/Data/
     .m1k3-selftest.json — SelfTestEnv consumes it on read) with the report
     path INSIDE the container (a path outside is silently refused);
  5. launches, proves the trigger was consumed (else the build is unsandboxed
     or reads another container — it aborts rather than waiting for nothing),
     waits for the SelfTest to exit, and reads the JSON it wrote;
  6. relaunches the live app if it was running before.

Provenance: power source + powermode are read from pmset and stamped; a
battery run is marked "battery" in the notes — pass counts stand on battery,
tok/s and latency do not (the 2026-09-05 power correction).

`--direct` (macOS 27): app-data privacy closed the container to shells, so the
trigger file can't be written and the report can't be read back. Direct mode
execs the bundle's binary itself with the trigger map as its ENVIRONMENT and
`M1K3_SELFTEST_OUT=-`, so the sandboxed app streams the transcript to the
inherited stdout and the JSON rides the same stream fenced
(ChatEvalReport.fenced); the driver cuts the last fenced block out. The
quit/blocker/cool-down rules are the same; only the launch and the read differ.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.8 (pure decisions pinned
in test_run_chateval.py; the quit/launch/wait glue driven by hand on the
installed app). Prior: none (new file; replaces the scratchpad run-selftest
helpers that died with two session restarts).
Review: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 — `--direct`: exec the
binary with the trigger as env + stdout reporting (the only route on macOS 27);
`extract_fenced_json` + `direct_env` pinned. Confidence now 0.8.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

BUNDLE_ID = "app.m1k3"
LIVE_APP = "/Applications/M1K3.app"
KNOWN_BRAINS = ("mini", "pocket", "lil", "big")
AFM_COOLDOWN_S = 120
STAMP = Path(tempfile.gettempdir()) / "m1k3-chateval-last-launch"
REPO_MACOS = Path(__file__).resolve().parents[2]


def default_container() -> Path:
    return Path.home() / "Library/Containers" / BUNDLE_ID / "Data"


# ── pure decisions (pinned in test_run_chateval.py) ─────────────────────────

def parse_power_source(pmset_batt: str) -> str:
    """'ac' | 'battery' | 'unknown' from `pmset -g batt`."""
    match = re.search(r"Now drawing from '([^']+)'", pmset_batt)
    if not match:
        return "unknown"
    source = match.group(1).lower()
    if "ac" in source.split():
        return "ac"
    if "battery" in source:
        return "battery"
    return "unknown"


def parse_powermode(pmset_g: str) -> int | None:
    """The `powermode` value from `pmset -g` (0 auto, 1 low, 2 high), or None."""
    match = re.search(r"^\s*powermode\s+(\d+)\s*$", pmset_g, re.MULTILINE)
    return int(match.group(1)) if match else None


def mlx_revision(resolved: dict) -> str | None:
    """The mlx-swift-lm revision from a Package.resolved document."""
    for pin in resolved.get("pins", []):
        if pin.get("identity") == "mlx-swift-lm":
            return pin.get("state", {}).get("revision")
    return None


_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")


def validate_name(name: str) -> str:
    """A run name becomes a file name inside the container — keep it boring."""
    if not _NAME.match(name or ""):
        raise ValueError(f"run name {name!r}: use letters, digits, . _ - (≤120, no leading dot)")
    return name


def out_path(container: Path, name: str) -> Path:
    return container / "Library/Application Support/M1K3/selftest-out" / validate_name(name)


def json_path(report: Path) -> Path:
    return Path(str(report) + ".json")


FENCE_OPEN = "-----BEGIN CHATEVAL JSON-----"
FENCE_CLOSE = "-----END CHATEVAL JSON-----"


def extract_fenced_json(text: str) -> dict | None:
    """The LAST complete fenced document in a stdout transcript, parsed; None
    when there is no open+close pair (a half-written block is not a scorecard).
    Mirrors ChatEvalReport.unfenced in M1K3Eval — keep the two in step."""
    close = text.rfind(FENCE_CLOSE)
    if close < 0:
        return None
    open_at = text.rfind(FENCE_OPEN, 0, close)
    if open_at < 0:
        return None
    body = text[open_at + len(FENCE_OPEN):close].strip()
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def direct_env(trig: dict[str, str], base: dict[str, str]) -> dict[str, str]:
    """The environment for a direct exec: the caller's env plus the trigger map,
    with the report routed to stdout. Direct mode never leaves a container path
    in M1K3_SELFTEST_OUT — the sandbox would write it where no shell can read."""
    env = dict(base)
    env.update(trig)
    env["M1K3_SELFTEST_OUT"] = "-"
    return env


def dump_dir(container: Path, name: str) -> Path:
    return container / "Library/Application Support/M1K3/selftest-dump" / validate_name(name)


@dataclass
class RunOptions:
    name: str
    brains: list[str]
    model: str | None = None
    kinds: list[str] = field(default_factory=list)
    repeats: int = 1
    live_path: bool = True
    notes: str | None = None
    dump_prompt: bool = False


def build_trigger(opts: RunOptions, *, container: Path, power_source: str, powermode: int | None,
                  commit: str | None, mlx_rev: str | None) -> dict[str, str]:
    """The trigger map SelfTestEnv reads. Absent options stay absent so the
    app's own defaults decide — never a guessed value (an unknown powermode is
    omitted, not written as 0)."""
    if not opts.brains or any(b not in KNOWN_BRAINS for b in opts.brains):
        raise ValueError(f"brains {opts.brains!r}: choose from {', '.join(KNOWN_BRAINS)}")
    if opts.repeats < 1:
        raise ValueError("repeats must be ≥ 1")
    report = out_path(container, opts.name)
    trig = {
        "M1K3_SELFTEST": "1",
        "M1K3_SELFTEST_CHATEVAL": "1",
        "M1K3_SELFTEST_CHATEVAL_BRAINS": ",".join(opts.brains),
        "M1K3_SELFTEST_OUT": str(report),
    }
    if opts.live_path:
        trig["M1K3_SELFTEST_CHATEVAL_LIVE_PATH"] = "1"
    if opts.model:
        trig["M1K3_SELFTEST_CHATEVAL_MLX_MODEL"] = opts.model
    if opts.kinds:
        trig["M1K3_SELFTEST_CHATEVAL_KINDS"] = ",".join(opts.kinds)
    if opts.repeats > 1:
        trig["M1K3_SELFTEST_CHATEVAL_REPEATS"] = str(opts.repeats)
    if powermode is not None:
        trig["M1K3_SELFTEST_POWERMODE"] = str(powermode)
    if commit:
        trig["M1K3_SELFTEST_APP_COMMIT"] = commit
    if mlx_rev:
        trig["M1K3_SELFTEST_MLX_REVISION"] = mlx_rev
    notes = opts.notes or ""
    if power_source == "battery":
        notes = f"{notes}; battery — latency not headline-grade" if notes else "battery — latency not headline-grade"
    if notes:
        trig["M1K3_SELFTEST_NOTES"] = notes
    if opts.dump_prompt:
        trig["M1K3_SELFTEST_DUMP_PROMPT"] = str(dump_dir(container, opts.name))
    return trig


def cooldown_remaining(last_launch: float | None, now: float, window: int = AFM_COOLDOWN_S) -> float:
    if last_launch is None:
        return 0
    return max(0.0, window - (now - last_launch))


@dataclass
class InstancePlan:
    to_quit: list[int]
    blockers: list[tuple[int, str]]
    live_was_running: bool


def plan_instances(running: list[tuple[int, str]], *, live_app: str, target_app: str) -> InstancePlan:
    """Which running M1K3 processes we may quit. Anything that is neither the
    live app nor the target is somebody else's build — never ours to kill."""
    ours = tuple(p.rstrip("/") + "/" for p in {live_app, target_app})
    to_quit, blockers, live = [], [], False
    for pid, exe in running:
        if exe.startswith(ours):
            to_quit.append(pid)
            live = live or exe.startswith(live_app.rstrip("/") + "/")
        else:
            blockers.append((pid, exe))
    return InstancePlan(to_quit, blockers, live)


# ── side effects (driven by hand; kept thin) ────────────────────────────────

def sh(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True).stdout


def running_instances() -> list[tuple[int, str]]:
    pids = [int(p) for p in sh("pgrep", "-x", "M1K3").split()]
    return [(pid, sh("ps", "-o", "comm=", "-p", str(pid)).strip()) for pid in pids]


def wait_until(predicate, timeout: float, every: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(every)
    return predicate()


def quit_app(path: str, pids: list[int]) -> bool:
    subprocess.run(["osascript", "-e", f'tell application "{path}" to quit'], capture_output=True)
    return wait_until(lambda: not any(pid in dict(running_instances()) for pid in pids), timeout=45)


def app_commit(app: Path) -> str | None:
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle).get("GitCommitSHA")
    except OSError:
        return None


def app_bundle_id(app: Path) -> str | None:
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier")
    except OSError:
        return None


def summarise(doc_path: Path) -> str:
    doc = json.loads(doc_path.read_text())
    lines = []
    for run in doc.get("runs", []):
        scores = run.get("scores", [])
        passed = sum(1 for s in scores if not any(c.get("outcome") == "fail" for c in s.get("checks", [])))
        label = run.get("brainID") or "?"
        model = run.get("modelID") or "stock"
        lines.append(f"  {label} [{model}]: {passed}/{len(scores)} trials passed")
    prov = doc.get("provenance", {})
    lines.append(f"  power={prov.get('powerSource')} powermode={prov.get('powerMode')} commit={prov.get('appCommit')}")
    return "\n".join(lines)


def run_direct(args, app: Path, trig: dict[str, str], plan: "InstancePlan") -> int:
    """Direct mode: the binary, the env, stdout. Returns like main()."""
    binary = app / "Contents/MacOS/M1K3"
    if not binary.exists():
        print(f"✗ no binary at {binary}", file=sys.stderr)
        return 2
    log_path = Path(args.log) if args.log else (
        Path(args.save_to).with_suffix(".log") if args.save_to else Path(tempfile.gettempdir()) / f"m1k3-chateval-{args.name}.log")
    STAMP.write_text(str(time.time()))
    print(f"▸ SelfTest (direct) → stdout → {log_path}")
    started = time.monotonic()
    with open(log_path, "w") as log:
        proc = subprocess.Popen([str(binary)], env=direct_env(trig, os.environ), stdout=log, stderr=subprocess.STDOUT,
                                cwd=tempfile.gettempdir())
        lines = 0
        while proc.poll() is None:
            if time.monotonic() - started > args.timeout_min * 60:
                print("✗ timed out — the SelfTest is still running; leaving it alone", file=sys.stderr)
                return 6
            time.sleep(10)
            now_lines = log_path.read_text(errors="replace").count("\n")
            if now_lines != lines:
                lines = now_lines
                print(f"  … {lines} report lines · {int((time.monotonic() - started) / 60)} min")
    doc = extract_fenced_json(log_path.read_text(errors="replace"))
    if doc is None:
        print(f"✗ no fenced JSON on stdout (exit {proc.returncode}) — read the transcript: {log_path}", file=sys.stderr)
        rc = 7
    else:
        if args.save_to:
            Path(args.save_to).write_text(json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
            print(summarise(Path(args.save_to)))
            print(f"  saved → {args.save_to}")
        else:
            print(json.dumps(doc, indent=2, sort_keys=True)[:2000])
        rc = 0
    if plan.live_was_running and not args.no_relaunch:
        subprocess.run(["open", "-a", LIVE_APP])
    return rc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--name", required=True, help="run name → selftest-out/<name>(.json)")
    ap.add_argument("--brains", required=True, help="comma list: mini,pocket,lil,big")
    ap.add_argument("--model", help="override: a bare id (one MLX brain) or lil=<id>,big=<id>")
    ap.add_argument("--kinds", default="", help="comma list of task kinds (default: all)")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--bare", action="store_true", help="bare provider.generate instead of the live path")
    ap.add_argument("--notes", help="free-text provenance note")
    ap.add_argument("--dump-prompt", action="store_true", help="dump no-call turns' exact prompts")
    ap.add_argument("--app", default=LIVE_APP, help="the M1K3.app bundle to run (default: installed)")
    ap.add_argument("--commit", help="app commit for provenance (default: Info.plist GitCommitSHA)")
    ap.add_argument("--save-to", help="copy the JSON here when done (e.g. macos/docs/evals/<name>.json)")
    ap.add_argument("--timeout-min", type=int, default=240)
    ap.add_argument("--no-relaunch", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="print the trigger and plan, touch nothing")
    ap.add_argument("--direct", action="store_true",
                    help="exec the bundle's binary with the trigger as env and read the report off stdout "
                         "(macOS 27: the container is closed to shells)")
    ap.add_argument("--log", help="direct mode: where to keep the raw stdout transcript (default: beside --save-to, or temp)")
    args = ap.parse_args(argv)

    container = default_container()
    app = Path(args.app).resolve()
    if app_bundle_id(app) != BUNDLE_ID:
        print(f"✗ {app} is not an {BUNDLE_ID} bundle", file=sys.stderr)
        return 2
    opts = RunOptions(
        name=args.name, brains=[b for b in args.brains.split(",") if b], model=args.model,
        kinds=[k for k in args.kinds.split(",") if k], repeats=args.repeats,
        live_path=not args.bare, notes=args.notes, dump_prompt=args.dump_prompt,
    )
    resolved = REPO_MACOS / "Package.resolved"
    mlx_rev = mlx_revision(json.loads(resolved.read_text())) if resolved.exists() else None
    power = parse_power_source(sh("pmset", "-g", "batt"))
    trig = build_trigger(opts, container=container, power_source=power,
                         powermode=parse_powermode(sh("pmset", "-g")),
                         commit=args.commit or app_commit(app), mlx_rev=mlx_rev)
    plan = plan_instances(running_instances(), live_app=LIVE_APP, target_app=str(app))
    report = Path(trig["M1K3_SELFTEST_OUT"])
    print(json.dumps(trig, indent=1, sort_keys=True))
    print(f"power: {power} · quit: {plan.to_quit} · live running: {plan.live_was_running}")
    if "M1K3_SELFTEST_APP_COMMIT" not in trig:
        print("! app commit unknown (local builds carry no GitCommitSHA) — pass --commit")
    if plan.blockers:
        for pid, exe in plan.blockers:
            print(f"✗ pid {pid} is someone else's M1K3 ({exe}) — not quitting it; stop it yourself", file=sys.stderr)
        return 3
    if args.dry_run:
        return 0

    if plan.to_quit and not quit_app(LIVE_APP if plan.live_was_running else str(app), plan.to_quit):
        print("✗ M1K3 did not quit within 45 s — aborting (never force-killed)", file=sys.stderr)
        return 4
    for pid in plan.to_quit:  # a second instance (the target build) quits by its own path
        if pid in dict(running_instances()):
            quit_app(str(app), [pid])
    last = float(STAMP.read_text()) if STAMP.exists() else None
    wait = cooldown_remaining(last, time.time())
    if wait:
        print(f"… AFM cool-down {int(wait)} s")
        time.sleep(wait)

    if args.direct:
        return run_direct(args, app, trig, plan)

    for stale in (report, json_path(report)):
        stale.unlink(missing_ok=True)
    trigger_file = container / ".m1k3-selftest.json"
    tmp = trigger_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(trig))
    os.replace(tmp, trigger_file)
    STAMP.write_text(str(time.time()))
    launched = subprocess.run(["open", "-a", str(app)], capture_output=True, text=True)
    if launched.returncode != 0:  # -600 right after a quit: once more after a beat
        time.sleep(3)
        subprocess.run(["open", "-a", str(app)], check=True)
    if not wait_until(lambda: not trigger_file.exists(), timeout=30):
        trigger_file.unlink(missing_ok=True)
        print("✗ the app never consumed the trigger — unsandboxed build or another container?", file=sys.stderr)
        return 5
    started = time.monotonic()
    print(f"▸ SelfTest running → {report}")

    def finished() -> bool:
        return not running_instances()

    lines = 0
    while not finished():
        if time.monotonic() - started > args.timeout_min * 60:
            print("✗ timed out — the SelfTest is still running; leaving it alone", file=sys.stderr)
            return 6
        time.sleep(10)
        if report.exists():
            now_lines = report.read_text(errors="replace").count("\n")
            if now_lines != lines:
                lines = now_lines
                print(f"  … {lines} report lines · {int((time.monotonic() - started) / 60)} min")

    doc = json_path(report)
    if not doc.exists():
        print(f"✗ no JSON at {doc} — read the report: {report}", file=sys.stderr)
        rc = 7
    else:
        print(summarise(doc))
        if args.save_to:
            shutil.copyfile(doc, args.save_to)
            print(f"  saved → {args.save_to}")
        rc = 0
    if plan.live_was_running and not args.no_relaunch:
        subprocess.run(["open", "-a", LIVE_APP])
    return rc


if __name__ == "__main__":
    sys.exit(main())
