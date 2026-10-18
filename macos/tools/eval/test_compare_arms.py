"""Pins compare_arms.py: two ChatEval reports compared fixture by fixture. The unit is the fixture
(repeats of one fixture are not independent), so the parts pinned hard are the ones that decide
what a reader believes: the up/down/same call per fixture, the exact sign-test p, the noise floor
inside each arm, and which fixtures leave the comparison (reworded, one-sided, excluded).

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
Review: Kev + claude-opus-5-5, 2026-10-18 — review + challenger fold: an empty runs[] is unreadable input; content,
strict and empty are run_chateval's own rules (pinned against kind_rows); unequal repeats are trimmed to the common
count by repeatIndex; the noise floor is n/a at r=1 and counts only r≥2 fixtures; Δ pp, the p-value count and the
wiring flags (model, power, powermode, mixed power, route); --kinds, --exclude, --brain and the dropped line driven
through main; the "all" row parsed, not substring-matched.
"""

import json

import compare_arms as ca
import pytest
import run_chateval as rc


def score(fixture, *, kind="reasoning", repeat=0, fails=(), ms=1000, preview="ok", **extra):
    """One score as ChatEvalDocument writes it; `fails` names the failing checks."""
    checks = [] if "non-empty" in fails else [{"name": "non-empty", "outcome": "pass"}]
    checks += [{"name": "coherent", "outcome": "skip"}]
    checks += [{"name": name, "outcome": "fail"} for name in fails]
    return {"fixtureID": fixture, "kind": kind, "repeatIndex": repeat, "latencyMS": ms,
            "answerPreview": preview, "checks": checks, **extra}


def runs(*passes, fixture="f", kind="reasoning", **extra):
    """One fixture's repeats: True passes, False fails on content, "slow" fails latency only."""
    fails = {True: (), False: ("contains expected",), "slow": ("responsive",)}
    return [score(fixture, kind=kind, repeat=i, fails=fails[p], **extra) for i, p in enumerate(passes)]


def doc(*scores, brain="lil", driver=None, **provenance):
    out = {"schemaVersion": 1, "provenance": {"appCommit": "abc12345", "powerSource": "ac", "powerMode": 0,
                                              **provenance},
           "runs": [{"brainID": brain, "modelID": "mlx-community/Qwen3.5-4B-MLX-4bit", "scores": list(scores)}]}
    if driver is not None:
        out["driver"] = driver
    return out


def trials(*scores, brain=None):
    return ca.trials_from_doc(doc(*scores), brain=brain)


# ── scoring a trial ─────────────────────────────────────────────────────────

def test_content_ignores_latency_only_fails_strict_does_not():
    slow = trials(*runs("slow"))[0]
    assert slow.content and not slow.strict
    wrong = trials(*runs(False))[0]
    assert not wrong.content and not wrong.strict
    right = trials(*runs(True))[0]
    assert right.content and right.strict  # skips are not fails


def test_not_applicable_trials_are_out():
    na = {"fixtureID": "see-photo", "kind": "vision", "repeatIndex": 0, "latencyMS": 1,
          "checks": [{"name": "applicable", "outcome": "skip"}]}
    assert [t.fixture for t in trials(na, *runs(True))] == ["f"]


def test_content_strict_and_empty_agree_with_run_chateval():
    """One rule per count across the eval tools: the same scores through kind_rows and through compare_arms."""
    scores = [score("a"),
              score("b", fails=("responsive",)),                       # latency only: a content pass
              score("c", fails=("contains expected",)),
              score("d", fails=("responsive", "contains expected")),   # slow AND wrong: a content fail
              score("e", fails=("response-format",)),                  # a check that merely starts "respons"
              score("f", fails=("non-empty",), preview=""),
              score("g", preview="  "),                                # blank preview, the scorer saw text
              {"fixtureID": "h", "kind": "reasoning", "repeatIndex": 0, "latencyMS": 1,
               "checks": [{"name": "applicable", "outcome": "skip"}]}]
    ts = trials(*scores)
    (row,) = rc.kind_rows(scores)
    assert [t.fixture for t in ts if t.content] == ["a", "b", "g"]
    assert row["content"] == sum(t.content for t in ts) == 3
    assert row["passed"] == sum(t.strict for t in ts) == 2
    assert row["empty"] == sum(t.empty for t in ts) == 1
    assert row["total"] == len(ts) == 7


