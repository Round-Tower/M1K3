"""Pins run_chateval.py: the one command that takes "evaluate model X" to a
provenance-stamped ChatEvalDocument. The orchestration (quit, launch, wait) is
thin glue around these pure decisions — the decisions are what go wrong
silently: a battery run stamped as a headline, a trigger that names a path
outside the sandbox, another session's debug build killed mid-run.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.8 (pure parts pinned
here; the launch/quit glue is driven by hand on the real app).
Prior: none (new file).
Review: Kev + claude-fable-5.1, 2026-10-09 — the router arm's keys (`--router dispatch`, head, chain) pinned.
Review: Kev + claude-fable-5.1, 2026-10-09 — pins the Lil RAM-cap flag (5 GB own peak, lil only, inclusive).
Review: Kev + claude-opus-5-5, 2026-10-10 — `--router off`.
Review: Kev + claude-opus-5-5, 2026-10-18 — the timeout reap (`stop_child` on real children), both live-app
folders and the relaunch of the one that ran, the `driver` block, `--overwrite`, and the empty + p50 columns.
Review: Kev + claude-opus-5-5, 2026-10-18 — review fold: no secret and no home path in the driver block, the power
record (every poll; unknown is unverified, not mixed), the transcript set aside on a re-run and never the --save-to,
and run_direct's glue on a stand-in app that execs /bin/sleep (timeout → 6, Ctrl-C, SIGTERM to the runner, missing
binary: the child is gone and the live app reopened every time).
Review: Kev + claude-opus-5-5, 2026-10-19 — the relaunch retries once and says UNVERIFIED; a Ctrl-C in the cool-down
reopens the live app (`quit_for_run`); an abbreviated flag is refused.
Review: Kev + claude-opus-5.5, 2026-10-26 — `--router-search` (#713): off unless asked (the Mac ships the search head off),
never without dispatch, and threaded from main to the trigger.
Review: Kev + claude-opus-5.5, 2026-10-26 (review fold) — a --bare run with --router-search is flagged (its avoids
checks skip there).
"""

import json
import os
import plistlib
import signal
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

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


@pytest.mark.parametrize(("live_path", "router", "warns"), [
    (True, None, True),
    (True, "dispatch", False),
    (True, "off", False),
    (False, None, False),
])
def test_a_live_run_without_a_route_is_flagged(live_path, router, warns):
    # The plain turn (cut, retry, forced budget, NoWait) is reached only through a route, as in the app.
    assert (rc.route_warning(base_opts(live_path=live_path, router=router)) is not None) == warns


def test_a_bare_run_with_the_search_head_is_flagged():
    # #713 review: --bare runs world knowledge as bare generate, no tool on offer, so the #680 fixtures' avoids
    # checks skip there and the arm measures nothing of the head.
    warning = rc.route_warning(base_opts(live_path=False, router="dispatch", router_search=True))
    assert warning is not None and "--router-search" in warning
    assert rc.route_warning(base_opts(live_path=True, router="dispatch", router_search=True)) is None
    assert rc.route_warning(base_opts(live_path=False, router="dispatch", router_search=False)) is None


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
HOME_LIVE = "/Users/kev/Applications/M1K3.app"
LIVE_APPS = (LIVE, HOME_LIVE)
TARGET = "/tmp/rel/export/M1K3.app"


def test_plan_quits_the_live_app_and_a_stale_target():
    running = [(101, LIVE + "/Contents/MacOS/M1K3"), (202, TARGET + "/Contents/MacOS/M1K3")]
    plan = rc.plan_instances(running, live_apps=LIVE_APPS, target_app=TARGET)
    assert plan.to_quit == [101, 202]
    assert plan.blockers == []
    assert plan.live_running == LIVE
    assert plan.live_was_running is True


def test_plan_refuses_another_sessions_build():
    other = "/Users/kev/Library/Developer/Xcode/DerivedData/M1K3-abc/Build/Products/Debug/M1K3.app/Contents/MacOS/M1K3"
    plan = rc.plan_instances([(303, other)], live_apps=LIVE_APPS, target_app=TARGET)
    assert plan.to_quit == []
    assert plan.blockers == [(303, other)]
    assert plan.live_running is None
    assert plan.live_was_running is False


def test_plan_with_nothing_running():
    plan = rc.plan_instances([], live_apps=LIVE_APPS, target_app=LIVE)
    assert (plan.to_quit, plan.blockers, plan.live_running) == ([], [], None)


def test_the_live_app_is_either_applications_folder():
    # 2026-10-18: Kev's daily app runs from ~/Applications, and /Applications holds a copy too. Before this the
    # ~/Applications one read as "someone else's build", so every A/B needed a wrapper to quit it by hand.
    assert rc.LIVE_APPS == ("/Applications/M1K3.app", str(Path.home() / "Applications/M1K3.app"))


def test_plan_reports_the_live_app_path_that_was_actually_running():
    plan = rc.plan_instances([(101, HOME_LIVE + "/Contents/MacOS/M1K3")], live_apps=LIVE_APPS, target_app=TARGET)
    assert plan.to_quit == [101] and plan.blockers == []
    assert plan.live_running == HOME_LIVE, "the ~/Applications copy, not LIVE_APPS[0]"


def test_plan_does_not_take_a_lookalike_path_for_a_live_app():
    lookalike = "/Applications/M1K3.app.old/Contents/MacOS/M1K3"
    plan = rc.plan_instances([(404, lookalike)], live_apps=LIVE_APPS, target_app=TARGET)
    assert plan.blockers == [(404, lookalike)] and plan.live_running is None


def test_relaunch_reopens_the_live_app_that_was_running():
    assert rc.relaunch_argv(HOME_LIVE, no_relaunch=False) == ["open", "-a", HOME_LIVE]
    assert rc.relaunch_argv(LIVE, no_relaunch=False) == ["open", "-a", LIVE]
    assert rc.relaunch_argv(None, no_relaunch=False) is None, "nothing was running: open nothing"
    assert rc.relaunch_argv(HOME_LIVE, no_relaunch=True) is None


