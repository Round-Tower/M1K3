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


def run_cell(serial, fixtures_path, model, thinking, variant, cell_timeout):
    adb(serial, "shell", "am", "force-stop", PACKAGE, check=False)
    adb(serial, "shell", "run-as", PACKAGE, "rm", "-f", APP_RESULTS_PATH, check=False)

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
    adb(serial, *args)

    deadline = time.time() + cell_timeout
    got_file = False
    while time.time() < deadline:
        if device_file_exists(serial, APP_RESULTS_PATH):
            got_file = True
            break
        if not device_process_alive(serial):
            # The activity may still be flushing the file at the moment the
            # process count last read as zero — give it one more beat.
            time.sleep(2)
            got_file = device_file_exists(serial, APP_RESULTS_PATH)
            break
        time.sleep(POLL_INTERVAL_S)

    if not got_file and time.time() >= deadline:
        return {"status": "timeout", "raw": None}
    if got_file:
        raw_text = pull_text(serial, APP_RESULTS_PATH)
        try:
            return {"status": "ok", "raw": json.loads(raw_text)}
        except json.JSONDecodeError:
            return {"status": "unparseable", "raw": raw_text}
    return {"status": "crashed", "raw": None}


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

    total_cells = len(models) * len(thinking_labels) * len(variants)
    cell_num = 0
    for model in models:
        for thinking_label in thinking_labels:
            thinking = None if thinking_label is None else thinking_label == "on"
            for variant in variants:
                cell_num += 1
                cell_id = "-".join(filter(None, [model or "default", thinking_label, variant])) or "default"
                print(f"\n=== [{cell_num}/{total_cells}] cell: {cell_id} ===")

                outcome = run_cell(args.device, device_fixtures_path, model, thinking, variant, args.cell_timeout)
                print(f"  status={outcome['status']}")

                raw_path = None
                if outcome["raw"] is not None:
                    raw_path = raw_dir / f"{cell_id}.json"
                    if isinstance(outcome["raw"], (dict, list)):
                        raw_path.write_text(json.dumps(outcome["raw"], indent=2))
                    else:
                        raw_path.write_text(outcome["raw"])

                manifest["cells"].append(
                    {
                        "id": cell_id,
                        "model": model,
                        "thinking": thinking_label,
                        "variant": variant,
                        "status": outcome["status"],
                        "raw": str(raw_path) if raw_path else None,
                    }
                )

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nwrote {out_dir / 'manifest.json'}")
    print(f"next: ./scorecard.py {out_dir}")


if __name__ == "__main__":
    main()