# ── the sign test ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("up, down, p", [
    (5, 0, 0.0625),   # 2 · 1/32
    (0, 5, 0.0625),
    (3, 1, 0.625),    # 2 · (1 + 4)/16
    (1, 3, 0.625),
    (0, 0, 1.0),      # nothing moved, nothing to test
    (2, 2, 1.0),      # 2 · 11/16 caps at 1
    (6, 1, 0.125),    # 2 · (1 + 7)/128
    (10, 0, 0.001953125),
])
def test_sign_test_p_is_exact_and_two_sided(up, down, p):
    assert ca.sign_test_p(up, down) == pytest.approx(p)


# ── up / down / same per fixture ────────────────────────────────────────────

@pytest.mark.parametrize("a, b, expected", [
    ((True, False), (True, True), "up"),
    ((True, True), (True, False), "down"),
    ((True, False), (False, True), "same"),   # one pass each: the repeats moved, the fixture did not
    ((False, False), (False, False), "same"),
    (("slow", True), (True, True), "same"),   # content counts a latency-only fail as a pass
])
def test_direction_compares_passes_across_repeats(a, b, expected):
    assert ca.direction(trials(*runs(*a)), trials(*runs(*b))) == expected


def test_direction_on_strict_sees_the_latency_fail():
    assert ca.direction(trials(*runs("slow", True)), trials(*runs(True, True)), "strict") == "up"


# ── pairing: what leaves the comparison ─────────────────────────────────────

def test_unequal_repeats_are_trimmed_to_the_common_count():
    # The sign test needs P(up) = P(down) when nothing changed, which holds only on equal repeats: an easy
    # fixture at r=1 is 1/1 almost always, while r=3 has three chances to drop one (the challenger's 7% false
    # "B is worse" rate). So [T,F] vs [T,F,T] is [T,F] vs [T,F]: same.
    pairing = ca.pair(trials(*runs(True, False)), trials(*runs(True, False, True)))
    a, b = pairing.pairs["f"]
    assert (len(a), len(b)) == (2, 2)
    assert ca.direction(a, b) == "same"
    assert pairing.trimmed == ["f"]
    one = ca.pair(trials(*runs(True)), trials(*runs(True, False, True)))
    assert ca.direction(*one.pairs["f"]) == "same"  # rates said 1/1 → 2/3 "down"


def test_trimming_keeps_the_first_repeats_by_repeat_index():
    b = [score("f", repeat=2), score("f", repeat=0), score("f", repeat=1, fails=("contains expected",))]
    pairing = ca.pair(trials(*runs(True, False)), trials(*b))
    assert [t.repeat for t in pairing.pairs["f"][1]] == [0, 1]
    assert ca.direction(*pairing.pairs["f"]) == "same"


def test_equal_repeats_are_not_trimmed():
    assert ca.pair(trials(*runs(True, False)), trials(*runs(True, True))).trimmed == []


def test_fixtures_in_only_one_report_are_listed_and_dropped():
    a = trials(*runs(True, fixture="both"), *runs(True, fixture="gone"))
    b = trials(*runs(True, fixture="both"), *runs(True, fixture="new"))
    pairing = ca.pair(a, b)
    assert list(pairing.pairs) == ["both"]
    assert pairing.only_a == ["gone"]
    assert pairing.only_b == ["new"]