def test_relaunch_live_retries_once_and_says_when_the_live_app_did_not_reopen(monkeypatch, capsys):
    # `open -a` right after the eval app (same bundle id) was killed can fail with -600: once more after a beat,
    # then say so rather than leave Kev's live app closed in silence.
    plan = rc.InstancePlan(to_quit=[], blockers=[], live_running=HOME_LIVE)
    monkeypatch.setattr(rc.time, "sleep", lambda _s: None)
    for codes, unverified in (([1, 1], True), ([1, 0], False), ([0], False)):
        calls: list[list[str]] = []
        replies = iter(codes)
        monkeypatch.setattr(rc.subprocess, "run",
                            lambda argv, **_kw: (calls.append(argv), SimpleNamespace(returncode=next(replies)))[1])
        rc.relaunch_live(plan, no_relaunch=False)
        assert calls == [["open", "-a", HOME_LIVE]] * len(codes)
        assert ("UNVERIFIED" in capsys.readouterr().err) == unverified


def test_quit_for_run_reopens_the_live_app_when_interrupted_in_the_cool_down(tmp_path, monkeypatch):
    # main() quits the live app, then may sit out a 120 s AFM cool-down before run_direct's own guard starts:
    # a Ctrl-C there used to end the run with Kev's live app closed.
    stamp = tmp_path / "stamp"
    stamp.write_text(str(time.time()))
    monkeypatch.setattr(rc, "STAMP", stamp)
    monkeypatch.setattr(rc, "quit_app", lambda _path, _pids: True)
    monkeypatch.setattr(rc, "running_instances", list)
    relaunched: list[str | None] = []
    monkeypatch.setattr(rc, "relaunch_live", lambda plan, no_relaunch: relaunched.append(plan.live_running))

    def interrupted(_seconds):
        raise KeyboardInterrupt

    monkeypatch.setattr(rc.time, "sleep", interrupted)
    plan = rc.InstancePlan(to_quit=[9], blockers=[], live_running=HOME_LIVE)
    with pytest.raises(KeyboardInterrupt):
        rc.quit_for_run(plan, Path(TARGET), no_relaunch=False)
    assert relaunched == [HOME_LIVE]


def test_quit_for_run_reopens_nothing_when_m1k3_never_quit(tmp_path, monkeypatch):
    monkeypatch.setattr(rc, "STAMP", tmp_path / "stamp")
    monkeypatch.setattr(rc, "quit_app", lambda _path, _pids: False)
    monkeypatch.setattr(rc, "relaunch_live", lambda plan, no_relaunch: pytest.fail("nothing was quit"))
    plan = rc.InstancePlan(to_quit=[9], blockers=[], live_running=HOME_LIVE)
    assert rc.quit_for_run(plan, Path(TARGET), no_relaunch=False) is False


def test_main_refuses_an_abbreviated_flag(capsys):
    # run_arms reserves --save-to, --log, --timeout-min…; argparse's prefix matching let `--save=` past that guard.
    with pytest.raises(SystemExit):
        rc.main(["--name", "x", "--brains", "lil", "--save=/tmp/elsewhere.json"])
    assert "unrecognized arguments" in capsys.readouterr().err


# ── the timeout reap (2026-10-18): the runner started the app, so the runner stops it ──

def test_stop_child_terminates_a_running_child():
    # One orphaned eval app makes every later arm two MLX processes (the evals9–11 `reap()`).
    proc = subprocess.Popen(["sleep", "600"])
    try:
        assert rc.stop_child(proc, grace_s=10) == -signal.SIGTERM
        assert proc.poll() is not None
    finally:
        if proc.poll() is None:
            proc.kill()


def test_stop_child_kills_a_child_that_ignores_sigterm():
    ignore = ("import signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
              "print('ready', flush=True); time.sleep(600)")
    proc = subprocess.Popen([sys.executable, "-I", "-c", ignore], stdout=subprocess.PIPE, text=True)
    try:
        assert proc.stdout.readline().strip() == "ready"
        assert rc.stop_child(proc, grace_s=0.5) == -signal.SIGKILL
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.stdout.close()


def test_stop_child_leaves_an_exited_child_alone():
    proc = subprocess.Popen(["true"])
    proc.wait()
    assert rc.stop_child(proc, grace_s=1) == 0


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


def test_direct_runs_hold_the_display_awake_for_exactly_the_apps_lifetime():
    # 2026-10-07: with the display asleep macOS throttled the headless eval 10-35x (decode
    # 35 -> 0-3 tok/s), and `caffeinate -is` around the runner did not stop it. -d keeps the
    # display on; -w ties the assertion to the app's pid, so it ends when the app does.
    assert rc.caffeinate_argv(4242) == ["/usr/bin/caffeinate", "-dis", "-w", "4242"]


def test_direct_env_routes_the_report_to_stdout_and_keeps_the_caller_env():
    trig = {"M1K3_SELFTEST": "1", "M1K3_SELFTEST_OUT": "/container/path/run", "M1K3_SELFTEST_CHATEVAL_PCC": "1"}
    env = rc.direct_env(trig, {"PATH": "/usr/bin", "M1K3_SELFTEST_OUT": "/stale"})
    assert env["M1K3_SELFTEST_OUT"] == "-"
    assert env["M1K3_SELFTEST"] == "1"
    assert env["M1K3_SELFTEST_CHATEVAL_PCC"] == "1"
    assert env["PATH"] == "/usr/bin"
    assert trig["M1K3_SELFTEST_OUT"] == "/container/path/run", "the trigger map itself is not mutated"



