#!/usr/bin/env python3
"""The power receipt — what an answer costs in watt-hours, measured, not assumed.

Run in this order:

  1. Kev (sudo, in another terminal — powermetrics is root-only):
       sudo -b powermetrics --samplers cpu_power,gpu_power -i 500 -n 1200 \
            -o ~/.cache/m1k3-power/<brain>-<date>.log
  2. This tool drives real questions through the installed app's `m1k3 ask`
     and stamps each turn's wall-clock window:
       python3 tools/eval/power_receipt.py drive --brain lil --out turns.json
     then folds the two together:
       python3 tools/eval/power_receipt.py report --log <log> --turns turns.json \
            --out docs/evals/<date>-power-receipt-<brain>.json
  3. For an MLX tier, `rates` splits each generation into prefill and decode by the
     app's ttft lines (`log show` over the run) and prices each phase per token:
       python3 tools/eval/power_receipt.py rates --log <log> --turns turns.json \
            --ttft ttft.log --out docs/evals/<date>-power-rates-<brain>-run<N>.json
  `tools/eval/power_run.zsh <brain> <run>` does all three, with the preflight checks.

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

Review: Kev + claude-opus-5.5, 2026-10-27 (#696 receipts) — `rates`: places the
whole-second samples on the clock by their own elapsed headers (a run per
unbroken stretch, so a slipped loop leaves a gap, not a smeared clock), times
each generation's prefill and decode by its ttft line, fits each phase's watts
by least squares, and checks the placement against the data (`alignment_check`).
The receipt moved onto the same placement, counts a sample for the part a turn
holds, unclipped, and reads the GPU section's power line (the summary's copy
glitches). A blind re-derivation found the prorated split read low at phase
edges, the old whole-second binning 5–7 % low on Lil, and the glitch; all three
are folded, and it agrees with the fit to 0.1 %. Retires the Open above: the
token counts come from the ttft lines, joined by time. Its first use calibrated
Lil and Big (docs/ENERGY_MEASUREMENT.md). Confidence 0.85.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
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
    chars: int | None = None   # an answer's length when its text was left out (a committed windows file)

    @property
    def answer_chars(self) -> int:
        return self.chars if self.chars is not None else len(self.answer)

    def to_json(self) -> dict:
        return {"question": self.question, "answer": self.answer, "start": self.start.isoformat(), "end": self.end.isoformat()}

    @classmethod
    def from_json(cls, d: dict) -> Turn:
        start, end = datetime.fromisoformat(d["start"]), datetime.fromisoformat(d["end"])
        if "answer" in d:
            return cls(d["question"], d["answer"], start, end)
        return cls(d["question"], "", start, end, chars=d["answer_chars"])


def read_text(path: Path) -> str:
    """A log as written, or gzipped (`docs/evals` keeps the raw powermetrics logs as .gz)."""
    return gzip.decompress(path.read_bytes()).decode() if path.suffix == ".gz" else path.read_text()


def parse_powermetrics(text: str) -> list[Sample]:
    """One Sample per complete `*** Sampled system activity …` block: CPU + GPU + ANE.

    The GPU figure is the GPU section's own `GPU Power` line (the last one in the
    block). The processor summary's copy, which the Combined line is built from,
    now and then reads near 0 for one sample and about double the next (every
    2026-10-27 log, and September's): the run's total is the same, but the energy
    lands in the wrong half-second, which matters once a window is shorter than a
    second. A trailing block cut off mid-write (the log is read while it is still
    being written) is dropped rather than mis-summed.
    """
    heads = list(_SAMPLE_HEAD.finditer(text))
    out: list[Sample] = []
    for i, h in enumerate(heads):
        body = text[h.end(): heads[i + 1].start() if i + 1 < len(heads) else len(text)]
        vals: dict[str, int] = {}
        for m in _MW.finditer(body):
            vals[m.group(1)] = int(m.group(2))   # last occurrence wins: the GPU section's line
        if "CPU Power" not in vals or "GPU Power" not in vals:
            continue
        at = datetime.strptime(h.group(1), "%a %b %d %H:%M:%S %Y %z")
        watts = vals["CPU Power"] + vals["GPU Power"] + vals.get("ANE Power", 0)
        out.append(Sample(at, watts / 1000.0, vals["CPU Power"] / 1000.0, vals["GPU Power"] / 1000.0, float(h.group(2)) / 1000.0))
    return out


def _window(placed: list[Placed], start: datetime, end: datetime) -> list[Placed]:
    """The placed samples wholly inside [start, end)."""
    window = [p for p in placed if start <= p.start and p.end <= end]
    if not window:
        raise SystemExit(f"no powermetrics samples in the idle window {start.isoformat()} → {end.isoformat()}")
    return window


def idle_watts(placed: list[Placed], start: datetime, end: datetime) -> float:
    """Median package watts over [start, end) — the machine's cost of existing."""
    return statistics.median(p.sample.watts for p in _window(placed, start, end))


def idle_stats(placed: list[Placed], start: datetime, end: datetime) -> dict:
    """The idle window as numbers a reader can judge without the raw log: median, min, max, count.
    A max more than a few watts above the median means the Mac was not quiet."""
    inside = _window(placed, start, end)
    w = [p.sample.watts for p in inside]
    return {
        "idle_watts": round(statistics.median(w), 2), "idle_min_watts": round(min(w), 2), "idle_max_watts": round(max(w), 2),
        "idle_samples": len(w),
        # what the idle was made of; the Neural Engine is the package less CPU and GPU
        "idle_cpu_watts": round(statistics.median(p.sample.cpu_watts for p in inside), 2),
        "idle_gpu_watts": round(statistics.median(p.sample.gpu_watts for p in inside), 2),
        "idle_ane_watts": round(statistics.median(p.sample.watts - p.sample.cpu_watts - p.sample.gpu_watts for p in inside), 2),
    }


def _interval(placed: list[Placed]) -> float:
    """Median sample duration by the samples' own headers. Timestamps are whole seconds and
    cannot give this; and under contention powermetrics' loop slips, so a run captured at
    -i 500 that reports well above 0.5 s here was fighting for the cores."""
    return statistics.median(p.sample.elapsed_s for p in placed) if placed else 1.0


def _overlap(p: Placed, start: datetime, end: datetime) -> float:
    return max(0.0, (min(end, p.end) - max(start, p.start)).total_seconds())


def receipt(turns: list[Turn], placed: list[Placed], idle_watts: float, provenance: dict | None = None) -> dict:
    """Per-turn energy above idle over each turn's [start, end): every placed sample counted for the
    part of it the turn holds. A sample below the idle median counts below zero, so a noisy idle
    neither inflates nor hides an answer. The whole-second binning this replaced (2026-10-27) read
    Lil's ten answers 5–7 % low and one of them 28 % low."""
    dt = _interval(placed)
    rows = []
    for t in turns:
        inside = [(p, _overlap(p, t.start, t.end)) for p in placed if _overlap(p, t.start, t.end) > 0]
        seconds = (t.end - t.start).total_seconds()
        joules = energy_above(placed, t.start, t.end, idle_watts)
        held = sum(ov for _, ov in inside)
        mean_w = sum(p.sample.watts * ov for p, ov in inside) / held if held else 0.0
        peak_w = max((p.sample.watts for p, _ in inside), default=0.0)
        # `watts` is PACKAGE power (CPU + GPU + ANE). The split is carried too, so a
        # sentence like "the GPU did the work" is backed by a field, not a shorthand.
        mean_cpu = sum(p.sample.cpu_watts * ov for p, ov in inside) / held if held else 0.0
        mean_gpu = sum(p.sample.gpu_watts * ov for p, ov in inside) / held if held else 0.0
        rows.append({
            "question": t.question,
            "answer_chars": t.answer_chars,
            "seconds": round(seconds, 2),
            "samples": len(inside),
            "mean_watts": round(mean_w, 2),
            "peak_watts": round(peak_w, 2),
            "mean_cpu_watts": round(mean_cpu, 2),
            "mean_gpu_watts": round(mean_gpu, 2),
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
        "median_mean_watts": round(statistics.median(r["mean_watts"] for r in rows), 2) if rows else None,
        "median_mean_cpu_watts": round(statistics.median(r["mean_cpu_watts"] for r in rows), 2) if rows else None,
        "median_mean_gpu_watts": round(statistics.median(r["mean_gpu_watts"] for r in rows), 2) if rows else None,
        "total_wh_above_idle": round(sum(whs), 5),
    }
    return {"provenance": provenance or {}, "summary": summary, "turns": rows}


# ---------------------------------------------------------------------- rates (#696)
# The receipt bills whole turns. The app's ledger prices tokens, so a per-token rate needs each
# generation split into its prefill and its decode. The app's ttft line times both, and it is logged
# when decode ends. powermetrics stamps each 500 ms sample to the whole second, so the samples are
# first placed on the clock: laid end to end by their own "(NNNms elapsed)" headers, at the one offset
# every whole-second stamp allows (a stamp is the second its sample ended in). The headers' jitter
# narrows that offset to a few milliseconds. `alignment_check` then tests the placement against the
# data: the shift of the ttft clock at which the phase fit's error is smallest should be zero.

_TTFT = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*\[app\.m1k3:ttft\] \w+ \[(.+?)\]: "
    r"prompt=(\d+)tok prefill=(\d+)ms decode=(\d+)tok @(\d+)tok/s", re.MULTILINE)


@dataclass(frozen=True)
class Placed:
    sample: Sample
    start: datetime
    end: datetime


@dataclass(frozen=True)
class Generation:
    end: datetime          # the ttft line's own stamp: logged when decode ends
    model: str
    prompt_tokens: int     # the tokens this generation prefilled
    prefill_s: float
    decode_tokens: int
    decode_s: float        # decode tokens ÷ (the line's tok/s + 0.5): it prints the rate truncated


def _segments(samples: list[Sample]) -> list[tuple[int, int, float, float]]:
    """Runs of samples that one offset fits: (first index, count, lo, hi), where an offset in
    [lo, hi] seconds past the run's first stamp lays every sample's end inside the whole second its
    stamp names. When powermetrics' loop slips (a gap no header covers), the next sample opens a
    new run, so the gap stays unsampled instead of smearing the clock."""
    out, i = [], 0
    while i < len(samples):
        lo, hi, cum, j, base = float("-inf"), float("inf"), 0.0, i, samples[i].at
        while j < len(samples):
            c = cum + samples[j].elapsed_s
            k = (samples[j].at - base).total_seconds()
            nlo, nhi = max(lo, k - c), min(hi, k + 1 - c)
            if nlo > nhi:
                break
            lo, hi, cum, j = nlo, nhi, c, j + 1
        out.append((i, j - i, lo, hi))
        i = j
    return out


def placement_slack(samples: list[Sample]) -> float:
    """How far the least-pinned run could still move, in seconds. Near zero is a well-placed log."""
    return max(hi - lo for _, _, lo, hi in _segments(samples))


def place(samples: list[Sample]) -> list[Placed]:
    """Each sample's own [start, end) on the clock, to a few milliseconds: each run laid end to end
    from the middle of its offset range, never back over the run before it."""
    if not samples:
        raise SystemExit("no powermetrics samples to place")
    out: list[Placed] = []
    for first, count, lo, hi in _segments(samples):
        t = samples[first].at + timedelta(seconds=(lo + hi) / 2)
        if out and t < out[-1].end:
            t = out[-1].end
        for s in samples[first:first + count]:
            out.append(Placed(s, t, t + timedelta(seconds=s.elapsed_s)))
            t = out[-1].end
    return out


def parse_ttft(text: str, tz) -> list[Generation]:
    """One Generation per `[app.m1k3:ttft]` line of `log show --style compact` (local wall-clock stamps)."""
    out = []
    for m in _TTFT.finditer(text):
        end = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=tz)
        decode, tps = int(m.group(5)), int(m.group(6))
        # The line truncates tok/s, so the true rate is in [tps, tps + 1): its middle is unbiased.
        out.append(Generation(end, m.group(2), int(m.group(3)), int(m.group(4)) / 1000, decode, decode / (tps + 0.5) if tps else 0.0))
    return out


