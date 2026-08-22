#!/usr/bin/env python3
"""Drive the M1K3-for-Android eval harness over adb, one matrix cell per launch.

    ./run.py --device 59021JEBF12282 \
        --models qwen35_0b8,qwen35_2b \
        --thinking off,on \
        --variants armv8.6_1,armv9.0_1 \
        --fixtures 'fixtures/*.json' \
        --out runs/2026-08-22

Each cell = one (model, thinking, cpu-variant) combination = one fresh
`am force-stop` + `am start` of MainActivity with `m1k3.eval.*` extras (see
`composeApp/.../eval/EvalHarness.kt`). A fresh process per cell matters for
two reasons: `ma_core`'s CPU-backend load is once-per-process (so the
cpu-variant override needs a clean slate to mean anything), and the
`SELECTED_M1K3_TIER` preference is only read when a fresh
`ChatScreenViewModel` is constructed.

Waits for EITHER the results file to appear on-device OR the app process to
exit (never a fixed sleep) — a crashed run leaves no file and a dead
process, which is recorded as its own cell status rather than silently
hanging or silently passing.

stdlib only, no deps beyond `adb` on PATH.

Signed: Kev + claude-fable-5, 2026-08-22, Confidence 0.7 (the launch
contract and JSON shapes are pinned by the Kotlin-side tests; the actual
device timing/behaviour — how long a cell really takes, whether force-stop
is enough to reset ma_core's once-per-process backend load — is
verify-by-run, not yet run against real hardware by this script itself).
Prior: Unknown.
"""

import argparse
import glob
import json
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

PACKAGE = "app.m1k3"
ACTIVITY = f"{PACKAGE}/.ai.assistant.MainActivity"
DEVICE_TMP_FIXTURES_PATH = "/data/local/tmp/m1k3_eval_fixtures.json"
APP_FIXTURES_PATH = f"/data/data/{PACKAGE}/files/m1k3_eval_fixtures.json"
APP_RESULTS_PATH = f"/data/data/{PACKAGE}/files/m1k3_eval_results.json"

# Mirrors ma_core.cpp's kAndroidCpuBackendVariants — see that file's own
# comment for why armv8.6_1 is tried first in production (the Pixel 9a
# SVE2 broken-logits bug this harness exists to reproduce as a fixture).
VARIANT_FILENAMES = {
    "armv8.0_1": "libggml-cpu-android_armv8.0_1.so",
    "armv8.2_1": "libggml-cpu-android_armv8.2_1.so",
    "armv8.2_2": "libggml-cpu-android_armv8.2_2.so",
    "armv8.6_1": "libggml-cpu-android_armv8.6_1.so",
    "armv9.0_1": "libggml-cpu-android_armv9.0_1.so",
    "armv9.2_1": "libggml-cpu-android_armv9.2_1.so",
    "armv9.2_2": "libggml-cpu-android_armv9.2_2.so",
}

# Mirrors EvalModelKey (Kotlin) — the m1k3.eval.model extra's accepted values.
MODEL_KEYS = {"qwen35_0b8", "qwen35_2b", "gemma4_e2b"}

DEFAULT_CELL_TIMEOUT_S = 20 * 60
POLL_INTERVAL_S = 3
# A single fixture with no progress for this long is treated as a native hang
# (an uncancellable llama_decode — see EvalRunReport.inProgress): the process
# is killed and the cell resumes past it. Big's cold model load is exempted by
# only starting the clock once the first fixture is in-flight.
FIXTURE_STALL_S = 240
MAX_LAUNCHES_PER_CELL = 40


