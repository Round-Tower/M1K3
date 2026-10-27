"""Pins for power_receipt.py — the powermetrics parse and the receipt maths.

The claim on the brains page is only as honest as these two functions, so
they are pinned on hand-built samples with known answers.
"""
import json
from datetime import datetime, timedelta, timezone
from itertools import pairwise

import power_receipt as pr
import pytest

TZ = timezone(timedelta(hours=1))


def _sample(ts: str, cpu: int, gpu: int, combined: int | None = None, ane: int = 0, elapsed_ms: float = 500.12,
            summary_gpu: int | None = None) -> str:
    """One powermetrics block in the shape `--samplers cpu_power,gpu_power` prints. `summary_gpu` is the
    processor summary's copy of the GPU figure, which can glitch away from the GPU section's own."""
    lines = [f"*** Sampled system activity ({ts}) ({elapsed_ms:.2f}ms elapsed) ***", "", "**** Processor usage ****", ""]
    lines += [f"CPU Power: {cpu} mW", f"GPU Power: {gpu if summary_gpu is None else summary_gpu} mW", f"ANE Power: {ane} mW"]
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


def test_parse_takes_the_gpu_sections_line_over_the_summarys_glitch():
    # powermetrics' processor summary sometimes reads ~0 W for one sample and ~double the next;
    # the GPU section's own line holds steady, and the Combined line is built from the summary's
    glitched = _sample("Tue Sep 15 21:00:00 2026 +0100", 1000, 32000, combined=1500, summary_gpu=500)
    (s,) = pr.parse_powermetrics(glitched)
    assert s.gpu_watts == 32.0
    assert s.watts == 33.0


def test_parse_ignores_a_truncated_trailing_block():
    log = LOG + "*** Sampled system activity (Tue Sep 15 21:00:05 2026 +0100) (500.00ms elapsed) ***\nCPU Power: 12"
    assert len(pr.parse_powermetrics(log)) == 5


def test_idle_baseline_is_the_median_of_the_idle_window():
    placed = _laid([1.1, 1.1, 30.0, 30.0, 1.1])
    assert pr.idle_watts(placed, start=T0, end=T0 + timedelta(seconds=1)) == 1.1


def test_idle_stats_make_the_was_it_quiet_call_machine_checkable():
    placed = _laid([1.1, 1.1, 30.0, 30.0, 1.1])
    stats = pr.idle_stats(placed, start=T0, end=T0 + timedelta(seconds=1.5))
    assert stats == {"idle_watts": 1.1, "idle_min_watts": 1.1, "idle_max_watts": 30.0, "idle_samples": 3,
                     "idle_cpu_watts": 0.0, "idle_gpu_watts": 1.1, "idle_ane_watts": 0.0}


def test_idle_window_takes_only_samples_wholly_inside_it():
    # the first answer's prefill sample straddles the idle window's end: it is not idle
    placed = _laid([1.0, 1.0, 1.0, 40.0])
    stats = pr.idle_stats(placed, start=T0, end=T0 + timedelta(seconds=1.75))
    assert stats["idle_max_watts"] == 1.0 and stats["idle_samples"] == 3


def test_receipt_charges_only_the_energy_above_idle_inside_the_turn():
    placed = _laid([1.1, 1.1, 30.0, 30.0, 1.1])
    turn = pr.Turn(question="q", answer="a" * 200, start=T0 + timedelta(seconds=1), end=T0 + timedelta(seconds=2))
    r = pr.receipt([turn], placed, idle_watts=1.1)
    (t,) = r["turns"]
    # two 0.5 s samples at 30.0 W above an idle of 1.1 W → 2 × 28.9 × 0.5 = 28.9 J = 0.00803 Wh
    assert t["seconds"] == 1.0
    assert t["samples"] == 2
    assert round(t["joules_above_idle"], 2) == 28.9
    assert round(t["wh_above_idle"], 5) == 0.00803
    assert round(t["mean_watts"], 1) == 30.0
    # package power is the billing figure; the CPU / GPU split rides beside it so prose
    # about "the GPU did the work" is backed by a field (review catch on #357)
    assert t["mean_cpu_watts"] == 0.0 and t["mean_gpu_watts"] == 30.0
    assert t["answer_chars"] == 200
    assert r["summary"]["idle_watts"] == 1.1
    assert r["summary"]["sample_interval_seconds"] == 0.5
    assert round(r["summary"]["median_wh_per_answer"], 5) == 0.00803


