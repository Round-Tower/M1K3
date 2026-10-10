"""Pins router_arm_summary.py: eight ChatEval JSONs (lil/big x off/routing/head/chain: three
flags against `off`) become one table and one verdict per flag. The verdict rule is the part
that decides a default flip, so it is pinned hard: 'flip' iff accuracy is within one fixture of
`off` AND the median turn is faster.

Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 (the rule is the brief's; "within one
fixture" is read as a fixture-level majority count with a one-fixture tolerance). Prior: none (new file).
Review: same day, code-quality fold — the tool-chain-* fixtures are out of the verdict and in their own column.
Review: Kev + claude-opus-5-5, 2026-10-10 — route stages, the untested-head verdict, Mini's baseline.
"""

import json
from pathlib import Path

import pytest

import router_arm_summary as ras


def trial(fixture, kind, ms, ok=True, repeat=0):
    return {"fixtureID": fixture, "kind": kind, "latencyMS": ms, "repeatIndex": repeat,
            "checks": [{"name": "tool-called", "outcome": "pass" if ok else "fail"}]}


def write_cell(tmp_path, brain, config, trials, date="2026-10-10"):
    path = tmp_path / f"{date}-router-arm-{brain}-{config}-x3-ac.json"
    path.write_text(json.dumps({"runs": [{"brainID": brain, "scores": trials}], "provenance": {}}))
    return path


def fixtures(passing, ms, kind="tool-use", names=("a", "b", "c", "d")):
    """Each fixture x3 repeats; `passing` = fixtures that pass all repeats."""
    return [trial(n, kind, ms, ok=(n in passing), repeat=r) for n in names for r in range(3)]


def test_cell_name_parses_brain_and_config():
    assert ras.parse_cell_name(Path("2026-10-10-router-arm-lil-chain-x3-ac.json")) == ("lil", "chain")
    with pytest.raises(ValueError):
        ras.parse_cell_name(Path("2026-10-10-lil-remeasure-x3-ac.json"))


def test_only_tool_use_and_open_chat_count_and_na_is_out(tmp_path):
    na = {"fixtureID": "v", "kind": "tool-use", "latencyMS": 1, "checks": [{"name": "applicable", "outcome": "skip"}]}
    other = trial("x", "security", 1)
    path = write_cell(tmp_path, "lil", "off", [trial("a", "tool-use", 5), na, other])
    cell = ras.load_cell(path)
    assert [t.fixture for t in cell.trials] == ["a"]


def test_cell_stats_pass_rate_and_median_by_kind(tmp_path):
    trials = fixtures({"a", "b"}, 1000) + fixtures({"a", "b", "c", "d"}, 3000, kind="open-chat")
    cell = ras.load_cell(write_cell(tmp_path, "lil", "off", trials))
    assert cell.passed("tool-use") == (6, 12)
    assert cell.passed("open-chat") == (12, 12)
    assert cell.median_ms("tool-use") == 1000
    assert cell.median_ms() == 2000.0  # 12 x 1000 and 12 x 3000


def test_fixture_accuracy_is_a_majority_of_repeats(tmp_path):
    trials = [trial("a", "tool-use", 1, ok=True, repeat=0), trial("a", "tool-use", 1, ok=True, repeat=1),
              trial("a", "tool-use", 1, ok=False, repeat=2),
              trial("b", "tool-use", 1, ok=False, repeat=0), trial("b", "tool-use", 1, ok=True, repeat=1),
              trial("b", "tool-use", 1, ok=False, repeat=2)]
    cell = ras.load_cell(write_cell(tmp_path, "lil", "off", trials))
    assert cell.fixtures_passed("tool-use") == (1, 2)


def cells(tmp_path, off, other):
    return (ras.load_cell(write_cell(tmp_path, "lil", "off", off)),
            ras.load_cell(write_cell(tmp_path, "lil", "routing", other)))


def test_flip_when_as_accurate_and_faster(tmp_path):
    off, routing = cells(tmp_path, fixtures({"a", "b", "c"}, 5900), fixtures({"a", "b", "c"}, 3000))
    assert ras.verdict(off, routing) == "flip"


def test_flip_tolerates_one_fixture_of_accuracy(tmp_path):
    off, routing = cells(tmp_path, fixtures({"a", "b", "c", "d"}, 5900), fixtures({"a", "b", "c"}, 3000))
    assert ras.verdict(off, routing) == "flip"


def test_keep_off_when_two_fixtures_worse(tmp_path):
    off, routing = cells(tmp_path, fixtures({"a", "b", "c", "d"}, 5900), fixtures({"a", "b"}, 3000))
    assert ras.verdict(off, routing).startswith("keep off")
    assert "accuracy" in ras.verdict(off, routing)


def test_keep_off_when_not_faster_even_at_equal_accuracy(tmp_path):
    off, routing = cells(tmp_path, fixtures({"a", "b"}, 5900), fixtures({"a", "b"}, 5900))
    assert ras.verdict(off, routing).startswith("keep off")
    assert "latency" in ras.verdict(off, routing)


def test_open_chat_regression_blocks_the_flip_too(tmp_path):
    off = fixtures({"a"}, 5900) + fixtures({"a", "b", "c", "d"}, 3000, kind="open-chat")
    routing = fixtures({"a"}, 1000) + fixtures({"a"}, 3000, kind="open-chat")
    o, r = cells(tmp_path, off, routing)
    assert ras.verdict(o, r).startswith("keep off")