def energy_above(placed: list[Placed], start: datetime, end: datetime, idle_watts: float) -> float:
    """Joules above idle in [start, end), each sample prorated by how much of it the window holds.
    Unclipped: a sample below the idle median counts below zero."""
    return sum((p.sample.watts - idle_watts) * _overlap(p, start, end) for p in placed)


def _solve(a: list[list[float]], b: list[float]) -> list[float]:
    """Gaussian elimination with partial pivoting, for the 3 × 3 normal equations below."""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        pivot = max(range(c, n), key=lambda r: abs(m[r][c]))
        if abs(m[pivot][c]) < 1e-12:
            raise SystemExit("the phase fit is singular: a run needs prefill, decode and some turn time outside both")
        m[c], m[pivot] = m[pivot], m[c]
        for r in range(c + 1, n):
            f = m[r][c] / m[c][c]
            m[r] = [x - f * y for x, y in zip(m[r], m[c], strict=True)]
    x = [0.0] * n
    for r in reversed(range(n)):
        x[r] = (m[r][n] - sum(m[r][k] * x[k] for k in range(r + 1, n))) / m[r][r]
    return x


def _fit_phase_watts(placed, gens, idle_watts, turns) -> tuple[list[float], float, float]:
    """Watts above idle in prefill, in decode and in the rest of a turn, fitted by least squares
    over every sample that touches a turn: each sample's energy above idle = Σ phase watts × the
    seconds of that phase it holds. Prorating alone gives a sample that straddles a phase edge one
    average power across both sides, so the edge's energy leaks out of the generation; the fit puts
    it back. Returns the three watts, the fit's RMS error in watts, and the joules it explains."""
    xtx = [[0.0] * 3 for _ in range(3)]
    xte = [0.0] * 3
    rows = []
    for p in placed:
        in_turn = sum(_overlap(p, a, b) for a, b in turns)
        if in_turn <= 0:
            continue
        pre = sum(_overlap(p, p0, d0) for p0, d0, _ in (_phases(g, 0.0) for g in gens))
        dec = sum(_overlap(p, d0, e) for _, d0, e in (_phases(g, 0.0) for g in gens))
        x = [pre, dec, max(in_turn - pre - dec, 0.0)]
        e = (p.sample.watts - idle_watts) * p.sample.elapsed_s
        rows.append((x, e, p.sample.elapsed_s))
        for i in range(3):
            xte[i] += x[i] * e
            for j in range(3):
                xtx[i][j] += x[i] * x[j]
    watts = _solve(xtx, xte)
    sq = [((sum(w * xi for w, xi in zip(watts, x, strict=True)) - e) / dt) ** 2 for x, e, dt in rows]
    return watts, math.sqrt(statistics.fmean(sq)) if sq else 0.0, sum(e for _, e, _ in rows)