def test_a_changed_fixture_hash_drops_the_fixture_and_lists_it():
    a = trials(*runs(True, fixture="same", fixtureHash="aaa"), *runs(True, fixture="reworded", fixtureHash="bbb"))
    b = trials(*runs(True, fixture="same", fixtureHash="aaa"), *runs(False, fixture="reworded", fixtureHash="ccc"))
    pairing = ca.pair(a, b)
    assert list(pairing.pairs) == ["same"]
    assert pairing.changed == ["reworded"]
    assert pairing.hashed


def test_without_hashes_exclude_drops_by_hand():
    a = trials(*runs(True, fixture="keep"), *runs(True, fixture="reason-days"))
    b = trials(*runs(True, fixture="keep"), *runs(False, fixture="reason-days"))
    pairing = ca.pair(a, b, exclude=["reason-days", "never-there"])
    assert list(pairing.pairs) == ["keep"]
    assert pairing.excluded == ["reason-days"]  # only what the reports held
    assert pairing.changed == [] and not pairing.hashed


def test_a_hash_on_one_side_only_cannot_say_changed():
    a = trials(*runs(True, fixture="f", fixtureHash="aaa"))
    b = trials(*runs(True, fixture="f"))
    pairing = ca.pair(a, b)
    assert list(pairing.pairs) == ["f"] and pairing.changed == [] and not pairing.hashed


def test_kinds_filter_before_pairing():
    a = trials(*runs(True, fixture="r"), *runs(True, fixture="chat", kind="open-chat"))
    b = trials(*runs(True, fixture="r"))
    pairing = ca.pair(a, b, kinds=["reasoning"])
    assert list(pairing.pairs) == ["r"]
    assert pairing.only_a == []  # open-chat was never in the comparison


# ── the numbers printed ─────────────────────────────────────────────────────

def test_noise_floor_counts_fixtures_whose_repeats_disagree_in_each_arm():
    a = trials(*runs(True, False, fixture="f1"), *runs(True, True, fixture="f2"), *runs(False, False, fixture="f3"))
    b = trials(*runs(True, True, fixture="f1"), *runs(True, False, fixture="f2"), *runs(False, True, fixture="f3"))
    assert ca.noise_floor(ca.pair(a, b)) == (1, 2, 3)  # inside A, inside B, of the fixtures with r ≥ 2


def test_noise_floor_leaves_out_fixtures_with_one_repeat():
    a = trials(*runs(True, False, fixture="f1"), *runs(True, fixture="f2"))
    b = trials(*runs(True, True, fixture="f1"), *runs(False, fixture="f2"))
    assert ca.noise_floor(ca.pair(a, b)) == (1, 0, 1)  # one trial can't disagree with itself
    assert ca.noise_floor(ca.pair(trials(*runs(True)), trials(*runs(False)))) == (0, 0, 0)


def test_bucket_prefix_splits_a_kind():
    assert ca.bucket_of("reason-hard-ages", "reasoning", ["reason-hard"]) == "reason-hard"
    assert ca.bucket_of("reason-easy-sum", "reasoning", ["reason-hard"]) == "reasoning"
    assert ca.bucket_of("reason-hard-ages", "reasoning", []) == "reasoning"


def test_bucket_rows_count_fixtures_and_trials_per_bucket():
    a = trials(*runs(False, False, fixture="reason-hard-1"), *runs(True, True, fixture="reason-2"),
               *runs(True, "slow", fixture="follow", kind="instruction-following"))
    b = trials(*runs(True, True, fixture="reason-hard-1"), *runs(True, False, fixture="reason-2"),
               *runs(True, True, fixture="follow", kind="instruction-following"))
    rows = {r["bucket"]: r for r in ca.bucket_rows(ca.pair(a, b), ["reason-hard"])}
    assert list(rows) == ["instruction-following", "reason-hard", "reasoning", "all"]
    assert rows["reason-hard"]["content"] == {"a": 0, "b": 2, "na": 2, "nb": 2, "up": 1, "down": 0, "p": 1.0,
                                              "delta_pp": 100.0}
    assert rows["reasoning"]["content"]["down"] == 1
    assert rows["reasoning"]["content"]["delta_pp"] == -50.0
    assert rows["instruction-following"]["content"]["up"] == 0  # latency-only: same on content…
    assert rows["instruction-following"]["strict"]["up"] == 1   # …up on strict
    assert rows["all"]["fixtures"] == 3
    assert (rows["all"]["content"]["up"], rows["all"]["content"]["down"]) == (1, 1)
    assert (rows["all"]["strict"]["up"], rows["all"]["strict"]["down"]) == (2, 1)
    assert rows["all"]["content"]["delta_pp"] == pytest.approx(50 / 3)  # the mean of +100, −50 and 0