def test_receipt_counts_the_part_of_a_sample_the_turn_holds_and_lets_a_quiet_one_go_negative():
    placed = _laid([1.1, 1.1, 30.0, 30.0, 0.5])
    # a quarter-second into the first 30 W sample, to a quarter-second into the 0.5 W one
    turn = pr.Turn("q", "a", T0 + timedelta(seconds=1.25), T0 + timedelta(seconds=2.25))
    (t,) = pr.receipt([turn], placed, idle_watts=1.1)["turns"]
    assert abs(t["joules_above_idle"] - (28.9 * 0.75 + (0.5 - 1.1) * 0.25)) < 0.006   # the receipt rounds to 0.01 J
    assert t["samples"] == 3
    assert abs(t["mean_watts"] - (30.0 * 0.75 + 0.5 * 0.25)) < 0.006   # weighted by the part held


def test_receipt_summary_takes_the_median_across_turns_and_names_the_power_source():
    placed = _laid([1.1, 1.1, 30.0, 30.0, 1.1])
    a = pr.Turn("q1", "x", T0 + timedelta(seconds=1), T0 + timedelta(seconds=1.5))
    b = pr.Turn("q2", "y", T0 + timedelta(seconds=1), T0 + timedelta(seconds=2))
    r = pr.receipt([a, b], placed, idle_watts=1.1, provenance={"brain": "lil", "power_source": "ac"})
    assert r["summary"]["turns"] == 2
    assert round(r["summary"]["median_wh_per_answer"], 5) == round((0.00401 + 0.00803) / 2, 5)
    assert r["provenance"]["brain"] == "lil" and r["provenance"]["power_source"] == "ac"
    json.dumps(r)  # serialisable as written


def test_report_bills_against_the_unrounded_idle_median(tmp_path):
    # idle at 1.104 W: the display rounds to 1.1, the billing must not
    true_start = T0 + timedelta(milliseconds=200)
    (tmp_path / "p.log").write_text(_log_from(true_start, [1.104] * 20 + [30.0] * 4 + [1.1] * 4))
    # a short synthetic log places to ±0.1 s, so the turn takes the burst with idle margin on both sides
    turn = pr.Turn("q", "a", true_start + timedelta(seconds=20 * 0.51 - 0.3), true_start + timedelta(seconds=24 * 0.51 + 0.3))
    (tmp_path / "t.json").write_text(json.dumps({"brain": "lil", "idle_window": {
        "start": true_start.isoformat(), "end": (true_start + timedelta(seconds=19 * 0.51)).isoformat()}, "turns": [turn.to_json()]}))
    r = pr.report(tmp_path / "p.log", tmp_path / "t.json", None, {})
    assert r["summary"]["idle_watts"] == 1.1                       # display
    assert abs(r["turns"][0]["joules_above_idle"] - (30.0 - 1.104) * 4 * 0.51) < 0.006   # billing at full precision
    assert r["summary"]["placement_slack_seconds"] < 0.5


def test_report_reads_a_gzipped_log_and_a_windows_file_with_no_answer_text(tmp_path):
    # docs/evals keeps the raw logs gzipped and the turns as windows: lengths, never answer text
    import gzip
    true_start = T0 + timedelta(milliseconds=200)
    (tmp_path / "p.log.gz").write_bytes(gzip.compress(_log_from(true_start, [1.104] * 20 + [30.0] * 4 + [1.1] * 4).encode()))
    window = {"question": "q", "answer_chars": 321,
              "start": (true_start + timedelta(seconds=20 * 0.51 - 0.3)).isoformat(),
              "end": (true_start + timedelta(seconds=24 * 0.51 + 0.3)).isoformat()}
    (tmp_path / "w.json").write_text(json.dumps({"brain": "lil", "idle_window": {
        "start": true_start.isoformat(), "end": (true_start + timedelta(seconds=19 * 0.51)).isoformat()}, "turns": [window]}))
    (t,) = pr.report(tmp_path / "p.log.gz", tmp_path / "w.json", None, {})["turns"]
    assert t["answer_chars"] == 321
    assert abs(t["joules_above_idle"] - (30.0 - 1.104) * 4 * 0.51) < 0.006


