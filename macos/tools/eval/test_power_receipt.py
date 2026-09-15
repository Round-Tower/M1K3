"""Pins for power_receipt.py — the powermetrics parse and the receipt maths.

The claim on the brains page is only as honest as these two functions, so
they are pinned on hand-built samples with known answers.
"""
import json
from datetime import datetime, timedelta, timezone

import power_receipt as pr

TZ = timezone(timedelta(hours=1))


def _sample(ts: str, cpu: int, gpu: int, combined: int | None = None, ane: int = 0) -> str:
    """One powermetrics block in the shape `--samplers cpu_power,gpu_power` prints."""
    lines = [f"*** Sampled system activity ({ts}) (500.12ms elapsed) ***", "", "**** Processor usage ****", ""]
    lines += [f"CPU Power: {cpu} mW", f"GPU Power: {gpu} mW", f"ANE Power: {ane} mW"]
    if combined is not None:
        lines.append(f"Combined Power (CPU + GPU + ANE): {combined} mW")
    lines += ["", "**** GPU usage ****", "", f"GPU Power: {gpu} mW", ""]
    return "\n".join(lines) + "\n"


LOG = (
    _sample("Tue Sep 15 21:00:00 2026 +0100", 1000, 100, 1100)
    + _sample("Tue Sep 15 21:00:01 2026 +0100", 1000, 100, 1100)
    + _sample("Tue Sep 15 21:00:02 2026 +0100", 9000, 21000, 30000)
    + _sample("Tue Sep 15 21:00:03 2026 +0100", 9000, 21000, 30000)
    + _sample("Tue Sep 15 21:00:04 2026 +0100", 1000, 100, 1100)
)


def test_parse_reads_one_combined_watts_per_sample_with_its_timestamp():
    samples = pr.parse_powermetrics(LOG)
    assert len(samples) == 5
    assert samples[0].at == datetime(2026, 9, 15, 21, 0, 0, tzinfo=TZ)
    assert samples[0].watts == 1.1
    assert samples[2].watts == 30.0
    assert samples[2].cpu_watts == 9.0 and samples[2].gpu_watts == 21.0


def test_parse_falls_back_to_cpu_plus_gpu_when_no_combined_line():
    log = _sample("Tue Sep 15 21:00:00 2026 +0100", 1500, 2500)   # no Combined line
    (s,) = pr.parse_powermetrics(log)
    assert s.watts == 4.0


def test_parse_ignores_a_truncated_trailing_block():
    log = LOG + "*** Sampled system activity (Tue Sep 15 21:00:05 2026 +0100) (500.00ms elapsed) ***\nCPU Power: 12"
    assert len(pr.parse_powermetrics(log)) == 5


def test_idle_baseline_is_the_median_of_the_idle_window():
    samples = pr.parse_powermetrics(LOG)
    idle = pr.idle_watts(samples, start=datetime(2026, 9, 15, 21, 0, 0, tzinfo=TZ), end=datetime(2026, 9, 15, 21, 0, 1, 30_000, tzinfo=TZ))
    assert idle == 1.1


def test_receipt_charges_only_the_energy_above_idle_inside_the_turn():
    samples = pr.parse_powermetrics(LOG)
    turn = pr.Turn(
        question="q", answer="a" * 200,
        start=datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), end=datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ),
    )
    r = pr.receipt([turn], samples, idle_watts=1.1)
    (t,) = r["turns"]
    # two 1-second samples at 30.0 W above an idle of 1.1 W → 57.8 J = 0.01606 Wh; the 21:00:04 sample is outside [start, end)
    assert t["seconds"] == 2.0
    assert round(t["joules_above_idle"], 1) == 57.8
    assert round(t["wh_above_idle"], 5) == 0.01606
    assert round(t["mean_watts"], 1) == 30.0
    assert t["answer_chars"] == 200
    assert r["summary"]["idle_watts"] == 1.1
    assert round(r["summary"]["median_wh_per_answer"], 5) == 0.01606


def test_receipt_summary_takes_the_median_across_turns_and_names_the_power_source():
    samples = pr.parse_powermetrics(LOG)
    a = pr.Turn("q1", "x", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 3, tzinfo=TZ))
    b = pr.Turn("q2", "y", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ))
    r = pr.receipt([a, b], samples, idle_watts=1.1, provenance={"brain": "lil", "power_source": "ac"})
    assert r["summary"]["turns"] == 2
    assert round(r["summary"]["median_wh_per_answer"], 5) == round((0.00803 + 0.01606) / 2, 5)
    assert r["provenance"]["brain"] == "lil" and r["provenance"]["power_source"] == "ac"
    json.dumps(r)  # serialisable as written


def test_turn_json_round_trips():
    t = pr.Turn("q", "a", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ))
    assert pr.Turn.from_json(json.loads(json.dumps(t.to_json()))) == t