def test_arm_stats_median_empties_think_and_route():
    scores = [score("f", repeat=0, ms=3000, fails=("non-empty",), preview="", thinkChars=400, routeStage="picker"),
              score("f", repeat=1, ms=1000, fails=("non-empty",), preview="  ", routeStage="picker"),
              score("g", repeat=0, ms=2000, thinkChars=800),
              score("g", repeat=1, ms=4000, thinkChars=600)]
    stats = ca.arm_stats(trials(*scores))
    assert stats["median_ms"] == 2000  # the lower middle, Swift's medianOf rule
    assert stats["empties"] == 2
    assert stats["think_chars"] == 600
    assert stats["think_n"] == 3  # the median covers only the trials that recorded one, so say how many
    assert stats["routes"] == {"picker": 2, None: 2}


def test_arm_stats_without_think_or_route_fields():
    stats = ca.arm_stats(trials(*runs(True, True)))
    assert stats["think_chars"] is None and stats["think_n"] == 0
    assert stats["routes"] is None


def test_a_document_with_several_brains_needs_brain():
    two = doc(*runs(True))
    two["runs"].append({"brainID": "big", "scores": runs(False)})
    with pytest.raises(ValueError, match="lil, big"):
        ca.trials_from_doc(two)
    assert [t.content for t in ca.trials_from_doc(two, brain="big")] == [False]
    with pytest.raises(ValueError, match="no run for brain"):
        ca.trials_from_doc(two, brain="mini")


# ── wiring: what has to match for two arms to compare ───────────────────────

def test_wiring_reads_provenance_and_the_driver_power():
    w = ca.wiring(doc(*runs(True), driver={"power": {"start": "battery", "end": "ac", "mixed": True}}), None)
    assert w == {"brain": "lil", "model": "mlx-community/Qwen3.5-4B-MLX-4bit", "commit": "abc12345",
                 "power": "ac", "powermode": 0, "power_mixed": True}
    assert ca.wiring(doc(*runs(True)), None)["power_mixed"] is False  # older reports carry no driver block


def test_wiring_flags_name_what_differs():
    base = {"brain": "lil", "model": "m", "commit": "c1", "power": "ac", "powermode": 0, "power_mixed": False}
    assert ca.wiring_flags(base, {**base, "commit": "c2"}, None, None) == []  # the commit is usually the change
    assert ca.wiring_flags(base, {**base, "power": None, "powermode": None}, None, None) == []  # unknown ≠ differs
    flags = ca.wiring_flags(base, {**base, "model": "m2", "power": "battery", "powermode": 2, "power_mixed": True},
                            {"picker": 2}, None)
    assert len(flags) == 5 and all(f.startswith("! ") for f in flags)
    joined = "\n".join(flags)
    for needle in ("modelID", "power source", "powermode", "mid-run", "not wired alike"):
        assert needle in joined


# ── the command ─────────────────────────────────────────────────────────────

def write(tmp_path, name, document):
    path = tmp_path / name
    path.write_text(json.dumps(document))
    return path


def compare(tmp_path, a, b, *flags):
    return ca.main([str(write(tmp_path, "A.json", a)), str(write(tmp_path, "B.json", b)), *flags])


