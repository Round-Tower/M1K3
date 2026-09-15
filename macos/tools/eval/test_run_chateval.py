"""Pins run_chateval.py: the one command that takes "evaluate model X" to a
provenance-stamped ChatEvalDocument. The orchestration (quit, launch, wait) is
thin glue around these pure decisions — the decisions are what go wrong
silently: a battery run stamped as a headline, a trigger that names a path
outside the sandbox, another session's debug build killed mid-run.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.8 (pure parts pinned
here; the launch/quit glue is driven by hand on the real app).
Prior: none (new file).
"""

from pathlib import Path

import pytest

import run_chateval as rc

CONTAINER = Path("/Users/kev/Library/Containers/app.m1k3/Data")

BATT_AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n"
BATT_BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t69%; discharging; 3:57 remaining present: true\n"
PMSET_G = "System-wide power settings:\nCurrently in use:\n standby              1\n powermode            2\n sleep                1\n"


def test_power_source_reads_pmset_batt():
    assert rc.parse_power_source(BATT_AC) == "ac"
    assert rc.parse_power_source(BATT_BATTERY) == "battery"
    assert rc.parse_power_source("") == "unknown"


def test_powermode_reads_pmset_g():
    assert rc.parse_powermode(PMSET_G) == 2
    assert rc.parse_powermode(" lowpowermode 1\n") is None  # a different key is not powermode
    assert rc.parse_powermode("") is None


def test_mlx_revision_reads_the_resolved_pin():
    resolved = {"pins": [
        {"identity": "swift-transformers", "state": {"revision": "aaa"}},
        {"identity": "mlx-swift-lm", "state": {"revision": "e3d4a20e"}},
    ]}
    assert rc.mlx_revision(resolved) == "e3d4a20e"
    assert rc.mlx_revision({"pins": []}) is None


@pytest.mark.parametrize("name", ["lil-e2b", "gemma-4-e2b.x2", "A_b-1"])
def test_run_names_that_are_safe(name):
    assert rc.validate_name(name) == name


@pytest.mark.parametrize("name", ["", ".hidden", "a/b", "../up", "x" * 121, "sp ace"])
def test_run_names_that_are_refused(name):
    with pytest.raises(ValueError):
        rc.validate_name(name)


def test_out_path_stays_inside_the_container():
    out = rc.out_path(CONTAINER, "lil-e2b")
    assert out == CONTAINER / "Library/Application Support/M1K3/selftest-out/lil-e2b"
    assert rc.json_path(out) == Path(str(out) + ".json")


def base_opts(**over):
    opts = rc.RunOptions(name="lil-e2b", brains=["lil"])
    for key, value in over.items():
        setattr(opts, key, value)
    return opts


def test_trigger_minimal_run():
    trig = rc.build_trigger(base_opts(), container=CONTAINER, power_source="ac", powermode=2,
                            commit="8b5bf57a", mlx_rev="e3d4a20e")
    assert trig["M1K3_SELFTEST"] == "1"
    assert trig["M1K3_SELFTEST_CHATEVAL"] == "1"
    assert trig["M1K3_SELFTEST_CHATEVAL_BRAINS"] == "lil"
    assert trig["M1K3_SELFTEST_CHATEVAL_LIVE_PATH"] == "1"
    assert trig["M1K3_SELFTEST_OUT"] == str(CONTAINER / "Library/Application Support/M1K3/selftest-out/lil-e2b")
    assert trig["M1K3_SELFTEST_POWERMODE"] == "2"
    assert trig["M1K3_SELFTEST_APP_COMMIT"] == "8b5bf57a"
    assert trig["M1K3_SELFTEST_MLX_REVISION"] == "e3d4a20e"
    # absent options stay absent — the app's defaults decide, not a guessed value
    for key in ("M1K3_SELFTEST_CHATEVAL_MLX_MODEL", "M1K3_SELFTEST_CHATEVAL_KINDS",
                "M1K3_SELFTEST_CHATEVAL_REPEATS", "M1K3_SELFTEST_DUMP_PROMPT"):
        assert key not in trig
    assert all(isinstance(v, str) for v in trig.values())