def test_turn_json_round_trips():
    t = pr.Turn("q", "a", datetime(2026, 9, 15, 21, 0, 2, tzinfo=TZ), datetime(2026, 9, 15, 21, 0, 4, tzinfo=TZ))
    assert pr.Turn.from_json(json.loads(json.dumps(t.to_json()))) == t


# ---------------------------------------------------------------------- rates (#696)
# A receipt bills whole turns. A per-token rate needs each generation split into its prefill and
# its decode, which the app's ttft line times. The samples are stamped to the whole second, so the
# split first has to place each 500 ms sample on the clock.

T0 = datetime(2026, 10, 27, 18, 0, 0, tzinfo=TZ)


def _laid(watts: list[float], start: datetime = T0, dt: float = 0.5) -> list:
    """Samples laid end to end from `start`, `dt` seconds each: what `place` yields."""
    return [
        pr.Placed(pr.Sample(start, w, 0.0, w, dt), start + timedelta(seconds=i * dt), start + timedelta(seconds=(i + 1) * dt))
        for i, w in enumerate(watts)
    ]


def _stamp(t: datetime) -> str:
    return t.strftime("%a %b %d %H:%M:%S %Y %z")


def _log_from(true_start: datetime, watts: list[float], elapsed_ms: float = 510.0) -> str:
    """A powermetrics log as the tool writes it: each block stamped with the whole second its sample ENDED in."""
    out, cum = "", 0.0
    for w in watts:
        cum += elapsed_ms / 1000
        mw = round(w * 1000)
        out += _sample(_stamp(true_start + timedelta(seconds=cum)), 0, mw, mw, elapsed_ms=elapsed_ms)
    return out


def test_place_recovers_sub_second_windows_from_whole_second_stamps():
    true_start = T0 + timedelta(milliseconds=300)
    placed = pr.place(pr.parse_powermetrics(_log_from(true_start, [1.0] * 60)))
    assert abs((placed[0].start - true_start).total_seconds()) < 0.02
    assert all(a.end == b.start for a, b in pairwise(placed))
    assert abs((placed[-1].end - placed[0].start).total_seconds() - 60 * 0.51) < 1e-6
    assert pr.placement_slack(pr.parse_powermetrics(_log_from(true_start, [1.0] * 60))) < 0.03


def test_a_slipped_loop_opens_a_new_run_and_leaves_the_gap_unsampled():
    second = T0 + timedelta(seconds=20)   # the first run ends at 30 × 0.517 = 15.5 s: a 4.5 s hole no header covers
    log = _log_from(T0, [1.0] * 30, elapsed_ms=517) + _log_from(second, [1.0] * 30, elapsed_ms=517)
    samples = pr.parse_powermetrics(log)
    placed = pr.place(samples)
    assert len(pr._segments(samples)) == 2
    assert abs((placed[0].start - T0).total_seconds()) < 0.05
    assert abs((placed[30].start - second).total_seconds()) < 0.05
    assert (placed[30].start - placed[29].end).total_seconds() > 4


def test_energy_above_idle_prorates_a_sample_the_window_cuts():
    placed = _laid([10.0, 10.0])
    assert pr.energy_above(placed, T0 + timedelta(seconds=0.25), T0 + timedelta(seconds=0.75), idle_watts=2.0) == 8.0 * 0.5
    assert pr.energy_above(placed, T0 + timedelta(seconds=5), T0 + timedelta(seconds=6), idle_watts=2.0) == 0.0