def _phases(g: Generation, shift: float) -> tuple[datetime, datetime, datetime]:
    end = g.end + timedelta(seconds=shift)
    decode_start = end - timedelta(seconds=g.decode_s)
    return decode_start - timedelta(seconds=g.prefill_s), decode_start, end


def alignment_check(placed, gens, idle_watts, turns, reach: float = 1.0, step: float = 0.05) -> dict:
    """Refit with the ttft clock shifted in `step`s across ±`reach` and keep the shift whose fit
    error is smallest (the nearer zero on a tie). Zero means the placement and the log agree. The
    error half a sample either way says how sharply the data pin it."""
    n = round(reach / step)
    scan: dict[float, float] = {}
    for k in range(-n, n + 1):
        shift = round(k * step, 3)
        moved = [replace(g, end=g.end + timedelta(seconds=shift)) for g in gens]
        try:
            scan[shift] = _fit_phase_watts(placed, moved, idle_watts, turns)[1]
        except SystemExit:
            continue
    if 0.0 not in scan:
        raise SystemExit("the phase fit fails at the logged clock: is this the run's own ttft log?")
    best = min(scan, key=lambda s: (scan[s], abs(s)))
    half = [scan[s] for s in (-0.5, 0.5) if s in scan]
    return {
        "best_shift_seconds": best,
        "fit_rms_watts_at_best": round(scan[best], 2),
        "fit_rms_watts_at_zero": round(scan[0.0], 2),
        "fit_rms_watts_half_a_sample_off": round(min(half), 2) if half else None,
    }