def row_of(out, bucket):
    """The table row for `bucket`, split into its cells."""
    return next(line for line in out.splitlines() if line.split()[:1] == [bucket]).split()


def test_smoke_two_inline_reports(tmp_path, capsys):
    long_miss = "first line\n" + "x" * 100
    a = doc(*runs(True, True, fixture="reason-a", routeStage="picker"),
            *runs(False, False, fixture="reason-hard-x"),
            *runs(True, "slow", fixture="follow-y", kind="instruction-following"),
            *runs(True, True, fixture="chat-z", kind="open-chat"),
            *runs(True, fixture="only-a"))
    b_scores = (runs(True, fixture="reason-a", routeStage="picker")
                + [score("reason-a", repeat=1, fails=("contains expected",), preview=long_miss, routeStage="picker")]
                + runs(True, True, fixture="reason-hard-x")
                + runs(True, True, fixture="follow-y", kind="instruction-following")
                + runs(True, True, fixture="chat-z", kind="open-chat")
                + runs(True, fixture="only-b"))
    rc_ = compare(tmp_path, a, doc(*b_scores), "--bucket-prefix", "reason-hard")
    out = capsys.readouterr().out
    assert rc_ == 0
    assert "only in A (1): only-a" in out and "only in B (1): only-b" in out
    # content: trials, fixtures +up/−down, Δ pp, p; then strict (follow-y moves on latency alone)
    assert row_of(out, "all") == ["all", "4", "6/8", "→", "7/8", "+1/−1", "+12.5", "1",
                                  "5/8", "→", "7/8", "+2/−1", "+25.0", "1"]
    assert row_of(out, "reason-hard")[:8] == ["reason-hard", "1", "0/2", "→", "2/2", "+1/−0", "+100.0", "1"]
    assert "B miss: first line " + "x" * 59 + "\n" in out  # 70 chars, newline folded
    assert "picker 2 · none 6" in out  # A's route tally over the 8 compared trials
    assert "A 0/4 · B 1/4 (r=2)" in out  # repeat disagreement
    assert "10 p-values" in out  # five rows × two scores, uncorrected
    assert "cannot reach p < .05" in out
    assert "confounded with run order" in out  # the strict group's label
    assert not any(line.lower().startswith("verdict") for line in out.splitlines())  # numbers only; the rule is Kev's


def test_a_route_mismatch_between_arms_is_flagged(tmp_path, capsys):
    assert compare(tmp_path, doc(*runs(True, True, routeStage="picker")), doc(*runs(True, True))) == 0
    assert "not wired alike" in capsys.readouterr().out


def test_a_power_mismatch_between_arms_is_flagged(tmp_path, capsys):
    assert compare(tmp_path, doc(*runs(True, True)), doc(*runs(True, True), powerSource="battery")) == 0
    out = capsys.readouterr().out
    assert "! power source differs (A ac · B battery)" in out


def test_one_repeat_has_no_noise_floor(tmp_path, capsys):
    assert compare(tmp_path, doc(*runs(True)), doc(*runs(False))) == 0
    out = capsys.readouterr().out
    assert "n/a (r=1" in out and "A 0/1" not in out


def test_mixed_repeat_counts_show_the_range(tmp_path, capsys):
    a = doc(*runs(True, False, fixture="f1"), *runs(True, fixture="f2"))
    b = doc(*runs(True, True, fixture="f1"), *runs(True, fixture="f2"))
    assert compare(tmp_path, a, b) == 0
    assert "A 1/1 · B 0/1 (r=1–2; r=1 fixtures left out)" in capsys.readouterr().out


def test_trimmed_fixtures_are_named(tmp_path, capsys):
    assert compare(tmp_path, doc(*runs(True, True)), doc(*runs(True, True, False))) == 0
    out = capsys.readouterr().out
    assert "repeats trimmed to the common count on 1 fixture: f" in out
    assert row_of(out, "all")[2:6] == ["2/2", "→", "2/2", "+0/−0"]  # B's third repeat is out of every count


