#!/usr/bin/env python3
"""run_chateval.py — one command from "evaluate model X" to a provenance-stamped
ChatEvalDocument, driven through the REAL app bundle (the only honest runtime:
the sandbox container, the pinned weights store, the live prompt path).

  python3 macos/tools/eval/run_chateval.py --name lil-e2b-tools \\
      --brains lil --model lil=mlx-community/gemma-4-e2b-it-4bit \\
      --kinds tool-use,security --repeats 2 [--app /path/to/M1K3.app]

What it does, in order (each step is one that has bitten a hand-run):
  1. refuses to touch an M1K3 it doesn't own — a running instance that is
     neither the target app nor a live app (/Applications/M1K3.app or
     ~/Applications/M1K3.app) is another session's build (the :4242
     contention memory); it stops with the pid instead;
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
  6. relaunches the live app if it was running before, from the folder it ran from.

Provenance: power source + powermode are read from pmset and stamped; a
battery run is marked "battery" in the notes — pass counts stand on battery,
tok/s and latency do not (the 2026-09-05 power correction). The --save-to copy
also carries a `driver` block: the M1K3_* environment the app got (the trigger
keys and M1K3_SAMPLING with their values; any other M1K3_* name marked set, its
value withheld, since the copy is published and the shell can hold
M1K3_MCP_TOKEN; the home folder written as ~), the --app-arg argv, and the
power source read just before launch, at every 10-s poll and at the end
(`mixed` when two KNOWN sources were seen — the app stamps its own reading at
the END, so a run that started on battery can read "ac"; an unknown read is
"unverified", never a change). Under --direct the block is also printed when
the app launches, so a run that leaves no JSON still has it in its stdout. An
existing --save-to is refused without --overwrite.

`--direct` (macOS 27): app-data privacy closed the container to shells, so the
trigger file can't be written and the report can't be read back. Direct mode
execs the bundle's binary itself with the trigger map as its ENVIRONMENT and
`M1K3_SELFTEST_OUT=-`, so the sandboxed app streams the transcript to the
inherited stdout and the JSON rides the same stream fenced
(ChatEvalReport.fenced); the driver cuts the last fenced block out. The
quit/blocker/cool-down rules are the same; only the launch and the read differ.
A direct run that hits --timeout-min stops the app it launched (SIGTERM, 10 s,
then SIGKILL) and still exits 6: an orphaned eval app makes every later arm two
MLX processes. So does anything else that ends the runner early (an exception,
Ctrl-C, a SIGTERM to the runner): the app it launched is stopped and the live
app reopened on every way out. A re-run never truncates an earlier transcript:
a non-empty log is first renamed with its own end time (arm.log →
arm.20261018-143012.log), and a --log that is the --save-to is refused.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.8 (pure decisions pinned
in test_run_chateval.py; the quit/launch/wait glue driven by hand on the
installed app). Prior: none (new file; replaces the scratchpad run-selftest
helpers that died with two session restarts).
Review: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 — `--direct`: exec the
binary with the trigger as env + stdout reporting (the only route on macOS 27);
`extract_fenced_json` + `direct_env` pinned. Confidence now 0.8.
Review: Kev + claude-opus-5-5, 2026-10-07 — summarise reports latency-only fails and the content score
(the display-sleep stall: E4B 246/324 raw, 288/324 on content).
Review: Kev + claude-fable-5.1, 2026-10-09 — `--router dispatch [--router-head] [--router-chain]`
plumb the ChatEvalStage router keys through the trigger (the router arm, tools/eval/router_arm.sh).
Review: Kev + claude-fable-5.1, 2026-10-09 — `kind_rows` / `kind_table`: a per-kind table under each run line with the
latency-only and content columns (step 5 of the Qwen3.5 stream read "code-gen 24/30" off the JSON by hand).
Review: Kev + claude-fable-5.1, 2026-10-09 — `over_lil_own_peak_cap`: the summary flags a lil run whose own peak
exceeds the signed 5 GB cap (BrainTier.lilOwnPeakCapGB); the bake-off had applied it by eye.
Review: Kev + claude-fable-5.1, 2026-10-10 — `--think-steer` (the think-phase A/B clause) and two think columns
in `kind_rows` / `kind_table` (median ~tokens and ms of the think block, from the new score fields).
Review: Kev + claude-opus-5-5, 2026-10-10 — `--router off` (the live path, no route: the arm's like-for-like
baseline); head/chain now need `dispatch` specifically.
Review: Kev + claude-opus-5-5, 2026-10-16 — `--app-arg` (direct only): argv-domain A/B switches reach the exec
(`direct_argv`), first for the wrapped-persona-seed arm (-wrappedPersonaSeed NO).
Review: Kev + claude-opus-5-5, 2026-10-18 — `--calculator` (the calculator probe's stub) and the metacognition
steer arms (reread, trap, working, budget).
Review: Kev + claude-opus-5-5, 2026-10-18 — harvested from the Lil thinking evals' scratch wrappers: the timeout
reaps the app it launched (`stop_child`); the live app is either Applications folder and the relaunch reopens the
one that ran (`LIVE_APPS`, `relaunch_argv`); the --save-to copy carries a `driver` block (M1K3_* env, argv, power at
start and end) and refuses to overwrite without --overwrite; the kind table gains empty and p50-ms. card-auto's "ac"
stamp was the app's end-of-run reading, not a pmset misread, so parse_power_source is unchanged.
Review: Kev + claude-opus-5-5, 2026-10-18 — review fold: the driver block withholds every M1K3_* value but the trigger
keys and M1K3_SAMPLING (M1K3_MCP_TOKEN is a bearer token) and writes home as ~; power is read before launch, every
poll and at the end, and an unknown read is "unverified", never "mixed" (pmset's UPS now reads "ups", as the app's
does); run_direct stops its app and reopens the live one on every way out (try/finally plus a SIGTERM handler) and
prints the driver block at launch; a re-run sets the earlier transcript aside; a --log equal to --save-to is refused.
The glue is pinned on a stand-in app (/bin/sleep) in test_run_chateval.py; not yet driven against the real bundle.
Confidence 0.8.
Review: Kev + claude-opus-5-5, 2026-10-19 — `route_warning`: a live-path run with no `--router` never reaches the
plain turn, so the thinking cut, its retry, the forced budget and NoWait never run; the runner says so up front.
Review: Kev + claude-opus-5-5, 2026-10-19 (pre-push review of the follow-ups) — `quit_for_run`: from the quit to the
run's own guard (the AFM cool-down included), any way out reopens the live app; `relaunch_live` retries a failed
`open -a` once and says UNVERIFIED if it still fails; the scorecard is written whole (temp file, then rename); no
abbreviated flags, so run_arms' reserved ones can't be reached by prefix. Confidence 0.8.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

BUNDLE_ID = "app.m1k3"
LIVE_APP = "/Applications/M1K3.app"  # the --app default
# Either folder holds a live copy (Kev's daily app runs from ~/Applications; both exist on his Mac).
LIVE_APPS = (LIVE_APP, str(Path.home() / "Applications/M1K3.app"))
KNOWN_BRAINS = ("mini", "pocket", "lil", "big")
ROUTER_MODES = ("dispatch", "off")  # "off": the live path, no route (the router arm's baseline)  # "1" (the Mini-style plain route) is a different experiment
THINKING_MODES = ("tier", "always", "fast")  # EvalThinkingMode in M1K3Eval
AFM_COOLDOWN_S = 120
STAMP = Path(tempfile.gettempdir()) / "m1k3-chateval-last-launch"
REPO_MACOS = Path(__file__).resolve().parents[2]
SCORECARD = Path(__file__).resolve().with_name("scorecard.py")  # reads a transcript the run left without JSON


def default_container() -> Path:
    return Path.home() / "Library/Containers" / BUNDLE_ID / "Data"


# ── pure decisions (pinned in test_run_chateval.py) ─────────────────────────

def parse_power_source(pmset_batt: str) -> str:
    """'ac' | 'battery' | 'ups' | 'unknown' from `pmset -g batt` ('ups' as the app's PowerSource reads it)."""
    match = re.search(r"Now drawing from '([^']+)'", pmset_batt)
    if not match:
        return "unknown"
    source = match.group(1).lower()
    if "ac" in source.split():
        return "ac"
    if "battery" in source:
        return "battery"
    if "ups" in source.split():
        return "ups"
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
    when there is no open+close pair (a half-written block is not a scorecard);
    ValueError when a complete block is not JSON (a different problem from "no
    block", and named as such). Mirrors ChatEvalReport.unfenced in M1K3Eval —
    keep the two in step."""
    # Both markers as WHOLE lines (a newline before and after), like the Swift side: a marker
    # echoed INSIDE the document sits in a JSON string, where a real newline can never precede
    # it, so it can neither open nor close the block. The transcript's first line is never a
    # marker, so a leading newline is always there.
    padded = "\n" + text  # so a marker on the very first line still sits at a line start
    close = padded.rfind("\n" + FENCE_CLOSE)
    if close < 0:
        return None
    open_at = padded.rfind("\n" + FENCE_OPEN + "\n", 0, close)
    if open_at < 0:
        return None
    body = padded[open_at + len(FENCE_OPEN) + 2:close].strip()
    try:
        return json.loads(body)
    except json.JSONDecodeError as e:
        raise ValueError(f"a fenced block was there but is not JSON: {e}") from e


def direct_outcome(doc: dict | None, returncode: int | None, log_path: "Path") -> tuple[int, str]:
    """The exit code and the one line that explains it, for a direct run. A fenced document with a
    clean exit is 0; a document beside a non-zero exit is 8 (the scorecard is complete — a SelfTest
    writes it as its last act — but the process then died, and that is worth a look); no document
    is 7."""
    if doc is None:
        return 7, f"✗ no fenced JSON on stdout (exit {returncode}) — read the transcript: {log_path}"
    if returncode not in (0, None):
        return 8, f"! scorecard saved, but the app exited {returncode} after writing it — read the transcript: {log_path}"
    return 0, ""


def direct_env(trig: dict[str, str], base: dict[str, str]) -> dict[str, str]:
    """The environment for a direct exec: the caller's env plus the trigger map,
    with the report routed to stdout. Direct mode never leaves a container path
    in M1K3_SELFTEST_OUT — the sandbox would write it where no shell can read."""
    env = dict(base)
    env.update(trig)
    env["M1K3_SELFTEST_OUT"] = "-"
    return env


def direct_argv(binary: Path, app_args: list[str] | None) -> list[str]:
    """The exec line for a direct run: the binary, then any argv-domain A/B overrides
    (`--app-arg=-wrappedPersonaSeed --app-arg=NO`); on macOS 27 argv is the only way in."""
    return [str(binary), *(app_args or [])]


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
    pcc: bool = False
    thinking: str | None = None  # None → the app's default (tier: production's shape)
    think_steer: str | None = None  # none | terse | emoji | softcap | reread | trap | working | budget
    full_answers: bool = False  # whole answers in the document (bake-offs), not the 240-char excerpt
    calculator: bool = False  # offer the computing `calculate` stub (the calculator probe)
    router: str | None = None  # "dispatch": the app's own tool route, every tier on (the router arm)
    router_head: bool = False  # + the group head (toolGroupRouter); needs router
    router_chain: bool = False  # + two-tool chains (toolChain); needs router


def route_warning(opts: RunOptions) -> str | None:
    """A live-path run with no route: the turn goes to the agent loop, never the plain turn the app takes."""
    if opts.live_path and opts.router is None:
        return ("! live path without --router: no plain route, so the thinking cut, the no-think retry, the forced "
                "budget and NoWait never run (the Mac app routes every tier: --router dispatch)")
    return None


# The M1K3_* values the driver block records: the SelfTest trigger keys and the sampling A/B switch. Any other M1K3_*
# name is recorded as set with its value withheld — the --save-to copy is published (docs/evals), and the shell env
# can carry M1K3_MCP_TOKEN, a bearer token (tools/asc/verify_build.py). A secret-shaped name is withheld under
# SELFTEST too. No bare "KEY": M1K3_SELFTEST_KEYEVAL is a trigger.
_ENV_RECORDED = re.compile(r"^M1K3_(SELFTEST(_[A-Z0-9_]+)?|SAMPLING)$")
_ENV_SECRET = re.compile(r"TOKEN|SECRET|PASSW|AUTH|CREDENTIAL|API_?KEY|PRIVATE_?KEY")
WITHHELD = "<withheld>"


def recorded_env(env: dict[str, str], home: str) -> dict[str, str]:
    """The M1K3_* part of `env` as the driver block records it: values only for the listed names, the home folder
    written as ~ (a container path names the user)."""
    out = {}
    for key, value in sorted(env.items()):
        if not key.startswith("M1K3_"):
            continue
        if _ENV_RECORDED.match(key) and not _ENV_SECRET.search(key):
            out[key] = value.replace(home.rstrip("/") + "/", "~/")
        else:
            out[key] = WITHHELD
    return out


def power_record(readings: list[str], *, finished: bool = True) -> dict:
    """The power source over a run, from pmset reads in order (just before launch, every poll, at the end). `mixed`
    is the flag a reader needs: two different KNOWN sources were seen, so the latency is not headline-grade. An
    unknown read (pmset failed, or named nothing we know) never counts as a change; it shows in `seen`, and the
    summary calls the run's power unverified. At launch (`finished=False`) the end is "pending"."""
    known = {r for r in readings if r != "unknown"}
    return {"start": readings[0], "end": readings[-1] if finished else "pending",
            "seen": sorted(set(readings)), "mixed": len(known) > 1}


def driver_block(env: dict[str, str], app_args: list[str] | None, power: dict, *, home: str | None = None) -> dict:
    """What the runner itself did, for the --save-to copy and the launch line: the M1K3_* environment the app got
    (one record: the trigger map and anything inherited, e.g. M1K3_SAMPLING, already merged; see `recorded_env`),
    the argv-domain overrides, and the power record."""
    return {
        "env": recorded_env(env, str(Path.home()) if home is None else home),
        "appArgs": list(app_args or []),
        "power": power,
    }


def with_driver(doc: dict, block: dict) -> dict:
    """The document with the driver block beside its provenance (a new dict; readers that don't know the key ignore it)."""
    return {**doc, "driver": block}


def save_to_refusal(save_to: str | None, *, overwrite: bool) -> str | None:
    """The message to refuse on, or None. 2026-10-18: one wrapper script silently wrote over the previous one's
    run names; an existing result is only replaced on purpose."""
    if save_to and not overwrite and Path(save_to).exists():
        return f"✗ {save_to} already exists — refusing to write over it (pass --overwrite to replace it)"
    return None


def direct_log_path(log: str | None, save_to: str | None, name: str) -> Path:
    """Where a direct run keeps its stdout transcript: --log, else beside --save-to, else temp."""
    if log:
        return Path(log)
    if save_to:
        return Path(save_to).with_suffix(".log")
    return Path(tempfile.gettempdir()) / f"m1k3-chateval-{name}.log"


def log_refusal(log_path: Path, save_to: str | None) -> str | None:
    """`--save-to run.log` made the default transcript the JSON's own path: the document overwrote the transcript."""
    if save_to and log_path.resolve() == Path(save_to).resolve():
        return (f"✗ the transcript ({log_path}) and --save-to are the same file — the JSON would overwrite it; "
                "pass a different --log")
    return None


def aside_path(log_path: Path, mtime: float) -> Path:
    """Where an earlier transcript moves before a re-run writes the log afresh: its own end time (mtime) before the
    suffix. run_arms re-runs an arm whose JSON is missing, which is exactly a timed-out arm, whose log is its record."""
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(mtime))
    return log_path.with_name(f"{log_path.stem}.{stamp}{log_path.suffix}")


def build_trigger(opts: RunOptions, *, container: Path, power_source: str, powermode: int | None,
                  commit: str | None, mlx_rev: str | None) -> dict[str, str]:
    """The trigger map SelfTestEnv reads. Absent options stay absent so the
    app's own defaults decide — never a guessed value (an unknown powermode is
    omitted, not written as 0)."""
    if any(b not in KNOWN_BRAINS for b in opts.brains):
        raise ValueError(f"brains {opts.brains!r}: choose from {', '.join(KNOWN_BRAINS)}")
    if not opts.brains and not opts.pcc:
        raise ValueError("no brains selected: name at least one, or pass --pcc for the Private Cloud column alone")
    if opts.repeats < 1:
        raise ValueError("repeats must be ≥ 1")
    if opts.thinking is not None and opts.thinking not in THINKING_MODES:
        raise ValueError(f"thinking {opts.thinking!r}: choose from {', '.join(THINKING_MODES)}")
    if opts.router is not None and opts.router not in ROUTER_MODES:
        raise ValueError(f"router {opts.router!r}: choose from {', '.join(ROUTER_MODES)}")
    if (opts.router_head or opts.router_chain) and opts.router != "dispatch":
        raise ValueError("router head/chain need --router dispatch (the app reads them only there)")
    report = out_path(container, opts.name)
    trig = {
        "M1K3_SELFTEST": "1",
        "M1K3_SELFTEST_CHATEVAL": "1",
        "M1K3_SELFTEST_CHATEVAL_BRAINS": ",".join(opts.brains),
        "M1K3_SELFTEST_OUT": str(report),
    }
    if opts.live_path:
        trig["M1K3_SELFTEST_CHATEVAL_LIVE_PATH"] = "1"
    if opts.pcc:
        trig["M1K3_SELFTEST_CHATEVAL_PCC"] = "1"
    if opts.model:
        trig["M1K3_SELFTEST_CHATEVAL_MLX_MODEL"] = opts.model
    if opts.kinds:
        trig["M1K3_SELFTEST_CHATEVAL_KINDS"] = ",".join(opts.kinds)
    if opts.repeats > 1:
        trig["M1K3_SELFTEST_CHATEVAL_REPEATS"] = str(opts.repeats)
    if opts.thinking:
        trig["M1K3_SELFTEST_CHATEVAL_THINKING"] = opts.thinking
    if opts.think_steer:
        trig["M1K3_SELFTEST_CHATEVAL_THINK_STEER"] = opts.think_steer
    if opts.calculator:
        trig["M1K3_SELFTEST_CHATEVAL_CALCULATOR"] = "1"
    if opts.full_answers:
        trig["M1K3_SELFTEST_CHATEVAL_FULL_ANSWERS"] = "1"
    if opts.router:
        trig["M1K3_SELFTEST_CHATEVAL_ROUTER"] = opts.router
        if opts.router_head:
            trig["M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD"] = "1"
        if opts.router_chain:
            trig["M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN"] = "1"
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
    live_running: str | None  # the live app's path as it was running, or None

    @property
    def live_was_running(self) -> bool:
        return self.live_running is not None


def _inside(exe: str, app: str) -> bool:
    return exe.startswith(app.rstrip("/") + "/")


def plan_instances(running: list[tuple[int, str]], *, live_apps: tuple[str, ...], target_app: str) -> InstancePlan:
    """Which running M1K3 processes we may quit. Anything that is neither a
    live app nor the target is somebody else's build — never ours to kill.
    `live_running` is the live copy that was actually running, so the
    relaunch reopens THAT one, not the first folder in the list."""
    to_quit, blockers, live = [], [], None
    for pid, exe in running:
        seen = next((app for app in live_apps if _inside(exe, app)), None)
        if seen or _inside(exe, target_app):
            to_quit.append(pid)
            live = live or seen
        else:
            blockers.append((pid, exe))
    return InstancePlan(to_quit, blockers, live)


def relaunch_argv(live_running: str | None, *, no_relaunch: bool) -> list[str] | None:
    """The command that reopens the live app the run quit, or None (nothing was running, or --no-relaunch)."""
    if live_running is None or no_relaunch:
        return None
    return ["open", "-a", live_running]


# ── side effects (driven by hand; kept thin) ────────────────────────────────

def sh(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True).stdout


def running_instances() -> list[tuple[int, str]]:
    pids = [int(p) for p in sh("pgrep", "-x", "M1K3").split()]
    return [(pid, sh("ps", "-o", "comm=", "-p", str(pid)).strip()) for pid in pids]


def read_power() -> str:
    """One pmset read; a read that fails is "unknown", never a reason to end the run (it is read every poll)."""
    try:
        return parse_power_source(sh("pmset", "-g", "batt"))
    except OSError:
        return "unknown"


def set_aside(log_path: Path) -> Path | None:
    """Rename a non-empty earlier transcript out of the way (see `aside_path`); the new one, or None."""
    try:
        if log_path.stat().st_size == 0:
            return None
    except FileNotFoundError:
        return None
    aside = aside_path(log_path, log_path.stat().st_mtime)
    log_path.rename(aside)
    return aside


def _sigterm_as_exit(signum: int, _frame) -> None:
    raise SystemExit(128 + signum)


def relaunch_live(plan: InstancePlan, no_relaunch: bool) -> None:
    """Reopen the live app the run quit. `open -a` straight after the eval app (same bundle id) went can fail with
    -600: once more after a beat, then say so rather than leave the live app closed in silence."""
    argv = relaunch_argv(plan.live_running, no_relaunch=no_relaunch)
    if not argv:
        return
    if subprocess.run(argv).returncode != 0:
        time.sleep(3)
        if subprocess.run(argv).returncode != 0:
            print(f"! the live app did not reopen ({' '.join(argv)}): UNVERIFIED, open it yourself", file=sys.stderr)


def quit_for_run(plan: InstancePlan, app: Path, no_relaunch: bool) -> bool:
    """Quit the live app (and a target build already up) and sit out the AFM cool-down. False when M1K3 didn't
    quit (nothing to reopen). From the quit until the run's own guard takes over, any way out — Ctrl-C in the
    cool-down, a SIGTERM, an exception — reopens the live app."""
    previous = signal.signal(signal.SIGTERM, _sigterm_as_exit)
    try:
        if plan.to_quit and not quit_app(plan.live_running or str(app), plan.to_quit):
            return False
        for pid in plan.to_quit:  # a second instance (the target build) quits by its own path
            if pid in dict(running_instances()):
                quit_app(str(app), [pid])
        last = float(STAMP.read_text()) if STAMP.exists() else None
        wait = cooldown_remaining(last, time.time())
        if wait:
            print(f"… AFM cool-down {int(wait)} s")
            time.sleep(wait)
        return True
    except BaseException:
        relaunch_live(plan, no_relaunch)
        raise
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_DFL if previous is None else previous)


