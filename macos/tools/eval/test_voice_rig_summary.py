"""Pins voice_rig_summary: one row per voice turn, read from the rig's app.log.

The fixture lines are verbatim from the 2026-10-16 rig run on master e632482d (prefixes trimmed).
"""

from __future__ import annotations

import voice_rig_summary as vrs

LOG = """\
19:21:47.478 Df M1K3[1:1] [app.m1k3:stt] voice endpoint: complete thought · idle 2.6s · required 2.5s
19:21:47.826 Df M1K3[1:2] [app.m1k3:responder] tool router: tools p=0.713
19:21:49.743 Df M1K3[1:3] [app.m1k3:responder] tool dispatch: none — a plain turn answers
19:22:06.960 Df M1K3[1:4] [app.m1k3:ttft] stream [mlx-community/gemma-4-12B-it-4bit]: prompt=2139tok prefill=11362ms decode=156tok @26tok/s
19:22:20.590 Df M1K3[1:1] [app.m1k3:stt] voice turn: first sentence 18712ms · synth 906ms · first audio 19618ms · answer 33112ms · 5 sentences
19:22:51.842 Df M1K3[1:1] [app.m1k3:stt] voice endpoint: complete thought · idle 2.8s · required 2.5s
19:22:52.199 Df M1K3[1:2] [app.m1k3:responder] tool router: chat p=0.037
19:23:10.521 Df M1K3[1:4] [app.m1k3:ttft] stream [mlx-community/gemma-4-12B-it-4bit]: prompt=1863tok prefill=9847ms decode=238tok @28tok/s
19:23:31.900 Df M1K3[1:1] [app.m1k3:stt] voice turn: first sentence 14310ms · synth 1080ms · first audio 15390ms · answer 40057ms · 10 sentences
19:24:51.631 Df M1K3[1:1] [app.m1k3:stt] voice endpoint: complete thought · idle 2.7s · required 2.5s
19:24:51.801 Df M1K3[1:1] [app.m1k3:stt] name repair: <private> → <private> (0.80)
19:24:52.064 Df M1K3[1:2] [app.m1k3:responder] tool router: tools p=0.900
19:24:54.864 Df M1K3[1:3] [app.m1k3:responder] tool dispatch: fetch_page ran, 1500 chars
19:25:00.000 Df M1K3[1:4] [app.m1k3:ttft] stream: persona seed (1809tok) is not a prefix of the 3000tok render — full prefill; diverges at 12: seed […] render […]
19:25:09.701 Df M1K3[1:4] [app.m1k3:ttft] stream [mlx-community/gemma-4-12B-it-4bit]: prompt=1903tok prefill=9811ms decode=140tok @28tok/s
19:25:22.542 Df M1K3[1:1] [app.m1k3:stt] voice turn: first sentence 2845ms · synth 197ms · first audio 3042ms · answer 30910ms · 5 sentences
"""


def test_one_row_per_voice_turn_with_route_prompt_and_first_audio():
    rows = vrs.turns(LOG.splitlines())
    assert [r.route for r in rows] == ["plain (tools verdict)", "plain (chat)", "fetch_page"]
    assert [r.prompt_tokens for r in rows] == [2139, 1863, 1903]
    assert [r.prefill_ms for r in rows] == [11362, 9847, 9811]
    assert [r.first_audio_ms for r in rows] == [19618, 15390, 3042]


def test_flags_name_repair_and_a_seed_divergence():
    rows = vrs.turns(LOG.splitlines())
    assert rows[0].notes == []
    assert rows[2].notes == ["name repair 0.80", "seed diverged"]


def test_a_turn_without_its_summary_line_is_not_reported():
    rows = vrs.turns(LOG.splitlines()[:4])
    assert rows == []


def test_table_has_a_header_and_a_row_per_turn():
    table = vrs.table(vrs.turns(LOG.splitlines()))
    lines = table.splitlines()
    assert lines[0].split()[:2] == ["#", "route"]
    assert len(lines) == 2 + 3  # header, rule, three turns
    assert "19.6 s" in lines[2]