def test_summary_names_the_build_configuration(tmp_path):
    # 2026-10-25: a Debug arm and a Release arm look alike in the summary unless the line says which.
    ok = {"fixtureID": "chat-x", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok]}],
                               "provenance": {"buildConfiguration": "Release"}}))
    assert "config=Release" in rc.summarise(doc)
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok]}], "provenance": {}}))
    assert "config=unknown" in rc.summarise(doc), "an older document says so rather than guessing Debug"


def test_summary_leaves_out_not_applicable_trials(tmp_path):
    na = {"fixtureID": "vis-x", "kind": "vision", "latencyMS": 0,
          "checks": [{"name": "applicable", "outcome": "skip", "detail": "n/a — text-only"}]}
    ok = {"fixtureID": "chat-x", "kind": "open-chat", "latencyMS": 9,
          "checks": [{"name": "non-empty", "outcome": "pass"}]}
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok, na]}], "provenance": {}}))
    summary = rc.summarise(doc)
    assert "1/1 trials passed" in summary
    assert "1 n/a" in summary


def test_summary_has_a_per_kind_table_with_a_content_column(tmp_path):
    # Stream B step 5 (2026-10-09): "code-gen 24/30, grounded-Q 18/24" were hand counts off the
    # JSON, and the latency-only split was hand-counted on top. One table, four columns.
    ok = {"fixtureID": "a", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    slow = {"fixtureID": "b", "kind": "code-gen", "latencyMS": 200000,
            "checks": [{"name": "non-empty", "outcome": "pass"}, {"name": "responsive", "outcome": "fail"}]}
    wrong = {"fixtureID": "c", "kind": "code-gen", "latencyMS": 9,
             "checks": [{"name": "contains expected", "outcome": "fail"}, {"name": "responsive", "outcome": "fail"}]}
    right = {"fixtureID": "d", "kind": "code-gen", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    na = {"fixtureID": "e", "kind": "vision", "latencyMS": 0, "checks": [{"name": "applicable", "outcome": "skip"}]}
    rows = rc.kind_rows([ok, slow, wrong, right, na])
    assert rows == [
        {"kind": "code-gen", "passed": 1, "total": 3, "latency_only": 1, "content": 2, "empty": 0, "p50_ms": 9,
         "think_tokens": None, "think_ms": None},
        {"kind": "open-chat", "passed": 1, "total": 1, "latency_only": 0, "content": 1, "empty": 0, "p50_ms": 9,
         "think_tokens": None, "think_ms": None},
    ], "kinds sorted, n/a trials left out, content = passed + latency-only; no think fields → None"
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok, slow, wrong, right, na]}], "provenance": {}}))
    table = rc.kind_table(rows)
    assert table.splitlines()[0].split() == ["kind", "passed", "latency-only", "content", "empty", "p50-ms",
                                             "~think-tk", "think-ms"]
    assert "code-gen" in table and "1/3" in table and "2/3" in table
    assert table in rc.summarise(doc), "the table rides in the summary under the run line"


def test_summary_counts_latency_only_fails_as_content_passes(tmp_path):
    # 2026-10-07: a display-sleep stall turned 42 of E4B's fails into latency-ceiling fails with
    # right answers — the summary must say how many, and what the content score is.
    ok = {"fixtureID": "a", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    slow = {"fixtureID": "b", "kind": "code-gen", "latencyMS": 200000,
            "checks": [{"name": "non-empty", "outcome": "pass"}, {"name": "responsive", "outcome": "fail"}]}
    wrong = {"fixtureID": "c", "kind": "reasoning", "latencyMS": 9,
             "checks": [{"name": "contains expected", "outcome": "fail"}, {"name": "responsive", "outcome": "fail"}]}
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok, slow, wrong]}], "provenance": {}}))
    first = rc.summarise(doc).splitlines()[0]
    assert "1/3 trials passed" in first
    assert "1 latency-only (content 2/3)" in first
    clean = tmp_path / "clean.json"
    clean.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok]}], "provenance": {}}))
    # The run line's suffix only appears when there is something to say; the per-kind table's
    # latency-only column is always there (that is what makes it a column).
    assert "latency-only (content" not in rc.summarise(clean)


def test_thinking_mode_rides_the_trigger_only_when_set():
    assert "M1K3_SELFTEST_CHATEVAL_THINKING" not in rc.build_trigger(
        base_opts(), container=CONTAINER, power_source="ac", powermode=None, commit=None, mlx_rev=None)
    trig = rc.build_trigger(base_opts(thinking="always"), container=CONTAINER, power_source="ac",
                            powermode=None, commit=None, mlx_rev=None)
    assert trig["M1K3_SELFTEST_CHATEVAL_THINKING"] == "always"


def test_unknown_thinking_mode_is_refused():
    with pytest.raises(ValueError):
        rc.build_trigger(base_opts(thinking="on"), container=CONTAINER, power_source="ac",
                         powermode=None, commit=None, mlx_rev=None)


def test_full_answers_rides_the_trigger_only_when_asked():
    assert "M1K3_SELFTEST_CHATEVAL_FULL_ANSWERS" not in rc.build_trigger(
        base_opts(), container=CONTAINER, power_source="ac", powermode=None, commit=None, mlx_rev=None)
    trig = rc.build_trigger(base_opts(full_answers=True), container=CONTAINER, power_source="ac",
                            powermode=None, commit=None, mlx_rev=None)
    assert trig["M1K3_SELFTEST_CHATEVAL_FULL_ANSWERS"] == "1"


def test_calculator_rides_the_trigger_only_when_asked():
    assert "M1K3_SELFTEST_CHATEVAL_CALCULATOR" not in rc.build_trigger(
        base_opts(), container=CONTAINER, power_source="ac", powermode=None, commit=None, mlx_rev=None)
    trig = rc.build_trigger(base_opts(calculator=True), container=CONTAINER, power_source="ac",
                            powermode=None, commit=None, mlx_rev=None)
    assert trig["M1K3_SELFTEST_CHATEVAL_CALCULATOR"] == "1"