def test_chain_fixtures_are_out_of_the_verdict_and_in_their_own_column(tmp_path):
    # The stubs tell a native loop to stop after one call, so `off` fails every chain fixture by
    # construction; a chain cell that regresses two plain fixtures must still read "keep off".
    plain = ("a", "b", "c", "d")
    off = fixtures(set(plain), 5000, names=plain) + fixtures(set(), 5000, names=("tool-chain-x", "tool-chain-y", "tool-chain-z"))
    chain = fixtures({"a", "b"}, 3000, names=plain) + fixtures({"tool-chain-x", "tool-chain-y", "tool-chain-z"}, 3000,
                                                                names=("tool-chain-x", "tool-chain-y", "tool-chain-z"))
    o = ras.load_cell(write_cell(tmp_path, "lil", "off", off))
    c = ras.load_cell(write_cell(tmp_path, "lil", "chain", chain))
    assert o.fixtures_passed("tool-use") == (4, 4) and c.fixtures_passed("tool-use") == (2, 4)
    assert o.fixtures_passed("tool-use", chain=True) == (0, 3) and c.fixtures_passed("tool-use", chain=True) == (3, 3)
    assert ras.verdict(o, c).startswith("keep off (accuracy")
    out = ras.render({("lil", "off"): o, ("lil", "chain"): c})
    assert "| chain fx |" in out and "| 0/3 fx |" in out and "| 3/3 fx |" in out


def test_missing_cell_is_not_a_verdict():
    assert ras.verdict(None, None) == "no data"


def test_table_has_a_row_per_brain_and_config_and_verdicts_for_flags(tmp_path):
    for brain in ("lil", "big"):
        write_cell(tmp_path, brain, "off", fixtures({"a", "b"}, 6000))
        write_cell(tmp_path, brain, "routing", fixtures({"a", "b"}, 2000))
        write_cell(tmp_path, brain, "head", fixtures({"a", "b"}, 2500))
        write_cell(tmp_path, brain, "chain", fixtures(set(), 2500))
    out = ras.render(ras.load_dir(tmp_path, "2026-10-10"))
    assert out.count("| lil |") == 4 and out.count("| big |") == 4
    assert "flip" in out and "keep off" in out


def test_main_prints_and_reports_a_missing_directory(tmp_path, capsys):
    assert ras.main(["--dir", str(tmp_path), "--date", "2026-10-10"]) == 1
    write_cell(tmp_path, "lil", "off", fixtures({"a"}, 1))
    assert ras.main(["--dir", str(tmp_path), "--date", "2026-10-10"]) == 0
    assert "lil" in capsys.readouterr().out


# 2026-10-10: the 10-09 arm's head never fired (no fixture reached its floor), yet "routing + head"
# read as a flip. Each score now carries the stage that picked its tool; the table shows it, and a
# head cell where the head never picked is "untested", never a flip.
def staged(fixture, ms, stage, ok=True, repeat=0):
    return dict(trial(fixture, "tool-use", ms, ok=ok, repeat=repeat), routeStage=stage)


def test_trials_carry_their_route_stage(tmp_path):
    cell = ras.load_cell(write_cell(tmp_path, "lil", "head", [staged("a", 5, "head"), trial("b", "tool-use", 5)]))
    assert [t.stage for t in cell.trials] == ["head", None]
    assert cell.stage_counts() == {"head": 1}


def test_a_head_cell_whose_head_never_picked_is_untested_not_a_flip(tmp_path):
    off = ras.load_cell(write_cell(tmp_path, "lil", "off", fixtures({"a", "b", "c", "d"}, 3000)))
    never = ras.load_cell(write_cell(tmp_path, "lil", "head",
                                     [staged(n, 1000, "picker", repeat=r) for n in "abcd" for r in range(3)]))
    assert ras.verdict(off, never) == "untested (the head never picked)"
    fired = ras.load_cell(write_cell(tmp_path, "big", "head",
                                     [staged(n, 1000, "head", repeat=r) for n in "abcd" for r in range(3)]))
    assert ras.verdict(off, fired) == "flip"


def test_mini_is_measured_against_its_shipping_route_not_off(tmp_path):
    assert ras.baseline_config("mini") == "routing"
    assert ras.baseline_config("lil") == "off"
    write_cell(tmp_path, "mini", "off", fixtures(set(), 9000))
    write_cell(tmp_path, "mini", "routing", fixtures({"a", "b", "c", "d"}, 2000))
    write_cell(tmp_path, "mini", "head", [staged(n, 1000, "head", repeat=r) for n in "abcd" for r in range(3)])
    table = ras.render(ras.load_dir(tmp_path, "2026-10-10"))
    assert "| mini | routing |" in table and "baseline |" in table.split("| mini | routing |")[1].split("\n")[0]
    assert "head 12" in table


def test_the_stage_column_reads_dash_when_nothing_routed(tmp_path):
    write_cell(tmp_path, "lil", "off", fixtures({"a"}, 1000))
    row = next(r for r in ras.render(ras.load_dir(tmp_path, "2026-10-10")).splitlines() if r.startswith("| lil | off |"))
    assert row.split(" | ")[5] == "-"  # brain, config, tool-use, open-chat, chain fx, picked by