def stop_child(proc: subprocess.Popen, grace_s: float = 10) -> int:
    """Stop a process this runner launched: SIGTERM, `grace_s` to exit, then SIGKILL. Returns its exit
    code (negative: the signal). Only ever the Popen it started — never a pid found by name, so the live
    app and other sessions' builds are out of reach."""
    if proc.poll() is not None:
        return proc.returncode
    proc.terminate()
    try:
        return proc.wait(grace_s)
    except subprocess.TimeoutExpired:
        proc.kill()
        return proc.wait()


def write_document(path: str, doc: dict) -> None:
    """Whole or not at all (a temp file, then a rename): run_arms reads a JSON that parses as a finished arm."""
    target = Path(path)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    os.replace(tmp, target)


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


def _applicable(scores: list[dict]) -> list[dict]:
    """n/a (a vision turn on a brain that can't see) is one skip named "applicable" — out of every count."""
    return [s for s in scores
            if [(c.get("name"), c.get("outcome")) for c in s.get("checks", [])] != [("applicable", "skip")]]


def _passed(score: dict) -> bool:
    return not any(c.get("outcome") == "fail" for c in score.get("checks", []))


def _latency_only(score: dict) -> bool:
    """A fail whose ONLY failing check is the latency ceiling: the answer was right, the clock wasn't
    (2026-10-07: a display-sleep stall made 42 of E4B's fails exactly this). Reported, never folded in."""
    return [c.get("name") for c in score.get("checks", []) if c.get("outcome") == "fail"] == ["responsive"]


