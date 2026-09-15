#!/usr/bin/env python3
"""The power receipt — what an answer costs in watt-hours, measured, not assumed.

Two halves, run in this order:

  1. Kev (sudo, in another terminal — powermetrics is root-only):
       sudo -b powermetrics --samplers cpu_power,gpu_power -i 500 -n 1200 \
            -o ~/.cache/m1k3-power/<brain>-<date>.log
  2. This tool drives real questions through the installed app's `m1k3 ask`
     and stamps each turn's wall-clock window:
       python3 tools/eval/power_receipt.py drive --brain lil --out turns.json
     then folds the two together:
       python3 tools/eval/power_receipt.py report --log <log> --turns turns.json \
            --idle-seconds 30 --out docs/evals/<date>-power-receipt-<brain>.json

The receipt charges each answer only the energy ABOVE the idle baseline
(median package watts over the idle window recorded before the first
question), integrated over the turn's window. It is whole-machine package
power (CPU + GPU + ANE), so anything else running during the run is billed
to the answers — run it on a quiet Mac and say so in the provenance.

Why not a per-process counter: task_info(TASK_POWER_INFO_V2).task_energy is
CPU-only on Apple Silicon (a 6.6 TFLOP/s Metal burn read 0.06 J in the
2026-09-15 spike), and rusage's ri_billed_energy never moves. The brain runs
on the GPU. Only package power tells the truth.

Signed: Kev + claude-fable-5.1, 2026-09-15 (launch night), Confidence 0.8.
The parse and the maths are pinned in test_power_receipt.py on hand-built
samples; the drive half shells out to the shipping `m1k3` helper so the
measured turns are the product's own turns, not a harness's. Open: token
counts per answer (the app's log has them; v1 records chars). Prior: Unknown.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

M1K3 = "/Applications/M1K3.app/Contents/Helpers/m1k3"

# Ten ordinary questions: no web, no documents needed, short-to-medium answers.
DEFAULT_QUESTIONS = [
    "In one sentence, what is a knowledge graph?",
    "Give me three tips for focusing on a long task.",
    "Explain what a hash function is, briefly.",
    "What's a good name for a fox who fixes computers? One or two suggestions.",
    "Summarise the plot of Frankenstein in two sentences.",
    "How do I boil an egg so the yolk is jammy?",
    "What's the difference between weather and climate?",
    "Write a haiku about a quiet machine.",
    "Why is the sky blue? Keep it short.",
    "List four uses for a Raspberry Pi.",
]

_SAMPLE_HEAD = re.compile(r"^\*\*\* Sampled system activity \((.+?)\) \(([\d.]+)ms elapsed\) \*\*\*$", re.M)
_MW = re.compile(r"^(CPU Power|GPU Power|ANE Power|Combined Power \(CPU \+ GPU \+ ANE\)): (\d+) mW$", re.M)


@dataclass(frozen=True)
class Sample:
    at: datetime          # whole-second stamp — two `-i 500` samples share one
    watts: float
    cpu_watts: float
    gpu_watts: float
    elapsed_s: float      # this sample's own duration, from its header's "(NNNms elapsed)"


@dataclass(frozen=True)
class Turn:
    question: str
    answer: str
    start: datetime
    end: datetime

    def to_json(self) -> dict:
        return {"question": self.question, "answer": self.answer, "start": self.start.isoformat(), "end": self.end.isoformat()}

    @classmethod
    def from_json(cls, d: dict) -> "Turn":
        return cls(d["question"], d["answer"], datetime.fromisoformat(d["start"]), datetime.fromisoformat(d["end"]))


def parse_powermetrics(text: str) -> list[Sample]:
    """One Sample per complete `*** Sampled system activity …` block.

    Uses the Combined line when powermetrics prints it, else CPU + GPU. A
    trailing block cut off mid-write (the log is read while it is still being
    written) is dropped rather than mis-summed.
    """
    heads = list(_SAMPLE_HEAD.finditer(text))
    out: list[Sample] = []
    for i, h in enumerate(heads):
        body = text[h.end(): heads[i + 1].start() if i + 1 < len(heads) else len(text)]
        vals: dict[str, int] = {}
        for m in _MW.finditer(body):
            vals.setdefault(m.group(1), int(m.group(2)))   # first occurrence wins (the GPU section repeats GPU Power)
        if "CPU Power" not in vals or "GPU Power" not in vals:
            continue
        at = datetime.strptime(h.group(1), "%a %b %d %H:%M:%S %Y %z")
        combined = vals.get("Combined Power (CPU + GPU + ANE)", vals["CPU Power"] + vals["GPU Power"] + vals.get("ANE Power", 0))
        out.append(Sample(at, combined / 1000.0, vals["CPU Power"] / 1000.0, vals["GPU Power"] / 1000.0, float(h.group(2)) / 1000.0))
    return out


def _window(samples: list[Sample], start: datetime, end: datetime) -> list[Sample]:
    window = [s for s in samples if start <= s.at < end]
    if not window:
        raise SystemExit(f"no powermetrics samples in the idle window {start.isoformat()} → {end.isoformat()}")
    return window


def idle_watts(samples: list[Sample], start: datetime, end: datetime) -> float:
    """Median package watts over [start, end) — the machine's cost of existing."""
    return statistics.median(s.watts for s in _window(samples, start, end))