def test_trigger_candidate_run():
    opts = base_opts(model="lil=mlx-community/gemma-4-e2b-it-4bit", kinds=["tool-use", "security"],
                     repeats=2, notes="small-gemma audition")
    trig = rc.build_trigger(opts, container=CONTAINER, power_source="ac", powermode=None,
                            commit=None, mlx_rev=None)
    assert trig["M1K3_SELFTEST_CHATEVAL_MLX_MODEL"] == "lil=mlx-community/gemma-4-e2b-it-4bit"
    assert trig["M1K3_SELFTEST_CHATEVAL_KINDS"] == "tool-use,security"
    assert trig["M1K3_SELFTEST_CHATEVAL_REPEATS"] == "2"
    assert trig["M1K3_SELFTEST_NOTES"] == "small-gemma audition"
    assert "M1K3_SELFTEST_POWERMODE" not in trig  # unknown is omitted, never 0
    assert "M1K3_SELFTEST_APP_COMMIT" not in trig


def test_battery_is_stamped_into_the_notes():
    trig = rc.build_trigger(base_opts(notes="exp"), container=CONTAINER, power_source="battery",
                            powermode=0, commit=None, mlx_rev=None)
    assert "battery" in trig["M1K3_SELFTEST_NOTES"]
    assert trig["M1K3_SELFTEST_NOTES"].startswith("exp")
    bare = rc.build_trigger(base_opts(), container=CONTAINER, power_source="battery",
                            powermode=0, commit=None, mlx_rev=None)
    assert "battery" in bare["M1K3_SELFTEST_NOTES"]


def test_live_path_can_be_turned_off_for_bare_generation():
    trig = rc.build_trigger(base_opts(live_path=False), container=CONTAINER, power_source="ac",
                            powermode=2, commit=None, mlx_rev=None)
    assert "M1K3_SELFTEST_CHATEVAL_LIVE_PATH" not in trig


def test_dump_prompt_goes_inside_the_container():
    trig = rc.build_trigger(base_opts(dump_prompt=True), container=CONTAINER, power_source="ac",
                            powermode=2, commit=None, mlx_rev=None)
    assert trig["M1K3_SELFTEST_DUMP_PROMPT"] == str(
        CONTAINER / "Library/Application Support/M1K3/selftest-dump/lil-e2b")


def test_pcc_column_rides_the_trigger_and_may_run_alone():
    alone = rc.build_trigger(base_opts(brains=[], pcc=True), container=CONTAINER, power_source="ac",
                             powermode=2, commit=None, mlx_rev=None)
    assert alone["M1K3_SELFTEST_CHATEVAL_PCC"] == "1"
    assert alone["M1K3_SELFTEST_CHATEVAL_BRAINS"] == ""  # no tiers: the PCC column alone
    both = rc.build_trigger(base_opts(brains=["lil"], pcc=True), container=CONTAINER, power_source="ac",
                            powermode=2, commit=None, mlx_rev=None)
    assert both["M1K3_SELFTEST_CHATEVAL_BRAINS"] == "lil" and both["M1K3_SELFTEST_CHATEVAL_PCC"] == "1"
    with pytest.raises(ValueError, match="no brains"):
        rc.build_trigger(base_opts(brains=[]), container=CONTAINER, power_source="ac",
                         powermode=2, commit=None, mlx_rev=None)


@pytest.mark.parametrize("brains", [[], ["lil", "huge"], ["LIL"]])
def test_unknown_brains_are_refused(brains):
    with pytest.raises(ValueError):
        rc.build_trigger(base_opts(brains=brains), container=CONTAINER, power_source="ac",
                         powermode=2, commit=None, mlx_rev=None)


def test_repeats_must_be_positive():
    with pytest.raises(ValueError):
        rc.build_trigger(base_opts(repeats=0), container=CONTAINER, power_source="ac",
                         powermode=2, commit=None, mlx_rev=None)


def test_cooldown_waits_out_the_afm_window():
    assert rc.cooldown_remaining(None, now=1000.0) == 0
    assert rc.cooldown_remaining(950.0, now=1000.0) == 70
    assert rc.cooldown_remaining(800.0, now=1000.0) == 0
    assert rc.cooldown_remaining(990.0, now=1000.0, window=30) == 20


LIVE = "/Applications/M1K3.app"
TARGET = "/tmp/rel/export/M1K3.app"