def _empty(score: dict) -> bool:
    """No visible text: the scorer's own `non-empty` check failed (the answer with the think block and the
    FOLLOWUPS trailer stripped). On every 2026-10-17/18 Lil arm it agrees with a blank answerPreview."""
    return any(c.get("name") == "non-empty" and c.get("outcome") == "fail" for c in score.get("checks", []))


def _median(values: list[int]) -> int | None:
    """The lower middle for an even count — the same rule as Swift's `medianOf`, so both reports agree."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[(len(ordered) - 1) // 2]


def kind_rows(scores: list[dict]) -> list[dict]:
    """Per task-kind: passed, total, latency-only fails, the content score (passed + latency-only),
    empty answers and the p50 latency (2026-10-18, the lower-middle median), and the think phase
    (2026-10-10): median think tokens (thinkChars / 4) and median think ms over
    the trials that recorded them (None when none did — older reports). Sorted by kind; n/a trials
    left out. "code-gen 24/30, grounded-Q 18/24" were hand counts off the JSON before this
    (2026-10-09); content is a column, not a hand count on top of one."""
    rows: dict[str, dict] = {}
    latency: dict[str, list[int]] = {}
    think_chars: dict[str, list[int]] = {}
    think_ms: dict[str, list[int]] = {}
    for s in _applicable(scores):
        kind = s.get("kind") or "?"
        row = rows.setdefault(kind, {"passed": 0, "total": 0, "latency_only": 0, "empty": 0})
        row["total"] += 1
        if _passed(s):
            row["passed"] += 1
        elif _latency_only(s):
            row["latency_only"] += 1
        if _empty(s):
            row["empty"] += 1
        if s.get("latencyMS") is not None:
            latency.setdefault(kind, []).append(int(s["latencyMS"]))
        if s.get("thinkChars") is not None:
            think_chars.setdefault(kind, []).append(int(s["thinkChars"]))
        if s.get("thinkMS") is not None:
            think_ms.setdefault(kind, []).append(int(s["thinkMS"]))
    out = []
    for kind, row in sorted(rows.items()):
        chars = _median(think_chars.get(kind, []))
        out.append({"kind": kind, **row, "content": row["passed"] + row["latency_only"],
                    "p50_ms": _median(latency.get(kind, [])),
                    "think_tokens": None if chars is None else chars // 4,
                    "think_ms": _median(think_ms.get(kind, []))})
    return out


def kind_table(rows: list[dict]) -> str:
    """The rows as an aligned text table:
    kind | passed | latency-only | content | empty | p50 ms | ~think tk | think ms."""
    width = max([len("kind")] + [len(r["kind"]) for r in rows])
    lines = [f"    {'kind'.ljust(width)}  passed  latency-only  content  empty  p50-ms  ~think-tk  think-ms"]
    for r in rows:
        passed, content = f"{r['passed']}/{r['total']}", f"{r['content']}/{r['total']}"
        p50 = "—" if r.get("p50_ms") is None else str(r["p50_ms"])
        tk = "—" if r.get("think_tokens") is None else str(r["think_tokens"])
        ms = "—" if r.get("think_ms") is None else str(r["think_ms"])
        lines.append(f"    {r['kind'].ljust(width)}  {passed.rjust(6)}  {str(r['latency_only']).rjust(12)}  "
                     f"{content.rjust(7)}  {str(r.get('empty', 0)).rjust(5)}  {p50.rjust(6)}  "
                     f"{tk.rjust(9)}  {ms.rjust(8)}")
    return "\n".join(lines)


# Lil's RAM cap, signed 2026-10-09 (BrainTier.lilOwnPeakCapGB): 5 GB of the brain's OWN peak on a
# 16 GB Mac, in the mebibytes the report records. The incumbent and Qwen3.5-4B measured 4.8 GB;
# gemma-4 E4B's 10.3 GB is what it rejects. Inclusive at the cap.
LIL_OWN_PEAK_CAP_GB = 5


def over_lil_own_peak_cap(brain_id: str, own_mb: int | None) -> bool:
    """True when a lil run's own peak exceeds the signed cap. Other brains have their own floors."""
    return brain_id == "lil" and own_mb is not None and own_mb > LIL_OWN_PEAK_CAP_GB * 1024