TTFT = """Timestamp               Ty Process[PID:TID]
2026-10-27 18:12:36.580 Df M1K3[15900:66ab26] [app.m1k3:ttft] stream [mlx-community/Qwen3.5-4B-MLX-4bit]: prompt=785tok prefill=1235ms decode=43tok @83tok/s
2026-10-27 18:12:40.000 Df M1K3[15900:66ab26] [app.m1k3:mlx-load] loaded something
2026-10-27 18:12:43.149 Df M1K3[15900:66ab25] [app.m1k3:ttft] generate [mlx-community/Qwen3.5-4B-MLX-4bit]: prompt=12tok prefill=40ms decode=0tok @0tok/s
"""


def test_parse_ttft_reads_each_generation_and_its_phase_durations():
    a, b = pr.parse_ttft(TTFT, TZ)
    assert a.end == datetime(2026, 10, 27, 18, 12, 36, 580_000, tzinfo=TZ)
    assert a.model == "mlx-community/Qwen3.5-4B-MLX-4bit"
    assert (a.prompt_tokens, a.prefill_s, a.decode_tokens) == (785, 1.235, 43)
    assert abs(a.decode_s - 43 / 83.5) < 1e-12      # tok/s is printed truncated: [83, 84) → 83.5
    assert (b.decode_tokens, b.decode_s) == (0, 0.0)  # a 0 tok/s line has no decode window


def _one_generation(end_offset: float = 4.0) -> tuple[list, list, list]:
    # idle 1 W for 1 s, prefill at 41 W for 1 s (400 tokens), decode at 31 W for 2 s (100 tokens @ 50 tok/s)
    placed = _laid([1.0, 1.0, 41.0, 41.0, 31.0, 31.0, 31.0, 31.0, 1.0, 1.0])
    gen = pr.Generation(T0 + timedelta(seconds=end_offset), "m", 400, 1.0, 100, 2.0)
    turn = (T0 + timedelta(seconds=0.5), T0 + timedelta(seconds=4.5))
    return placed, [gen], [turn]


def test_phase_rates_split_a_generation_into_prefill_and_decode_joules_per_token():
    placed, gens, turns = _one_generation()
    r = pr.phase_rates(placed, gens, idle_watts=1.0, turns=turns)
    assert r["model"] == "m"
    assert (r["prefill_tokens"], r["decode_tokens"]) == (400, 100)
    assert r["prefill_joules"] == 40.0 and r["decode_joules"] == 60.0
    assert r["joules_per_prefill_token"] == 0.1 and r["joules_per_decode_token"] == 0.6
    assert r["prefill_watts_above_idle"] == 40.0 and r["decode_watts_above_idle"] == 30.0
    assert r["rest_of_turn_watts_above_idle"] == 0.0 and r["fit_rms_watts"] == 0.0
    assert r["generation_share_of_turn_energy"] == 1.0
    assert r["cross_check_prorated"] == {"joules_per_prefill_token": 0.1, "joules_per_decode_token": 0.6}
    (row,) = r["rows"]
    assert set(row) == {"prompt_tokens", "prefill_s", "decode_tokens", "decode_s"}   # numbers only


def test_the_fit_recovers_phase_watts_when_a_generation_starts_mid_sample():
    # true power: idle 1 W, prefill 41 W over [1.25, 2.25) s, decode 31 W over [2.25, 4.25) s, idle after.
    # Each 0.5 s sample reads its own average, so the samples at 1.0–1.5 and 4.0–4.5 s straddle an edge.
    def true_watts(t: float) -> float:
        return 41.0 if 1.25 <= t < 2.25 else 31.0 if 2.25 <= t < 4.25 else 1.0
    averaged = [sum(true_watts(i * 0.5 + k / 1000) for k in range(500)) / 500 for i in range(10)]
    placed = _laid(averaged)
    gen = pr.Generation(T0 + timedelta(seconds=4.25), "m", 400, 1.0, 100, 2.0)
    turn = (T0 + timedelta(seconds=0.5), T0 + timedelta(seconds=4.75))
    r = pr.phase_rates(placed, [gen], 1.0, [turn])
    assert abs(r["prefill_watts_above_idle"] - 40.0) < 0.05 and abs(r["decode_watts_above_idle"] - 30.0) < 0.05
    assert abs(r["joules_per_prefill_token"] - 0.1) < 0.0005 and abs(r["joules_per_decode_token"] - 0.6) < 0.001
    assert r["generation_share_of_turn_energy"] > 0.995
    # prorating alone gives each straddling sample its average across the edge, and leaks energy out
    assert r["cross_check_prorated"]["joules_per_prefill_token"] < 0.095
    assert r["cross_check_prorated"]["joules_per_decode_token"] < 0.59


