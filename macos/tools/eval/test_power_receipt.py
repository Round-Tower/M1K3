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


def test_parse_reads_one_combined_watts_per_sample_with_its_timestamp_and_elapsed():
    samples = pr.parse_powermetrics(LOG)
    assert len(samples) == 5
    assert samples[0].at == datetime(2026, 9, 15, 21, 0, 0, tzinfo=TZ)
    assert samples[0].watts == 1.1
    assert samples[2].watts == 30.0
    assert samples[2].cpu_watts == 9.0 and samples[2].gpu_watts == 21.0
    # the header's own "(500.12ms elapsed)" is the sample's duration — timestamps are
    # whole seconds, so two -i 500 samples share one; the header is the only truth
    assert samples[0].elapsed_s == 0.50012


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


def test_idle_stats_make_the_was_it_quiet_call_machine_checkable():
    samples = pr.parse_powermetrics(LOG)
    stats = pr.idle_stats(samples, start=datetime(2026, 9, 15, 21, 0, 0, tzinfo=TZ), end=datetime(2026, 9, 15, 21, 0, 3, tzinfo=TZ))
    assert stats == {"idle_watts": 1.1, "idle_min_watts": 1.1, "idle_max_watts": 30.0, "idle_samples": 3}


def test_receipt_charges_only_the_energy_above_idle_inside_the_turn():
    samples = pr.parse_powermetrics(LOG)
    turn = pr.Turn(
        question="q", answer="a" * 200,
        start=datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), end=datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ),
    )
    r = pr.receipt([turn], samples, idle_watts=1.1)
    (t,) = r["turns"]
    # two samples at 30.0 W, each 0.50012 s long by its own header, above an idle of 1.1 W
    # → 2 × 28.9 × 0.50012 = 28.907 J = 0.00803 Wh; the 21:00:04 sample is outside [start, end)
    assert t["seconds"] == 2.0
    assert round(t["joules_above_idle"], 2) == 28.91
    assert round(t["wh_above_idle"], 5) == 0.00803
    assert round(t["mean_watts"], 1) == 30.0
    # package power is the billing figure; the CPU / GPU split rides beside it so prose
    # about "the GPU did the work" is backed by a field (review catch on #357)
    assert t["mean_cpu_watts"] == 9.0 and t["mean_gpu_watts"] == 21.0
    assert t["answer_chars"] == 200
    assert r["summary"]["idle_watts"] == 1.1
    assert r["summary"]["sample_interval_seconds"] == 0.50012
    assert round(r["summary"]["median_wh_per_answer"], 5) == 0.00803
    assert r["summary"]["median_mean_watts"] == 30.0
    assert r["summary"]["median_mean_gpu_watts"] == 21.0 and r["summary"]["median_mean_cpu_watts"] == 9.0


def test_receipt_summary_takes_the_median_across_turns_and_names_the_power_source():
    samples = pr.parse_powermetrics(LOG)
    a = pr.Turn("q1", "x", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 3, tzinfo=TZ))
    b = pr.Turn("q2", "y", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ))
    r = pr.receipt([a, b], samples, idle_watts=1.1, provenance={"brain": "lil", "power_source": "ac"})
    assert r["summary"]["turns"] == 2
    assert round(r["summary"]["median_wh_per_answer"], 5) == round((0.00401 + 0.00803) / 2, 5)
    assert r["provenance"]["brain"] == "lil" and r["provenance"]["power_source"] == "ac"
    json.dumps(r)  # serialisable as written


def test_report_bills_against_the_unrounded_idle_median(tmp_path):
    # idle samples at 1.1044 / 1.1056 W → median 1.105; the display rounds to 1.1, the billing must not
    log = (_sample("Tue Sep 15 21:00:00 2026 +0100", 1000, 104, 1104)
           + _sample("Tue Sep 15 21:00:01 2026 +0100", 1000, 106, 1106)
           + _sample("Tue Sep 15 21:00:02 2026 +0100", 9000, 21000, 30000))
    (tmp_path / "p.log").write_text(log)
    turn = pr.Turn("q", "a", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 3, tzinfo=TZ))
    (tmp_path / "t.json").write_text(json.dumps({"brain": "lil", "idle_window": {"start": "2026-09-15T21:00:00+01:00", "end": "2026-09-15T21:00:02+01:00"}, "turns": [turn.to_json()]}))
    r = pr.report(tmp_path / "p.log", tmp_path / "t.json", None, {})
    assert r["summary"]["idle_watts"] == 1.1                       # display
    assert r["turns"][0]["joules_above_idle"] == round((30.0 - 1.105) * 0.50012, 2)   # billing at full precision


def test_turn_json_round_trips():
    t = pr.Turn("q", "a", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ))
    assert pr.Turn.from_json(json.loads(json.dumps(t.to_json()))) == t