def test_summary_shows_peak_memory_when_recorded(tmp_path):
    ok = {"fixtureID": "chat-x", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok], "peakMemoryMB": 5120}], "provenance": {}}))
    assert "peak 5120 MB" in rc.summarise(doc)


def test_summary_shows_the_brains_own_peak_when_resident_is_known(tmp_path):
    ok = {"fixtureID": "chat-x", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "big", "scores": [ok], "peakMemoryMB": 13502,
                                         "residentMemoryMBAtStart": 6100}], "provenance": {}}))
    assert "peak 13502 MB (own 7402 MB)" in rc.summarise(doc)


def test_summary_omits_own_peak_when_peak_is_below_resident(tmp_path):
    ok = {"fixtureID": "chat-x", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    doc = tmp_path / "run.json"
    doc.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok], "peakMemoryMB": 0,
                                         "residentMemoryMBAtStart": 900}], "provenance": {}}))
    summary = rc.summarise(doc)
    # "(own N MB)" is the figure that must be absent; "unknown" (the config field) also spells o-w-n.
    assert "(own" not in summary and "peak 0 MB" in summary


# ── the router arm (2026-10-09): the app's own route, with the head and chains as flags ──

def _trig(**over):
    return rc.build_trigger(base_opts(**over), container=CONTAINER, power_source="ac",
                            powermode=None, commit=None, mlx_rev=None)


def test_router_keys_are_absent_unless_asked():
    trig = _trig()
    assert not [k for k in trig if "ROUTER" in k]


def test_router_dispatch_wires_like_the_mac_app_by_default():
    # 2026-10-24: the Mac app turns the head and chains on when unset (AppEnvironment+ChatHistory.swift,
    # `whenUnset: true`); a bare `--router dispatch` ran without them and failed every tool-chain fixture
    # (gemma-12B 0/9 vs 9/9 wired like the app), which read as a router regression.
    plain = _trig(router="dispatch")
    assert plain["M1K3_SELFTEST_CHATEVAL_ROUTER"] == "dispatch"
    assert plain["M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD"] == "1"
    assert plain["M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN"] == "1"


def test_router_head_and_chain_can_each_be_turned_off_for_an_arm():
    no_head = _trig(router="dispatch", router_head=False)
    assert "M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD" not in no_head
    assert no_head["M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN"] == "1"
    no_chain = _trig(router="dispatch", router_chain=False)
    assert no_chain["M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD"] == "1"
    assert "M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN" not in no_chain


def test_router_head_or_chain_without_dispatch_is_refused():
    # The app reads them only under _ROUTER=dispatch; a silent no-op arm would read as "no gain".
    for over in ({"router_head": True}, {"router_chain": True}):
        with pytest.raises(ValueError):
            _trig(**over)
    # Off without dispatch says nothing the app could misread, so it passes; unset stays unset off dispatch.
    assert not [k for k in _trig(router="off", router_head=False, router_chain=False) if "HEAD" in k or "CHAIN" in k]
    assert not [k for k in _trig(router="off") if "HEAD" in k or "CHAIN" in k]


def test_main_threads_no_router_head_and_chain_to_the_trigger(tmp_path, monkeypatch, capsys):
    app = tmp_path / "M1K3.app"
    (app / "Contents").mkdir(parents=True)
    with open(app / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": rc.BUNDLE_ID}, handle)
    monkeypatch.setattr(rc, "sh", lambda *cmd: BATT_AC if cmd[-1] == "batt" else PMSET_G)
    monkeypatch.setattr(rc, "running_instances", list)
    base = ["--name", "x", "--brains", "big", "--app", str(app), "--dry-run", "--router", "dispatch"]

    assert rc.main(base) == 0
    wired = capsys.readouterr().out
    assert '"M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD": "1"' in wired and '"M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN": "1"' in wired

    head_key, chain_key = '"M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD"', '"M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN"'
    assert rc.main([*base, "--no-router-head", "--no-router-chain"]) == 0
    routing_only = capsys.readouterr().out
    assert head_key not in routing_only and chain_key not in routing_only

    # router_arm.sh's mixed cells.
    assert rc.main([*base, "--router-head", "--no-router-chain"]) == 0
    head_cell = capsys.readouterr().out
    assert head_key in head_cell and chain_key not in head_cell
    assert rc.main([*base, "--no-router-head", "--router-chain"]) == 0
    chain_cell = capsys.readouterr().out
    assert head_key not in chain_cell and chain_key in chain_cell


def test_router_search_is_off_unless_asked_even_under_dispatch():
    # #713: the Mac app ships the search head off (`whenUnset: false`), so a bare dispatch run wires like it.
    assert "M1K3_SELFTEST_CHATEVAL_ROUTER_SEARCH" not in _trig(router="dispatch")
    assert "M1K3_SELFTEST_CHATEVAL_ROUTER_SEARCH" not in _trig(router="dispatch", router_search=False)
    assert _trig(router="dispatch", router_search=True)["M1K3_SELFTEST_CHATEVAL_ROUTER_SEARCH"] == "1"


def test_router_search_without_dispatch_is_refused():
    # The app reads it only on the dispatch route: a silent no-op arm would read as "the head changes nothing".
    for router in (None, "off", "1"):
        with pytest.raises(ValueError):
            _trig(router=router, router_search=True)
    assert "M1K3_SELFTEST_CHATEVAL_ROUTER_SEARCH" not in _trig(router="off", router_search=False)


def test_main_threads_router_search_to_the_trigger(tmp_path, monkeypatch, capsys):
    app = tmp_path / "M1K3.app"
    (app / "Contents").mkdir(parents=True)
    with open(app / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": rc.BUNDLE_ID}, handle)
    monkeypatch.setattr(rc, "sh", lambda *cmd: BATT_AC if cmd[-1] == "batt" else PMSET_G)
    monkeypatch.setattr(rc, "running_instances", list)
    base = ["--name", "x", "--brains", "big", "--app", str(app), "--dry-run", "--router", "dispatch"]
    key = '"M1K3_SELFTEST_CHATEVAL_ROUTER_SEARCH"'
    assert rc.main(base) == 0
    assert key not in capsys.readouterr().out
    assert rc.main([*base, "--router-search"]) == 0
    assert f'{key}: "1"' in capsys.readouterr().out


def test_unknown_router_mode_is_refused():
    with pytest.raises(ValueError):
        _trig(router="turbo")


def test_summary_flags_a_lil_run_over_the_own_peak_cap(tmp_path):
    # Signed 2026-10-09: Lil's cap is 5 GB OWN peak (BrainTier.lilOwnPeakCapGB) on a 16 GB Mac —
    # the incumbent and Qwen3.5 both measured 4.8 GB; gemma-4 E4B's 10.3 GB is what it rejects.
    ok = {"fixtureID": "chat-x", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    over = tmp_path / "over.json"
    over.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok], "peakMemoryMB": 11000,
                                          "residentMemoryMBAtStart": 453}], "provenance": {}}))
    summary = rc.summarise(over)
    assert "own 10547 MB" in summary
    assert "OVER the Lil RAM cap (5 GB own peak)" in summary
    under = tmp_path / "under.json"
    under.write_text(json.dumps({"runs": [{"brainID": "lil", "scores": [ok], "peakMemoryMB": 5368,
                                           "residentMemoryMBAtStart": 453}], "provenance": {}}))
    assert "RAM cap" not in rc.summarise(under), "4.8 GB own peak is inside the cap"
    # The rule itself: mebibytes, inclusive at the cap, Lil only (Big's 7.4 GB has its own floor).
    assert rc.LIL_OWN_PEAK_CAP_GB == 5
    assert rc.over_lil_own_peak_cap("lil", 5120) is False
    assert rc.over_lil_own_peak_cap("lil", 5121) is True
    assert rc.over_lil_own_peak_cap("big", 7402) is False
    assert rc.over_lil_own_peak_cap("lil", None) is False