def phase_rates(placed, gens, idle_watts, turns) -> dict:
    """Joules per prefilled and per decoded token: each phase's fitted watts above idle × its
    seconds, over its tokens. The prorated split rides beside it as a cross-check."""
    models = {g.model for g in gens}
    if len(models) != 1:
        raise SystemExit(f"a rate is for one model; this run's generations name {sorted(models) or 'none'}")
    (pre_w, dec_w, other_w), rms, touched = _fit_phase_watts(placed, gens, idle_watts, turns)
    ptok, dtok = sum(g.prompt_tokens for g in gens), sum(g.decode_tokens for g in gens)
    psec, dsec = sum(g.prefill_s for g in gens), sum(g.decode_s for g in gens)
    pj, dj = pre_w * psec, dec_w * dsec
    if touched <= 0 or pre_w <= 0 or dec_w <= 0 or (pj + dj) / touched < 0.5:
        raise SystemExit("the generations hold almost none of the turns' energy: a wrong ttft log, or a clock "
                         "an hour out (a time-zone change between the run and `log show`)?")
    outside = sum(1 for g in gens if not any(a <= g.end <= b for a, b in turns))
    opj = sum(energy_above(placed, *_phases(g, 0.0)[:2], idle_watts) for g in gens)
    odj = sum(energy_above(placed, *_phases(g, 0.0)[1:], idle_watts) for g in gens)
    return {
        "model": models.pop(),
        "estimator": "least-squares phase watts over the samples that touch a turn",
        "generations": len(gens),
        "prefill_tokens": ptok, "decode_tokens": dtok,
        "prefill_seconds": round(psec, 3), "decode_seconds": round(dsec, 3),
        "prefill_watts_above_idle": round(pre_w, 2),
        "decode_watts_above_idle": round(dec_w, 2),
        "rest_of_turn_watts_above_idle": round(other_w, 2),
        "fit_rms_watts": round(rms, 2),
        "prefill_joules": round(pj, 2), "decode_joules": round(dj, 2),
        "joules_per_prefill_token": round(pj / ptok, 4) if ptok else None,
        "joules_per_decode_token": round(dj / dtok, 4) if dtok else None,
        "generation_share_of_turn_energy": round((pj + dj) / touched, 3),
        "generations_ending_outside_a_turn": outside,
        "cross_check_prorated": {
            "joules_per_prefill_token": round(opj / ptok, 4) if ptok else None,
            "joules_per_decode_token": round(odj / dtok, 4) if dtok else None,
        },
        "rows": [
            {"prompt_tokens": g.prompt_tokens, "prefill_s": round(g.prefill_s, 3),
             "decode_tokens": g.decode_tokens, "decode_s": round(g.decode_s, 3)}
            for g in gens
        ],
    }