def summarise(doc_path: Path) -> str:
    doc = json.loads(doc_path.read_text())
    lines = []
    for run in doc.get("runs", []):
        everything = run.get("scores", [])
        scores = _applicable(everything)
        passed = sum(1 for s in scores if _passed(s))
        latency_only = sum(1 for s in scores if _latency_only(s))
        label = run.get("brainID") or "?"
        model = run.get("modelID") or "stock"
        na = len(everything) - len(scores)
        peak, resident = run.get("peakMemoryMB"), run.get("residentMemoryMBAtStart")
        # Same rule as BrainRun.ownPeakMemoryMB: peak below resident means no number.
        own_mb = peak - resident if peak is not None and resident is not None and peak >= resident else None
        own = f" (own {own_mb} MB)" if own_mb is not None else ""
        if over_lil_own_peak_cap(label, own_mb):
            own += f" ⚠ OVER the Lil RAM cap ({LIL_OWN_PEAK_CAP_GB} GB own peak)"
        lines.append(f"  {label} [{model}]: {passed}/{len(scores)} trials passed" + (f" ({na} n/a)" if na else "")
                     + (f", {latency_only} latency-only (content {passed + latency_only}/{len(scores)})"
                        if latency_only else "")
                     + (f", peak {peak} MB{own}" if peak is not None else ""))
        if scores:
            lines.append(kind_table(kind_rows(everything)))
    prov = doc.get("provenance", {})
    line = f"  power={prov.get('powerSource')} powermode={prov.get('powerMode')} commit={prov.get('appCommit')}"
    power = (doc.get("driver") or {}).get("power") or {}
    seen = power.get("seen") or [power.get("start"), power.get("end")]
    ends = f"{power.get('start')} at start, {power.get('end')} at end"
    if power.get("mixed"):
        between = f" (seen {', '.join(s for s in seen if s != 'unknown')})" if power.get("start") == power.get("end") else ""
        line += f" ⚠ power mixed: {ends}{between} — latency not headline-grade"
    elif power and "unknown" in seen:
        line += f" ⚠ power unverified: {ends}"
    lines.append(line)
    return "\n".join(lines)