def test_router_off_is_the_arms_like_for_like_baseline():
    # 2026-10-10: the arm's `off` cell sent tool-use through LocalAgent while the router cells took
    # the live path, two different paths. `--router off` is the live path with no route.
    assert _trig(router="off")["M1K3_SELFTEST_CHATEVAL_ROUTER"] == "off"
    for over in ({"router_head": True}, {"router_chain": True}):
        with pytest.raises(ValueError):
            _trig(router="off", **over)


def test_kind_rows_carry_the_think_phase_medians():
    # 2026-10-10: Lil's reasoning "running wild" was a feeling until the score carried the think block.
    thought = {"fixtureID": "a", "kind": "reasoning", "latencyMS": 9, "thinkChars": 800, "thinkMS": 4000,
               "checks": [{"name": "non-empty", "outcome": "pass"}]}
    thought2 = {"fixtureID": "b", "kind": "reasoning", "latencyMS": 9, "thinkChars": 1200, "thinkMS": 6000,
                "checks": [{"name": "non-empty", "outcome": "pass"}]}
    old = {"fixtureID": "c", "kind": "reasoning", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    rows = rc.kind_rows([thought, thought2, old])
    assert rows[0]["think_tokens"] == 200 and rows[0]["think_ms"] == 4000, "lower-middle median (Swift's rule) over the trials that recorded it"
    table = rc.kind_table(rows)
    assert "200" in table and "4000" in table



def test_direct_argv_appends_app_args_after_the_binary():
    # The A/B arms that live in argv (e.g. -wrappedPersonaSeed NO) ride the exec's argument domain.
    assert rc.direct_argv(Path("/x/M1K3"), ["-wrappedPersonaSeed", "NO"]) == ["/x/M1K3", "-wrappedPersonaSeed", "NO"]
    assert rc.direct_argv(Path("/x/M1K3"), None) == ["/x/M1K3"]


# ── the kind table's empty + p50 columns (2026-10-18) ──

def test_kind_rows_count_empty_answers_and_the_p50_latency():
    # The day's headline numbers were empties (an Always turn that thought to the cap and said nothing) and
    # latency; both were read off the JSON by a scratch script. "empty" is the scorer's own non-empty check.
    def trial(fid, ms, *, said=True):
        return {"fixtureID": fid, "kind": "reasoning", "latencyMS": ms,
                "checks": [{"name": "non-empty", "outcome": "pass" if said else "fail"}]}
    na = {"fixtureID": "v", "kind": "reasoning", "latencyMS": 0, "checks": [{"name": "applicable", "outcome": "skip"}]}
    rows = rc.kind_rows([trial("a", 100), trial("b", 400, said=False), trial("c", 300), trial("d", 200, said=False), na])
    assert rows[0]["empty"] == 2
    assert rows[0]["p50_ms"] == 200, "lower-middle median of 100/200/300/400 (Swift's rule); n/a's 0 ms left out"
    table = rc.kind_table(rows)
    cells = table.splitlines()[1].split()
    assert cells[:6] == ["reasoning", "2/4", "0", "2/4", "2", "200"]


def test_p50_is_a_dash_when_no_trial_recorded_a_latency():
    rows = rc.kind_rows([{"fixtureID": "a", "kind": "chat", "checks": [{"name": "non-empty", "outcome": "pass"}]}])
    assert rows[0]["p50_ms"] is None
    assert rc.kind_table(rows).splitlines()[1].split()[5] == "—"


# ── provenance: the driver block (2026-10-18) ──

STEADY = {"start": "ac", "end": "ac", "seen": ["ac"], "mixed": False}


def test_driver_block_records_the_env_the_app_got_once():
    # card-auto (2026-10-18) ran under M1K3_SAMPLING=card-mode, which only its free-text notes recorded.
    trig = {"M1K3_SELFTEST": "1", "M1K3_SELFTEST_OUT": "/container/run", "M1K3_SELFTEST_CHATEVAL_THINKING": "always"}
    env = rc.direct_env(trig, {"PATH": "/usr/bin", "HOME": "/Users/kev", "M1K3_SAMPLING": "card-mode"})
    block = rc.driver_block(env, ["-thinkBudgetTokens", "1024"], STEADY, home="/Users/kev")
    assert block["env"] == {"M1K3_SAMPLING": "card-mode", "M1K3_SELFTEST": "1",
                            "M1K3_SELFTEST_CHATEVAL_THINKING": "always", "M1K3_SELFTEST_OUT": "-"}
    assert block["appArgs"] == ["-thinkBudgetTokens", "1024"]
    assert block["power"] == STEADY
    assert set(block) == {"env", "appArgs", "power"}, "one env record: no second copy of the trigger map"
    assert rc.driver_block(env, None, STEADY, home="/Users/kev")["appArgs"] == []


def test_driver_block_never_records_a_secret_from_the_shell_env():
    # The --save-to copy is published (docs/evals), and Kev's secrets loader exports keys by name:
    # M1K3_MCP_TOKEN is a bearer token with the M1K3_ prefix (tools/asc/verify_build.py). Only the trigger keys and
    # the sampling switch keep their values; any other M1K3_* name is recorded as set, its value withheld.
    base = {"M1K3_MCP_TOKEN": "sekrit-bearer-123", "M1K3_STORE_PATH": "/Volumes/x/store",
            "M1K3_SELFTEST_HF_TOKEN": "hf_sekrit", "M1K3_SAMPLING": "card-mode", "GITHUB_TOKEN": "ghp_sekrit"}
    env = rc.direct_env({"M1K3_SELFTEST": "1", "M1K3_SELFTEST_KEYEVAL": "1"}, base)
    block = rc.driver_block(env, None, STEADY, home="/Users/kev")
    text = json.dumps(block)
    assert "sekrit" not in text
    assert block["env"]["M1K3_MCP_TOKEN"] == rc.WITHHELD
    assert block["env"]["M1K3_STORE_PATH"] == rc.WITHHELD, "unlisted: named, never valued"
    assert block["env"]["M1K3_SELFTEST_HF_TOKEN"] == rc.WITHHELD, "a secret-shaped name is withheld under SELFTEST too"
    assert block["env"]["M1K3_SELFTEST_KEYEVAL"] == "1", "KEYEVAL is a trigger, not a key"
    assert block["env"]["M1K3_SAMPLING"] == "card-mode"
    assert "GITHUB_TOKEN" not in block["env"]


def test_every_trigger_key_keeps_its_value_in_the_driver_block():
    # The allowlist must never withhold a key the runner itself sets: that is the record the block exists for.
    opts = base_opts(model="lil=x", kinds=["reasoning"], repeats=2, notes="n", dump_prompt=True, pcc=True,
                     thinking="always", think_steer="budget", full_answers=True, calculator=True, router="dispatch",
                     router_head=True, router_chain=True)
    trig = rc.build_trigger(opts, container=CONTAINER, power_source="battery", powermode=2, commit="c", mlx_rev="m")
    assert rc.WITHHELD not in rc.driver_block(trig, None, STEADY, home="/Users/kev")["env"].values()


def test_a_failed_power_read_is_unknown_not_the_end_of_the_run(monkeypatch):
    def no_pmset(*_args):
        raise FileNotFoundError("pmset")

    monkeypatch.setattr(rc, "sh", no_pmset)
    assert rc.read_power() == "unknown"


def test_driver_block_writes_the_home_folder_as_a_tilde():
    # The non-direct trigger's OUT path is a container path under the home folder (the username, published).
    trig = {"M1K3_SELFTEST_OUT": "/Users/kev/Library/Containers/app.m1k3/Data/run",
            "M1K3_SELFTEST_NOTES": "kept at /Users/kevin/x"}
    block = rc.driver_block(trig, None, STEADY, home="/Users/kev")
    assert block["env"]["M1K3_SELFTEST_OUT"] == "~/Library/Containers/app.m1k3/Data/run"
    assert block["env"]["M1K3_SELFTEST_NOTES"] == "kept at /Users/kevin/x", "a lookalike home is not the home"


def test_power_record_marks_a_run_whose_power_changed_as_mixed():
    # card-auto again: the runner read battery at launch (its driver.txt says "power: battery" and the notes carry
    # the battery stamp), but provenance.powerSource says "ac". Not a pmset misread: the app reads its own power
    # source when it writes the document, at the END (ChatEvalStage.currentProvenance), and the Mac was plugged in
    # by then. Every reading the runner took, and the flag, are the fix.
    assert rc.power_record(["battery", "ac"]) == {"start": "battery", "end": "ac", "seen": ["ac", "battery"],
                                                  "mixed": True}
    assert rc.power_record(["ac", "ac", "ac"]) == STEADY


def test_power_record_sees_an_unplug_between_the_ends():
    # Start and end alone can't see an unplug and replug; the poll loop reads pmset every 10 s.
    record = rc.power_record(["ac", "ac", "battery", "ac"])
    assert (record["start"], record["end"], record["mixed"]) == ("ac", "ac", True)


def test_power_record_never_calls_an_unknown_read_a_change():
    # A failed pmset read (or a source the reader doesn't name) is not a crossing: a false "mixed" discredits good data.
    record = rc.power_record(["unknown", "ac"])
    assert record["mixed"] is False and record["seen"] == ["ac", "unknown"]
    assert rc.power_record(["unknown", "unknown"])["mixed"] is False


def test_power_record_at_launch_marks_the_end_pending():
    assert rc.power_record(["battery"], finished=False) == {"start": "battery", "end": "pending",
                                                            "seen": ["battery"], "mixed": False}


def test_power_source_reads_a_ups_as_the_app_does():
    # SystemStatusProviding maps "UPS Power" to .ups; reading it as unknown made a UPS desk run "unverified".
    assert rc.parse_power_source("Now drawing from 'UPS Power'\n") == "ups"


def test_with_driver_adds_the_block_without_touching_the_document():
    doc = {"schemaVersion": 1, "runs": [], "provenance": {"powerSource": "ac"}}
    block = rc.driver_block({}, None, STEADY)
    stamped = rc.with_driver(doc, block)
    assert stamped["driver"] == block
    assert stamped["provenance"] == {"powerSource": "ac"} and stamped["runs"] == []
    assert "driver" not in doc


def _doc_with_power(tmp_path, readings):
    ok = {"fixtureID": "a", "kind": "open-chat", "latencyMS": 9, "checks": [{"name": "non-empty", "outcome": "pass"}]}
    path = tmp_path / f"{'-'.join(readings)}.json"
    path.write_text(json.dumps(rc.with_driver(
        {"runs": [{"brainID": "lil", "scores": [ok]}], "provenance": {"powerSource": readings[-1]}},
        rc.driver_block({}, None, rc.power_record(readings)))))
    return path


def test_summary_flags_mixed_power_from_the_driver_block(tmp_path):
    assert "power mixed: battery at start, ac at end" in rc.summarise(_doc_with_power(tmp_path, ["battery", "ac"]))
    between = rc.summarise(_doc_with_power(tmp_path, ["ac", "battery", "ac"]))
    assert "power mixed: ac at start, ac at end (seen ac, battery)" in between
    steady = rc.summarise(_doc_with_power(tmp_path, ["ac", "ac"]))
    assert "mixed" not in steady and "unverified" not in steady


def test_summary_says_unverified_not_mixed_when_a_read_was_unknown(tmp_path):
    summary = rc.summarise(_doc_with_power(tmp_path, ["unknown", "ac"]))
    assert "power unverified: unknown at start, ac at end" in summary
    assert "mixed" not in summary


# ── --overwrite (2026-10-18: evals10 silently wrote over evals9's names) ──

def test_save_to_refusal_names_the_flag(tmp_path):
    existing = tmp_path / "run.json"
    existing.write_text("{}")
    assert rc.save_to_refusal(None, overwrite=False) is None
    assert rc.save_to_refusal(str(tmp_path / "new.json"), overwrite=False) is None
    assert rc.save_to_refusal(str(existing), overwrite=True) is None
    message = rc.save_to_refusal(str(existing), overwrite=False)
    assert message is not None and str(existing) in message and "--overwrite" in message


def test_main_refuses_an_existing_save_to_before_touching_anything(tmp_path, monkeypatch, capsys):
    app = tmp_path / "M1K3.app"
    (app / "Contents").mkdir(parents=True)
    with open(app / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": rc.BUNDLE_ID}, handle)
    existing = tmp_path / "run.json"
    existing.write_text('{"keep": true}')

    def touched(*_args, **_kwargs):
        raise AssertionError("the refusal must come before any probe, quit or launch")

    for name in ("sh", "running_instances", "quit_app", "run_direct"):
        monkeypatch.setattr(rc, name, touched)
    code = rc.main(["--name", "x", "--brains", "lil", "--direct", "--app", str(app), "--save-to", str(existing)])
    assert code == 2
    assert existing.read_text() == '{"keep": true}'
    assert "--overwrite" in capsys.readouterr().err


# ── the transcript: never overwritten by the JSON, never lost to a re-run (2026-10-18) ──

def test_direct_log_path_defaults_beside_save_to_or_in_temp(tmp_path):
    assert rc.direct_log_path("/x/run.log", "/y/run.json", "run") == Path("/x/run.log")
    assert rc.direct_log_path(None, "/y/run.json", "run") == Path("/y/run.log")
    assert rc.direct_log_path(None, None, "run").name == "m1k3-chateval-run.log"


@pytest.mark.parametrize("extra", [["--save-to", "{tmp}/run.log"],
                                   ["--save-to", "{tmp}/run.json", "--log", "{tmp}/run.json"]])
def test_main_refuses_a_transcript_that_is_the_save_to(tmp_path, monkeypatch, capsys, extra):
    # `--save-to foo.log` made the default transcript path the JSON's path: the document overwrote the transcript.
    app = tmp_path / "M1K3.app"
    (app / "Contents").mkdir(parents=True)
    with open(app / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": rc.BUNDLE_ID}, handle)

    def touched(*_args, **_kwargs):
        raise AssertionError("the refusal must come before any probe, quit or launch")

    for name in ("sh", "running_instances", "quit_app", "run_direct"):
        monkeypatch.setattr(rc, name, touched)
    argv = ["--name", "x", "--brains", "lil", "--direct", "--app", str(app)] + [a.format(tmp=tmp_path) for a in extra]
    assert rc.main(argv) == 2
    assert "same file" in capsys.readouterr().err


def test_aside_path_names_the_earlier_transcript_by_when_it_was_written():
    mtime = time.mktime((2026, 10, 18, 14, 30, 12, 0, 0, -1))
    assert rc.aside_path(Path("/out/card-always.log"), mtime) == Path("/out/card-always.20261018-143012.log")


# ── run_direct's glue, on a stand-in app (2026-10-18): a timeout, an interrupt, a kill ──
# The stand-in execs /bin/sleep, never anything named M1K3, so a live eval's `pgrep -x M1K3` can't see it.

@pytest.fixture
def direct_rig(tmp_path, monkeypatch):
    app = tmp_path / "M1K3.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/M1K3").write_text("")  # run_direct checks it exists; the exec below is /bin/sleep
    started: list[subprocess.Popen] = []
    real_popen = subprocess.Popen

    def popen(argv, *a, **kw):
        proc = real_popen(argv, *a, **kw)
        started.append(proc)
        return proc

    relaunched: list[str | None] = []
    monkeypatch.setattr(rc, "STAMP", tmp_path / "stamp")
    monkeypatch.setattr(rc, "direct_argv", lambda binary, app_args: ["/bin/sleep", "600"])
    monkeypatch.setattr(rc, "caffeinate_argv", lambda pid: ["/usr/bin/true"])
    monkeypatch.setattr(rc, "sh", lambda *args: BATT_AC)
    monkeypatch.setattr(rc, "relaunch_live", lambda plan, no_relaunch: relaunched.append(plan.live_running))
    monkeypatch.setattr(rc.subprocess, "Popen", popen)
    plan = rc.InstancePlan(to_quit=[], blockers=[], live_running=HOME_LIVE)
    trig = {"M1K3_SELFTEST": "1", "M1K3_SELFTEST_OUT": "/container/run"}

    def args(**over):
        base = {"log": str(tmp_path / "run.log"), "save_to": None, "name": "x", "timeout_min": 240, "app_arg": None,
                "no_relaunch": False}
        return SimpleNamespace(**{**base, **over})

    rig = SimpleNamespace(app=app, plan=plan, trig=trig, args=args, started=started, relaunched=relaunched,
                          log=tmp_path / "run.log")
    yield rig
    for proc in started:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def _gone(proc: subprocess.Popen) -> bool:
    return proc.poll() is not None


def test_run_direct_timeout_stops_the_child_relaunches_and_exits_6(direct_rig, capsys):
    code = rc.run_direct(direct_rig.args(timeout_min=0), direct_rig.app, direct_rig.trig, direct_rig.plan)
    assert code == 6
    app_proc = direct_rig.started[0]
    assert _gone(app_proc) and app_proc.returncode == -signal.SIGTERM, "the runner stopped the app it launched"
    assert direct_rig.relaunched == [HOME_LIVE], "a timeout must not leave the live app quit"
    out = capsys.readouterr()
    assert "timed out" in out.err and "scorecard.py" in out.err
    launch = next(line for line in out.out.splitlines() if line.startswith("driver: "))
    block = json.loads(launch[len("driver: "):])
    assert block["env"]["M1K3_SELFTEST_OUT"] == "-" and block["power"]["end"] == "pending", \
        "the driver block is on stdout at launch, so a run that leaves no JSON still has it"
    end = next(line for line in out.out.splitlines() if line.startswith("driver power: "))
    assert json.loads(end[len("driver power: "):])["end"] == "ac"


def test_run_direct_keeps_the_previous_transcript(direct_rig):
    # run_arms re-runs an arm whose JSON is missing — exactly a timed-out arm — and the re-run truncated its log.
    direct_rig.log.write_text("the timed-out run's transcript\n")
    rc.run_direct(direct_rig.args(timeout_min=0), direct_rig.app, direct_rig.trig, direct_rig.plan)
    kept = [p for p in direct_rig.log.parent.glob("run.*.log")]
    assert len(kept) == 1 and kept[0].read_text() == "the timed-out run's transcript\n"


def _on_poll(monkeypatch, act):
    """Patch the runner's 10-s poll sleep only: Popen.wait's own short sleeps (stop_child) stay real. A second poll
    means the first act didn't stop the loop, so it fails instead of polling forever."""
    real_sleep, polls = time.sleep, []

    def sleep(seconds):
        if seconds < 10:
            return real_sleep(seconds)
        polls.append(seconds)
        if len(polls) > 1:
            raise AssertionError("the runner kept polling")
        act()

    monkeypatch.setattr(rc.time, "sleep", sleep)


def test_run_direct_reaps_and_relaunches_when_interrupted(direct_rig, monkeypatch):
    def interrupt():
        raise KeyboardInterrupt

    _on_poll(monkeypatch, interrupt)
    with pytest.raises(KeyboardInterrupt):
        rc.run_direct(direct_rig.args(), direct_rig.app, direct_rig.trig, direct_rig.plan)
    assert _gone(direct_rig.started[0]), "no orphaned eval app"
    assert direct_rig.relaunched == [HOME_LIVE]


def test_run_direct_takes_a_sigterm_to_the_runner_down_the_same_path(direct_rig, monkeypatch):
    # `kill <runner pid>` (a stuck chain) must reap the app too. A sentinel stands in for the default action, so
    # a runner that never installs its own handler fails here instead of killing pytest.
    hits = []
    sentinel = lambda signum, frame: hits.append(signum)
    previous = signal.signal(signal.SIGTERM, sentinel)
    try:
        _on_poll(monkeypatch, lambda: os.kill(os.getpid(), signal.SIGTERM))
        with pytest.raises(SystemExit):
            rc.run_direct(direct_rig.args(), direct_rig.app, direct_rig.trig, direct_rig.plan)
        assert hits == [], "the runner's own handler took it"
        assert signal.getsignal(signal.SIGTERM) is sentinel, "and gave the old one back"
    finally:
        signal.signal(signal.SIGTERM, previous)
    assert _gone(direct_rig.started[0])
    assert direct_rig.relaunched == [HOME_LIVE]


def test_run_direct_relaunches_even_when_the_binary_is_missing(direct_rig):
    (direct_rig.app / "Contents/MacOS/M1K3").unlink()
    assert rc.run_direct(direct_rig.args(), direct_rig.app, direct_rig.trig, direct_rig.plan) == 2
    assert direct_rig.relaunched == [HOME_LIVE], "main quit the live app before run_direct looked"