def adb(serial, *args, check=True, capture=True):
    cmd = ["adb", "-s", serial] + list(args)
    result = subprocess.run(cmd, capture_output=capture, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result


def load_fixtures(patterns):
    fixtures = []
    seen_ids = set()
    matched_any = False
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            matched_any = True
            data = json.loads(Path(path).read_text())
            for fixture in data:
                fid = fixture["id"]
                if fid in seen_ids:
                    sys.exit(f"duplicate fixture id '{fid}' — first seen before {path}")
                seen_ids.add(fid)
                fixtures.append(fixture)
    if not matched_any:
        sys.exit(f"no files matched {patterns}")
    if not fixtures:
        sys.exit(f"{patterns} matched files but they contained zero fixtures")
    return fixtures


def push_fixtures(serial, fixtures):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(fixtures, handle)
        local_path = handle.name
    try:
        adb(serial, "push", local_path, DEVICE_TMP_FIXTURES_PATH)
        adb(serial, "shell", "run-as", PACKAGE, "cp", DEVICE_TMP_FIXTURES_PATH, APP_FIXTURES_PATH)
    finally:
        Path(local_path).unlink(missing_ok=True)
    return APP_FIXTURES_PATH


def device_process_alive(serial):
    result = adb(serial, "shell", "pidof", PACKAGE, check=False)
    return bool(result.stdout.strip())


def device_file_exists(serial, path):
    result = adb(serial, "shell", "run-as", PACKAGE, "test", "-f", path, check=False)
    return result.returncode == 0


def pull_text(serial, path):
    result = adb(serial, "exec-out", "run-as", PACKAGE, "cat", path, check=False)
    return result.stdout


def _launch(serial, fixtures_path, model, thinking, variant, skip):
    adb(serial, "shell", "am", "force-stop", PACKAGE, check=False)
    adb(serial, "shell", "run-as", PACKAGE, "rm", "-f", APP_RESULTS_PATH, APP_RESULTS_PATH + ".tmp", check=False)
    args = [
        "shell", "am", "start", "-n", ACTIVITY,
        "--es", "m1k3.eval.fixtures", fixtures_path,
        "--es", "m1k3.eval.out", APP_RESULTS_PATH,
    ]
    if model:
        args += ["--es", "m1k3.eval.model", model]
    if thinking is not None:
        args += ["--ez", "m1k3.eval.thinking", "true" if thinking else "false"]
    if variant:
        args += ["--es", "m1k3.eval.cpu_variant", VARIANT_FILENAMES[variant]]
    if skip:
        args += ["--es", "m1k3.eval.skip", ",".join(sorted(skip))]
    adb(serial, *args)


def _read_report(serial):
    if not device_file_exists(serial, APP_RESULTS_PATH):
        return None
    raw = pull_text(serial, APP_RESULTS_PATH)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def run_cell(serial, fixtures_path, model, thinking, variant, cell_timeout, all_ids):
    """Run one matrix cell to completion, surviving native hangs.

    The app writes its results file after every fixture, naming the in-flight
    fixture in `inProgress`. We watchdog that: a fixture that stays in-flight
    while the completed-results count doesn't grow for FIXTURE_STALL_S is a
    native hang (a stuck llama_decode no coroutine timeout can cancel). We kill
    the process, record the fixture as `hung`, and relaunch with it added to
    the skip set — resuming the cell instead of losing it.
    """
    done = {}            # fixture id -> result dict (from the app)
    hung = {}            # fixture id -> synthetic hung result
    meta = None
    cell_deadline = time.time() + cell_timeout
    launches = 0

    while len(done) + len(hung) < len(all_ids) and launches < MAX_LAUNCHES_PER_CELL:
        if time.time() >= cell_deadline:
            break
        skip = set(done) | set(hung)
        _launch(serial, fixtures_path, model, thinking, variant, skip)
        launches += 1

        last_progress = time.time()
        last_count = len(done)
        last_inflight = None

        while True:
            time.sleep(POLL_INTERVAL_S)
            report = _read_report(serial)
            alive = device_process_alive(serial)

            if report is not None:
                if report.get("run"):
                    meta = report["run"]
                for r in report.get("results", []):
                    done[r["fixtureId"]] = r
                inflight = report.get("inProgress")
                if len(done) > last_count or inflight != last_inflight:
                    last_progress = time.time()
                    last_count = len(done)
                    last_inflight = inflight

                # Completed cleanly: process exiting with inProgress cleared.
                if inflight is None and not alive:
                    return {"meta": meta, "done": done, "hung": hung, "launches": launches}

                # Stalled on one fixture past the grace window → hang.
                if inflight is not None and time.time() - last_progress > FIXTURE_STALL_S:
                    print(f"    ! {inflight} hung ({FIXTURE_STALL_S}s no progress) — skipping")
                    hung[inflight] = {
                        "fixtureId": inflight, "kind": None, "passed": False,
                        "failedChecks": ["native-hang"], "answer": "", "thinking": None,
                        "toolsCalled": [], "chars": 0, "tokens": 0,
                        "generateMs": int((time.time() - last_progress) * 1000),
                        "firstTokenMs": None, "error": "native hang (killed by watchdog)",
                    }
                    adb(serial, "shell", "am", "force-stop", PACKAGE, check=False)
                    break
            elif not alive:
                # Process gone with no readable file: a crash with no partial.
                # Relaunch (skip set unchanged) unless nothing is progressing.
                if time.time() - last_progress > FIXTURE_STALL_S:
                    break

            if time.time() >= cell_deadline:
                break

    return {"meta": meta, "done": done, "hung": hung, "launches": launches}

def device_header(serial):
    model = adb(serial, "shell", "getprop", "ro.product.model", check=False).stdout.strip()
    battery_dump = adb(serial, "shell", "dumpsys", "battery", check=False).stdout
    level = None
    for line in battery_dump.splitlines():
        line = line.strip()
        if line.startswith("level:"):
            level = line.split(":", 1)[1].strip()
            break
    return {
        "device": model or "unknown",
        "batteryLevel": level,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", required=True, help="adb serial, e.g. 59021JEBF12282 (always -s, never implicit)")
    ap.add_argument("--models", default="", help="comma list of qwen35_0b8,qwen35_2b,gemma4_e2b (empty = leave the currently-selected tier)")
    ap.add_argument("--thinking", default="", help="comma list of off,on (empty = leave ThinkingPolicy's per-model default)")
    ap.add_argument("--variants", default="", help="comma list, e.g. armv8.6_1,armv9.0_1 (empty = native default order)")
    ap.add_argument("--fixtures", nargs="+", required=True, help="glob(s) of fixture JSON files, e.g. fixtures/*.json")
    ap.add_argument("--out", required=True, help="local output directory for this run")
    ap.add_argument("--cell-timeout", type=int, default=DEFAULT_CELL_TIMEOUT_S, help=f"seconds per cell (default {DEFAULT_CELL_TIMEOUT_S})")
    args = ap.parse_args()

    fixtures = load_fixtures(args.fixtures)
    print(f"{len(fixtures)} fixtures loaded from {args.fixtures}")
    all_ids = [f["id"] for f in fixtures]

    models = [m.strip() for m in args.models.split(",") if m.strip()] or [None]
    for model in models:
        if model and model not in MODEL_KEYS:
            sys.exit(f"unknown model key '{model}' — expected one of {sorted(MODEL_KEYS)}")

    thinking_labels = [t.strip() for t in args.thinking.split(",") if t.strip()] or [None]
    for label in thinking_labels:
        if label not in (None, "off", "on"):
            sys.exit(f"unknown --thinking value '{label}' — expected off/on")

    variants = [v.strip() for v in args.variants.split(",") if v.strip()] or [None]
    for variant in variants:
        if variant and variant not in VARIANT_FILENAMES:
            sys.exit(f"unknown variant '{variant}' — expected one of {sorted(VARIANT_FILENAMES)}")

    out_dir = Path(args.out)
    raw_dir = out_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    header = device_header(args.device)
    header["fixtureCount"] = len(fixtures)
    print(f"device={header['device']} battery={header['batteryLevel']}%")

    device_fixtures_path = push_fixtures(args.device, fixtures)
    print(f"fixtures pushed to {device_fixtures_path}")

    manifest = {"header": header, "cells": []}

    # Keep the device awake for the whole run. A cell that outlives the screen
    # timeout leaves the activity cached; Android's freezer then kills it
    # ("Async binder space running out while frozen", Pixel 9a 2026-08-22) and
    # the cell reads as crashed. Restored in the finally below.
    adb(args.device, "shell", "svc", "power", "stayon", "true", check=False)
    adb(args.device, "shell", "input", "keyevent", "KEYCODE_WAKEUP", check=False)
    adb(args.device, "shell", "wm", "dismiss-keyguard", check=False)

    total_cells = len(models) * len(thinking_labels) * len(variants)
    cell_num = 0
    for model in models:
        for thinking_label in thinking_labels:
            thinking = None if thinking_label is None else thinking_label == "on"
            for variant in variants:
                cell_num += 1
                cell_id = "-".join(filter(None, [model or "default", thinking_label, variant])) or "default"
                print(f"\n=== [{cell_num}/{total_cells}] cell: {cell_id} ===")

                outcome = run_cell(
                    args.device, device_fixtures_path, model, thinking, variant,
                    args.cell_timeout, all_ids,
                )
                results = list(outcome["done"].values()) + list(outcome["hung"].values())
                n_hung = len(outcome["hung"])
                status = (
                    "ok" if len(results) == len(all_ids) and n_hung == 0
                    else "partial" if results
                    else "crashed"
                )
                print(f"  status={status} ({len(outcome['done'])} ok, {n_hung} hung, "
                      f"{len(all_ids) - len(results)} missing, {outcome['launches']} launch(es))")

                raw_path = raw_dir / f"{cell_id}.json"
                raw_path.write_text(json.dumps(
                    {"run": outcome["meta"], "results": results}, indent=2,
                ))

                manifest["cells"].append(
                    {
                        "id": cell_id,
                        "model": model,
                        "thinking": thinking_label,
                        "variant": variant,
                        "status": status,
                        "hung": sorted(outcome["hung"]),
                        "launches": outcome["launches"],
                        "raw": str(raw_path),
                    }
                )

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nwrote {out_dir / 'manifest.json'}")
    adb(args.device, "shell", "svc", "power", "stayon", "false", check=False)
    print(f"next: ./scorecard.py {out_dir}")


if __name__ == "__main__":
    main()