def rates(log: Path, turns_path: Path, ttft: Path, out: Path | None, provenance: dict) -> dict:
    doc = json.loads(turns_path.read_text())
    samples = parse_powermetrics(read_text(log))
    placed = place(samples)
    i0, i1 = datetime.fromisoformat(doc["idle_window"]["start"]), datetime.fromisoformat(doc["idle_window"]["end"])
    idle = idle_watts(placed, i0, i1)
    turns = [(datetime.fromisoformat(t["start"]), datetime.fromisoformat(t["end"])) for t in doc["turns"]]
    gens = parse_ttft(ttft.read_text(), i0.tzinfo)
    r = {
        "provenance": {"brain": doc.get("brain"), "log": log.name, "ttft": ttft.name, **provenance},
        "idle_watts": round(idle, 2),
        "placement_slack_seconds": round(placement_slack(samples), 3),
        "placement_runs": len(_segments(samples)),
        **phase_rates(placed, gens, idle, turns),
        "alignment": alignment_check(placed, gens, idle, turns),
    }
    if out:
        out.write_text(json.dumps(r, indent=2, ensure_ascii=False) + "\n")
    print(f"{r['model']}: {r['joules_per_prefill_token']} J per prefilled token ({r['prefill_watts_above_idle']} W), "
          f"{r['joules_per_decode_token']} J per decoded token ({r['decode_watts_above_idle']} W) · "
          f"{r['generations']} generations hold {r['generation_share_of_turn_energy']:.0%} of the turns' energy · "
          f"placed within {r['placement_slack_seconds']:.3f} s, best clock shift {r['alignment']['best_shift_seconds']:+.2f} s")
    if abs(r["alignment"]["best_shift_seconds"]) > 0.1:
        print("  ⚠ the ttft clock and the placed samples disagree by more than 0.1 s: the split is suspect", file=sys.stderr)
    if r["generations"] != len(turns) or r["generations_ending_outside_a_turn"]:
        print(f"  ⚠ {r['generations']} generations for {len(turns)} turns, {r['generations_ending_outside_a_turn']} "
              "ending outside every turn: something else generated during the run", file=sys.stderr)
    return r


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
    samples = parse_powermetrics(read_text(log))
    placed = place(samples)
    i0, i1 = datetime.fromisoformat(doc["idle_window"]["start"]), datetime.fromisoformat(doc["idle_window"]["end"])
    turns = [Turn.from_json(t) for t in doc["turns"]]
    prov = {"brain": doc.get("brain"), "samples": len(samples), "log": log.name, **provenance}
    r = receipt(turns, placed, idle_watts(placed, i0, i1), prov)     # bill against the unrounded median
    r["summary"].update(idle_stats(placed, i0, i1))                   # round for display only
    r["summary"]["placement_slack_seconds"] = round(placement_slack(samples), 3)
    r["summary"]["placement_runs"] = len(_segments(samples))
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
    t = sub.add_parser("rates", help="split each generation into prefill and decode: joules per token")
    t.add_argument("--log", type=Path, required=True)
    t.add_argument("--turns", type=Path, required=True)
    t.add_argument("--ttft", type=Path, required=True, help="log show --style compact of category ttft over the run")
    t.add_argument("--out", type=Path)
    t.add_argument("--provenance", default="{}")
    args = ap.parse_args(argv)
    if args.cmd == "rates":
        rates(args.log, args.turns, args.ttft, args.out, json.loads(args.provenance))
        return 0
    if args.cmd == "drive":
        qs = [q.strip() for q in args.questions.read_text().splitlines() if q.strip()] if args.questions else DEFAULT_QUESTIONS
        drive(qs, args.out, args.brain, args.idle_seconds, args.m1k3)
        return 0
    report(args.log, args.turns, args.out, json.loads(args.provenance))
    return 0


if __name__ == "__main__":
    sys.exit(main())