def test_plan_quits_the_live_app_and_a_stale_target():
    running = [(101, LIVE + "/Contents/MacOS/M1K3"), (202, TARGET + "/Contents/MacOS/M1K3")]
    plan = rc.plan_instances(running, live_app=LIVE, target_app=TARGET)
    assert plan.to_quit == [101, 202]
    assert plan.blockers == []
    assert plan.live_was_running is True


def test_plan_refuses_another_sessions_build():
    other = "/Users/kev/Library/Developer/Xcode/DerivedData/M1K3-abc/Build/Products/Debug/M1K3.app/Contents/MacOS/M1K3"
    plan = rc.plan_instances([(303, other)], live_app=LIVE, target_app=TARGET)
    assert plan.to_quit == []
    assert plan.blockers == [(303, other)]
    assert plan.live_was_running is False


def test_plan_with_nothing_running():
    plan = rc.plan_instances([], live_app=LIVE, target_app=LIVE)
    assert (plan.to_quit, plan.blockers, plan.live_was_running) == ([], [], False)


# ── direct mode (macOS 27) ───────────────────────────────────────────────────

def test_extract_fenced_json_takes_the_last_complete_block():
    stale = rc.FENCE_OPEN + '\n{"runs": []}\n' + rc.FENCE_CLOSE
    real = rc.FENCE_OPEN + '\n{"runs": [{"brainID": "pcc"}]}\n' + rc.FENCE_CLOSE
    text = "• chateval: 1 fixture\n" + stale + "\nnoise\n" + real + "\n• chateval json → stdout (fenced)\n"
    assert rc.extract_fenced_json(text) == {"runs": [{"brainID": "pcc"}]}
    # a transcript that opens with the marker itself still parses (the line start counts as a boundary)
    assert rc.extract_fenced_json(rc.FENCE_OPEN + '\n{"a": 1}\n' + rc.FENCE_CLOSE) == {"a": 1}


def test_extract_fenced_json_refuses_partials_and_names_bad_json():
    assert rc.extract_fenced_json("plain transcript\n{}\n") is None
    assert rc.extract_fenced_json(rc.FENCE_OPEN + '\n{"a": 1}\n') is None
    assert rc.extract_fenced_json('{"a": 1}\n' + rc.FENCE_CLOSE + "\n") is None
    with pytest.raises(ValueError, match="not JSON"):
        rc.extract_fenced_json(rc.FENCE_OPEN + "\nnot json\n" + rc.FENCE_CLOSE)


def test_extract_fenced_json_ignores_markers_echoed_inside_the_document():
    # an answer preview quoting EITHER marker sits inside a JSON string, never at a line start
    body = '{"runs": [{"answerPreview": "it printed ' + rc.FENCE_OPEN + ' then ' + rc.FENCE_CLOSE + ' and stopped"}]}'
    text = "• chateval: 1 fixture\n" + rc.FENCE_OPEN + "\n" + body + "\n" + rc.FENCE_CLOSE + "\n"
    assert rc.extract_fenced_json(text) == {"runs": [{"answerPreview": "it printed " + rc.FENCE_OPEN + " then " + rc.FENCE_CLOSE + " and stopped"}]}


def test_direct_outcome_reads_the_exit_code_beside_the_document():
    log = Path("/tmp/run.log")
    assert rc.direct_outcome({"runs": []}, 0, log) == (0, "")
    code, note = rc.direct_outcome({"runs": []}, 139, log)
    assert code == 8 and "exited 139" in note
    code, note = rc.direct_outcome(None, 0, log)
    assert code == 7 and "no fenced JSON" in note


def test_direct_env_routes_the_report_to_stdout_and_keeps_the_caller_env():
    trig = {"M1K3_SELFTEST": "1", "M1K3_SELFTEST_OUT": "/container/path/run", "M1K3_SELFTEST_CHATEVAL_PCC": "1"}
    env = rc.direct_env(trig, {"PATH": "/usr/bin", "M1K3_SELFTEST_OUT": "/stale"})
    assert env["M1K3_SELFTEST_OUT"] == "-"
    assert env["M1K3_SELFTEST"] == "1"
    assert env["M1K3_SELFTEST_CHATEVAL_PCC"] == "1"
    assert env["PATH"] == "/usr/bin"
    assert trig["M1K3_SELFTEST_OUT"] == "/container/path/run", "the trigger map itself is not mutated"