def idle_stats(samples: list[Sample], start: datetime, end: datetime) -> dict:
    """The idle window as numbers a reader can judge without the raw log: median, min, max, count.
    A max more than a few watts above the median means the Mac was not quiet."""
    w = [s.watts for s in _window(samples, start, end)]
    return {"idle_watts": round(statistics.median(w), 2), "idle_min_watts": round(min(w), 2), "idle_max_watts": round(max(w), 2), "idle_samples": len(w)}


def _interval(samples: list[Sample]) -> float:
    """Median sample duration by the samples' own headers. Timestamps are whole seconds and
    cannot give this; and under contention powermetrics' loop slips, so a run captured at
    -i 500 that reports well above 0.5 s here was fighting for the cores."""
    return statistics.median(s.elapsed_s for s in samples) if samples else 1.0


def receipt(turns: list[Turn], samples: list[Sample], idle_watts: float, provenance: dict | None = None) -> dict:
    """Per-turn energy above idle, integrated over each turn's [start, end) window — each sample
    weighted by its own duration, never by an assumed interval."""
    dt = _interval(samples)
    rows = []
    for t in turns:
        inside = [s for s in samples if t.start <= s.at < t.end]
        seconds = (t.end - t.start).total_seconds()
        joules = sum(max(s.watts - idle_watts, 0.0) * s.elapsed_s for s in inside)
        mean_w = statistics.fmean(s.watts for s in inside) if inside else 0.0
        peak_w = max((s.watts for s in inside), default=0.0)
        rows.append({
            "question": t.question,
            "answer_chars": len(t.answer),
            "seconds": round(seconds, 2),
            "samples": len(inside),
            "mean_watts": round(mean_w, 2),
            "peak_watts": round(peak_w, 2),
            "joules_above_idle": round(joules, 2),
            "wh_above_idle": round(joules / 3600.0, 5),
        })
    whs = [r["wh_above_idle"] for r in rows]
    summary = {
        "turns": len(rows),
        "idle_watts": round(idle_watts, 2),
        "sample_interval_seconds": dt,
        "median_wh_per_answer": round(statistics.median(whs), 5) if whs else None,
        "mean_wh_per_answer": round(statistics.fmean(whs), 5) if whs else None,
        "median_seconds_per_answer": round(statistics.median(r["seconds"] for r in rows), 2) if rows else None,
        "total_wh_above_idle": round(sum(whs), 5),
    }
    return {"provenance": provenance or {}, "summary": summary, "turns": rows}


# ---------------------------------------------------------------------- drive