def caffeinate_argv(pid: int) -> list[str]:
    """Hold the display (and the system) awake for exactly the app's lifetime.

    2026-10-07: with the display asleep, macOS throttled the headless eval 10-35x
    (decode 35 -> 0-3 tok/s); `caffeinate -is` around the runner did not stop it.
    A separate `-w <pid>` keeps the app's own exit code (crash detection) intact.
    """
    return ["/usr/bin/caffeinate", "-dis", "-w", str(pid)]


def run_direct(args, app: Path, trig: dict[str, str], plan: "InstancePlan") -> int:
    """Direct mode: the binary, the env, stdout. Returns like main(). main() has already quit the live app, so every
    way out of here — a return, an exception, Ctrl-C, a SIGTERM to the runner — stops the app this launched and
    reopens the live one (the finally)."""
    previous = signal.signal(signal.SIGTERM, _sigterm_as_exit)  # `kill <runner pid>` takes the same way out
    proc: subprocess.Popen | None = None
    try:
        binary = app / "Contents/MacOS/M1K3"
        if not binary.exists():
            print(f"✗ no binary at {binary}", file=sys.stderr)
            return 2
        log_path = direct_log_path(args.log, args.save_to, args.name)
        aside = set_aside(log_path)
        if aside:
            print(f"  the previous transcript is kept as {aside}")
        env = direct_env(trig, os.environ)
        readings = [read_power()]  # just before launch, not before the quit and the AFM cool-down
        print("driver: " + json.dumps(driver_block(env, args.app_arg, power_record(readings, finished=False)),
                                      sort_keys=True, ensure_ascii=False))
        STAMP.write_text(str(time.time()))
        print(f"▸ SelfTest (direct) → stdout → {log_path}")
        started = time.monotonic()
        timed_out = False
        with open(log_path, "w") as log:
            proc = subprocess.Popen(direct_argv(binary, args.app_arg), env=env, stdout=log, stderr=subprocess.STDOUT,
                                    cwd=tempfile.gettempdir())
            try:
                subprocess.Popen(caffeinate_argv(proc.pid), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError as err:  # never orphan the app over a missing caffeinate
                print(f"⚠ caffeinate unavailable ({err}); the display may sleep and throttle the run", file=sys.stderr)
            lines = 0
            while proc.poll() is None:
                if time.monotonic() - started > args.timeout_min * 60:
                    timed_out = True
                    break
                time.sleep(10)
                readings.append(read_power())
                now_lines = log_path.read_text(errors="replace").count("\n")
                if now_lines != lines:
                    lines = now_lines
                    print(f"  … {lines} report lines · {int((time.monotonic() - started) / 60)} min")
        if timed_out:
            code = stop_child(proc)  # the runner started it, so the runner stops it
        readings.append(read_power())
        power = power_record(readings)
        print("driver power: " + json.dumps(power, sort_keys=True))
        if timed_out:
            print(f"✗ timed out after {args.timeout_min} min — stopped the eval app it launched (pid {proc.pid}, "
                  f"exit {code}); the transcript so far: python3 {SCORECARD} {log_path}",
                  file=sys.stderr)
            return 6
        try:
            doc = extract_fenced_json(log_path.read_text(errors="replace"))
        except ValueError as e:  # a block was there but is not JSON — one message, not two
            print(f"✗ {e} (exit {proc.returncode}) — read the transcript: {log_path}", file=sys.stderr)
            doc, rc = None, 7
        else:
            rc, note = direct_outcome(doc, proc.returncode, log_path)
            if note:
                print(note, file=sys.stderr)
        if doc is not None:
            doc = with_driver(doc, driver_block(env, args.app_arg, power))
            if args.save_to:
                write_document(args.save_to, doc)
                print(summarise(Path(args.save_to)))
                print(f"  saved → {args.save_to}")
            else:
                print(json.dumps(doc, indent=2, sort_keys=True)[:2000])
        return rc
    except BaseException:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)  # a second kill must not cut the reap short
        if proc is not None:
            stop_child(proc)
        raise
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_DFL if previous is None else previous)
        relaunch_live(plan, args.no_relaunch)  # never leave the live app quit