def test_alignment_check_finds_a_log_clock_that_runs_late():
    placed, gens, turns = _one_generation()
    a = pr.alignment_check(placed, gens, 1.0, turns)
    assert a["best_shift_seconds"] == 0.0 and a["fit_rms_watts_at_best"] == 0.0
    assert a["fit_rms_watts_half_a_sample_off"] > 5
    placed, late, turns = _one_generation(end_offset=4.5)   # the ttft line stamped 0.5 s after decode really ended
    assert pr.alignment_check(placed, late, 1.0, turns)["best_shift_seconds"] == -0.5


def test_a_run_whose_generations_hold_no_energy_is_refused_not_passed():
    # a wrong ttft log (or a clock an hour out) puts the generations where nothing happened
    _, gens, turns = _one_generation()
    flat = _laid([1.0] * 10)
    with pytest.raises(SystemExit, match="almost none"):
        pr.phase_rates(flat, gens, 1.0, turns)


def test_phase_rates_refuse_a_run_that_mixed_models():
    placed, gens, turns = _one_generation()
    other = pr.Generation(gens[0].end, "other", 10, 0.1, 1, 0.1)
    with pytest.raises(SystemExit, match="one model"):
        pr.phase_rates(placed, gens + [other], 1.0, turns)


def test_rates_end_to_end_from_the_three_files(tmp_path):
    # 30 s idle at 1 W, then one generation: prefill 40 W above idle for ~1 s, decode 30 W above for ~2 s
    true_start = T0 + timedelta(milliseconds=130)
    watts = [1.0] * 62 + [41.0] * 2 + [31.0] * 4 + [1.0] * 10
    (tmp_path / "p.log").write_text(_log_from(true_start, watts))
    gen_start = true_start + timedelta(seconds=62 * 0.51)
    pre_s, dec_s = 2 * 0.51, 4 * 0.51
    end = gen_start + timedelta(seconds=pre_s + dec_s)
    (tmp_path / "t.json").write_text(json.dumps({
        "brain": "lil",
        "idle_window": {"start": (true_start + timedelta(seconds=1)).isoformat(), "end": (true_start + timedelta(seconds=30)).isoformat()},
        "turns": [{"question": "q", "answer": "a", "start": (gen_start - timedelta(seconds=0.5)).isoformat(), "end": (end + timedelta(seconds=0.5)).isoformat()}],
    }))
    (tmp_path / "ttft.log").write_text(
        f"{end.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]} Df M1K3[1:2] [app.m1k3:ttft] stream [m]: "
        f"prompt=400tok prefill={round(pre_s * 1000)}ms decode=102tok @50tok/s\n"
    )
    r = pr.rates(tmp_path / "p.log", tmp_path / "t.json", tmp_path / "ttft.log", tmp_path / "r.json", {"power_source": "ac"})
    assert json.loads((tmp_path / "r.json").read_text()) == r
    assert r["provenance"]["brain"] == "lil" and r["provenance"]["power_source"] == "ac"
    assert r["idle_watts"] == 1.0 and r["generations"] == 1
    assert abs(r["joules_per_prefill_token"] - 40 * pre_s / 400) < 0.005
    assert abs(r["joules_per_decode_token"] - 30 * dec_s / 102) < 0.02
    assert abs(r["alignment"]["best_shift_seconds"]) <= 0.05
    assert r["generations_ending_outside_a_turn"] == 0
    assert "q" not in json.dumps(r["rows"]) and "answer" not in json.dumps(r)   # numbers only, no text