def drive(questions: list[str], out: Path, brain: str, idle_seconds: int, m1k3: str = M1K3) -> dict:
    """Idle for `idle_seconds`, then ask each question through the shipping CLI, stamping wall-clock windows."""
    tz = datetime.now().astimezone().tzinfo
    idle_start = datetime.now(tz)
    print(f"idle baseline: {idle_seconds}s — leave the Mac alone", file=sys.stderr)
    time.sleep(idle_seconds)
    idle_end = datetime.now(tz)
    turns: list[Turn] = []
    for i, q in enumerate(questions, 1):
        t0 = datetime.now(tz)
        r = subprocess.run([m1k3, "ask", q], capture_output=True, text=True, timeout=300)
        t1 = datetime.now(tz)
        answer = r.stdout.strip()
        print(f"[{i}/{len(questions)}] {(t1 - t0).total_seconds():5.1f}s  {len(answer):4d} chars  {q[:48]}", file=sys.stderr)
        turns.append(Turn(q, answer, t0, t1))
        time.sleep(3)   # let the machine settle between answers
    doc = {
        "brain": brain,
        "idle_window": {"start": idle_start.isoformat(), "end": idle_end.isoformat()},
        "turns": [t.to_json() for t in turns],
    }
    out.write_text(json.dumps(doc, indent=2, ensure_ascii=False))
    print(f"wrote {out}", file=sys.stderr)
    return doc


def report(log: Path, turns_path: Path, out: Path | None, provenance: dict) -> dict:
    doc = json.loads(turns_path.read_text())
    samples = parse_powermetrics(log.read_text())
    i0, i1 = datetime.fromisoformat(doc["idle_window"]["start"]), datetime.fromisoformat(doc["idle_window"]["end"])
    turns = [Turn.from_json(t) for t in doc["turns"]]
    prov = {"brain": doc.get("brain"), "samples": len(samples), "log": log.name, **provenance}
    r = receipt(turns, samples, idle_watts(samples, i0, i1), prov)   # bill against the unrounded median
    r["summary"].update(idle_stats(samples, i0, i1))                  # round for display only
    if out:
        out.write_text(json.dumps(r, indent=2, ensure_ascii=False) + "\n")
    s = r["summary"]
    print(f"idle {s['idle_watts']} W · {s['turns']} answers · median {s['median_wh_per_answer']} Wh "
          f"({s['median_seconds_per_answer']} s) · mean {s['mean_wh_per_answer']} Wh · total {s['total_wh_above_idle']} Wh")
    for row in r["turns"]:
        print(f"  {row['wh_above_idle']:.5f} Wh  {row['seconds']:5.1f}s  peak {row['peak_watts']:5.1f} W  {row['question'][:52]}")
    return r


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("drive", help="ask the questions through m1k3 and stamp the windows")
    d.add_argument("--out", type=Path, required=True)
    d.add_argument("--brain", required=True, help="the active brain, as Settings shows it (lil / mini / big)")
    d.add_argument("--idle-seconds", type=int, default=30)
    d.add_argument("--questions", type=Path, help="one question per line (default: the built-in ten)")
    d.add_argument("--m1k3", default=M1K3)
    r = sub.add_parser("report", help="fold a powermetrics log and a turns file into the receipt")
    r.add_argument("--log", type=Path, required=True)
    r.add_argument("--turns", type=Path, required=True)
    r.add_argument("--out", type=Path)
    r.add_argument("--provenance", default="{}", help='JSON, e.g. {"machine":"M1 Max 64 GB","power_source":"ac","app":"1.0.0 (362)"}')
    args = ap.parse_args(argv)
    if args.cmd == "drive":
        qs = [q.strip() for q in args.questions.read_text().splitlines() if q.strip()] if args.questions else DEFAULT_QUESTIONS
        drive(qs, args.out, args.brain, args.idle_seconds, args.m1k3)
        return 0
    report(args.log, args.turns, args.out, json.loads(args.provenance))
    return 0


if __name__ == "__main__":
    sys.exit(main())