def main(argv: list[str] | None = None) -> int:
    # No prefix matching: run_arms reserves --save-to, --log and the rest, and `--save=` would get past it.
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], allow_abbrev=False)
    ap.add_argument("--name", required=True, help="run name → selftest-out/<name>(.json)")
    ap.add_argument("--brains", default="", help="comma list: mini,pocket,lil,big (may be empty with --pcc)")
    ap.add_argument("--pcc", action="store_true",
                    help="add Apple's Private Cloud Compute as a column (needs an entitled M1K3_FM27 build)")
    ap.add_argument("--model", help="override: a bare id (one MLX brain) or lil=<id>,big=<id>")
    ap.add_argument("--kinds", default="", help="comma list of task kinds (default: all)")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--bare", action="store_true", help="bare provider.generate instead of the live path")
    ap.add_argument("--think-steer", choices=["none", "terse", "emoji", "softcap", "reread", "trap", "working", "budget"],
                    help="the think-steer A/B clause appended to the turn's rules (M1K3_SELFTEST_CHATEVAL_THINK_STEER)")
    ap.add_argument("--thinking", choices=THINKING_MODES,
                    help="how every arm thinks: tier (production's shape, the app default), always, fast")
    ap.add_argument("--calculator", action="store_true",
                    help="offer the computing `calculate` stub beside the palette (the calculator probe)")
    ap.add_argument("--full-answers", action="store_true",
                    help="keep every answer whole in the document (bake-offs: fails stay re-adjudicable)")
    ap.add_argument("--router", choices=ROUTER_MODES,
                    help="the app's own tool route with every tier on (ChatEvalStage _ROUTER=dispatch)")
    ap.add_argument("--router-head", action="store_true", help="with --router: the group head in front of the pick")
    ap.add_argument("--router-chain", action="store_true", help="with --router: let a pick run two read-only tools")
    ap.add_argument("--notes", help="free-text provenance note")
    ap.add_argument("--dump-prompt", action="store_true", help="dump no-call turns' exact prompts")
    ap.add_argument("--app", default=LIVE_APP, help="the M1K3.app bundle to run (default: installed)")
    ap.add_argument("--commit", help="app commit for provenance (default: Info.plist GitCommitSHA)")
    ap.add_argument("--save-to", help="copy the JSON here when done (e.g. macos/docs/evals/<name>.json)")
    ap.add_argument("--overwrite", action="store_true", help="replace an existing --save-to (refused without it)")
    ap.add_argument("--timeout-min", type=int, default=240)
    ap.add_argument("--no-relaunch", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="print the trigger and plan, touch nothing")
    ap.add_argument("--direct", action="store_true",
                    help="exec the bundle's binary with the trigger as env and read the report off stdout "
                         "(macOS 27: the container is closed to shells)")
    ap.add_argument("--log", help="direct mode: where to keep the raw stdout transcript (default: beside --save-to, or temp)")
    ap.add_argument("--app-arg", action="append",
                    help="direct mode: one argv word for the app, repeatable (--app-arg=-wrappedPersonaSeed --app-arg=NO)")
    args = ap.parse_args(argv)
    refusal = save_to_refusal(args.save_to, overwrite=args.overwrite)
    if not refusal and args.direct:
        refusal = log_refusal(direct_log_path(args.log, args.save_to, args.name), args.save_to)
    if refusal:  # before any probe, quit or launch
        print(refusal, file=sys.stderr)
        return 2

    container = default_container()
    app = Path(args.app).resolve()
    if app_bundle_id(app) != BUNDLE_ID:
        print(f"✗ {app} is not an {BUNDLE_ID} bundle", file=sys.stderr)
        return 2
    opts = RunOptions(
        name=args.name, brains=[b for b in args.brains.split(",") if b], model=args.model,
        kinds=[k for k in args.kinds.split(",") if k], repeats=args.repeats,
        live_path=not args.bare, notes=args.notes, dump_prompt=args.dump_prompt, pcc=args.pcc,
        thinking=args.thinking, think_steer=args.think_steer, full_answers=args.full_answers,
        calculator=args.calculator,
        router=args.router, router_head=args.router_head, router_chain=args.router_chain,
    )
    if args.app_arg and not args.direct:
        print("✗ --app-arg needs --direct (an `open -a` launch carries no argv)", file=sys.stderr)
        return 2
    if args.direct and args.dump_prompt:
        print("✗ --dump-prompt writes into the container, which --direct exists to avoid reading", file=sys.stderr)
        return 2
    resolved = REPO_MACOS / "Package.resolved"
    mlx_rev = mlx_revision(json.loads(resolved.read_text())) if resolved.exists() else None
    power = parse_power_source(sh("pmset", "-g", "batt"))
    trig = build_trigger(opts, container=container, power_source=power,
                         powermode=parse_powermode(sh("pmset", "-g")),
                         commit=args.commit or app_commit(app), mlx_rev=mlx_rev)
    plan = plan_instances(running_instances(), live_apps=LIVE_APPS, target_app=str(app))
    report = Path(trig["M1K3_SELFTEST_OUT"])
    print(json.dumps(recorded_env(trig, str(Path.home())), indent=1, sort_keys=True))  # ~, not the username
    if warning := route_warning(opts):
        print(warning)
    print(f"power: {power} · quit: {plan.to_quit} · live running: {plan.live_running or 'no'}")
    if "M1K3_SELFTEST_APP_COMMIT" not in trig:
        print("! app commit unknown (this build predates the GitCommitSHA stamp phase, or was built outside Xcode) — rebuild, or pass --commit")
    if plan.blockers:
        for pid, exe in plan.blockers:
            print(f"✗ pid {pid} is someone else's M1K3 ({exe}) — not quitting it; stop it yourself", file=sys.stderr)
        return 3
    if args.dry_run:
        return 0

    if not quit_for_run(plan, app, args.no_relaunch):
        print("✗ M1K3 did not quit within 45 s — aborting (never force-killed)", file=sys.stderr)
        return 4

    if args.direct:
        return run_direct(args, app, trig, plan)

    for stale in (report, json_path(report)):
        stale.unlink(missing_ok=True)
    trigger_file = container / ".m1k3-selftest.json"
    tmp = trigger_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(trig))
    os.replace(tmp, trigger_file)
    readings = [read_power()]  # just before launch
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
        readings.append(read_power())
        if report.exists():
            now_lines = report.read_text(errors="replace").count("\n")
            if now_lines != lines:
                lines = now_lines
                print(f"  … {lines} report lines · {int((time.monotonic() - started) / 60)} min")

    doc = json_path(report)
    if not doc.exists():
        print(f"✗ no JSON at {doc} — read the report: {report}", file=sys.stderr)
        rc = 7
    elif args.save_to:  # the trigger map IS what this app got: an `open -a` launch carries no env
        readings.append(read_power())
        write_document(args.save_to, with_driver(json.loads(doc.read_text()),
                                                 driver_block(trig, None, power_record(readings))))
        print(summarise(Path(args.save_to)))
        print(f"  saved → {args.save_to}")
        rc = 0
    else:
        print(summarise(doc))
        rc = 0
    relaunch_live(plan, args.no_relaunch)
    return rc


if __name__ == "__main__":
    sys.exit(main())