def test_kinds_through_main(tmp_path, capsys):
    a = doc(*runs(True, True, fixture="r"), *runs(True, True, fixture="chat", kind="open-chat"))
    b = doc(*runs(True, False, fixture="r"), *runs(False, False, fixture="chat", kind="open-chat"))
    assert compare(tmp_path, a, b, "--kinds", "reasoning") == 0
    out = capsys.readouterr().out
    assert row_of(out, "reasoning")[1] == "1"
    assert not any(line.startswith("open-chat") for line in out.splitlines())
    assert compare(tmp_path, a, b, "--kinds", "reasonin") == 1  # a typo is not an empty comparison
    err = capsys.readouterr().err
    assert "reasonin" in err and "the reports hold: open-chat, reasoning" in err


def test_exclude_through_main(tmp_path, capsys):
    a = doc(*runs(True, fixture="keep"), *runs(True, fixture="reason-days"))
    b = doc(*runs(True, fixture="keep"), *runs(False, fixture="reason-days"))
    assert compare(tmp_path, a, b, "--exclude", "reason-days,") == 0
    out = capsys.readouterr().out
    assert "excluded (1): reason-days" in out
    assert row_of(out, "all")[1] == "1"


def test_changed_and_unhashed_fixtures_in_the_printout(tmp_path, capsys):
    a = doc(*runs(True, fixture="same", fixtureHash="aaa"), *runs(True, fixture="reworded", fixtureHash="bbb"))
    b = doc(*runs(True, fixture="same", fixtureHash="aaa"), *runs(False, fixture="reworded", fixtureHash="ccc"))
    assert compare(tmp_path, a, b) == 0
    out = capsys.readouterr().out
    assert "fixtureHash changed (1): reworded" in out
    assert "no fixtureHash" not in out
    assert compare(tmp_path, doc(*runs(True)), doc(*runs(True))) == 0
    assert "no fixtureHash on both sides" in capsys.readouterr().out


def test_brain_through_main(tmp_path, capsys):
    def two(passes):
        d = doc(*runs(True))
        d["runs"].append({"brainID": "big", "modelID": None, "scores": runs(*passes)})
        return d
    assert compare(tmp_path, two([False]), two([True])) == 2
    assert "pick one with --brain" in capsys.readouterr().err
    assert compare(tmp_path, two([False]), two([True]), "--brain", "big") == 0
    out = capsys.readouterr().out
    assert out.startswith("A  A.json — big · stock")
    assert row_of(out, "all")[5] == "+1/−0"


@pytest.mark.parametrize("content", ["{not json", json.dumps({"runs": [{"scores": [{"kind": "x"}]}]}),
                                     json.dumps([1, 2]), json.dumps({"runs": []})])
def test_unreadable_input_exits_nonzero(tmp_path, capsys, content):
    good = write(tmp_path, "good.json", doc(*runs(True)))
    bad = tmp_path / "bad.json"
    bad.write_text(content)
    assert ca.main([str(good), str(bad)]) == 2
    assert ca.main([str(good), str(tmp_path / "missing.json")]) == 2
    assert "✗" in capsys.readouterr().err


def test_a_run_with_no_scores_has_nothing_to_compare(tmp_path, capsys):
    empty = {"runs": [{"brainID": "lil", "scores": []}]}
    assert compare(tmp_path, doc(*runs(True)), empty) == 1
    assert "no fixtures in common" in capsys.readouterr().err


def test_nothing_in_common_is_not_a_comparison(tmp_path, capsys):
    a = write(tmp_path, "A.json", doc(*runs(True, fixture="x")))
    b = write(tmp_path, "B.json", doc(*runs(True, fixture="y")))
    assert ca.main([str(a), str(b)]) == 1
    assert "no fixtures in common" in capsys.readouterr().err
