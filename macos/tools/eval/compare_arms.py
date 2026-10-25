#!/usr/bin/env python3
"""compare_arms.py — two ChatEval reports, compared fixture by fixture: what moved, how that sits
against the noise, and whether the two arms were wired alike.

    python3 macos/tools/eval/compare_arms.py A.json B.json [--kinds reasoning] \\
        [--bucket-prefix reason-hard] [--exclude reason-days,reason-hard-weekday] [--brain lil]

The unit is the FIXTURE, not the trial: the repeats of one fixture share a prompt, so they are
not independent draws, and counting trials makes x2 noise look like a result. Per fixture, its
passes in A against B are up, down or same. The p is an exact two-sided sign test over the
fixtures that moved. The sign test needs P(up) = P(down) when nothing changed, which holds only
on equal repeats (an easy fixture at r=1 is 1/1 almost always; at r=3 it has three chances to
drop one), so a fixture with unequal repeat counts is trimmed to the first k = min(rA, rB)
repeats by repeatIndex on both sides, and the trimmed fixtures are named.

Two scores per trial, side by side (the same pair run_chateval's kind table prints, by the same
functions — `_passed`, `_latency_only`, `_empty`, `_applicable`, `_median` — so the tools agree):
  content  passed, or the ONLY failing check is the latency ceiling ("responsive");
  strict   no failing check at all. The latency ceiling rides run order (heat, display sleep,
           battery, the AFM daemon), so strict's moves are confounded with which arm ran first.
A not-applicable trial (one skip named "applicable") is out of every count; an empty answer is
the scorer's own `non-empty` check failing.

Printed: per bucket (a kind, or a --bucket-prefix slice of one) the fixtures, the trial counts
A → B, the fixture-level +up/−down, Δ pp (the mean per-fixture change in pass rate, B − A) and
the sign p; how many p-values the table holds (uncorrected — at .05 about one in twenty crosses
by chance, so name the row that decides before the run). A row with ≤ 5 fixtures moved cannot
reach p < .05 (5/0 is .0625): its p reads as unresolved, not as no change. Then the repeat
disagreement inside each arm (fixtures with r ≥ 2 whose repeats disagree; n/a at r=1): a
sampling diagnostic, not on the +up/−down scale — for a noise floor on that scale, compare an
arm against a re-run of itself (A vs A'). Per arm the median latency, empty answers, median
think chars, the median reflection count inside the kept thoughts (wait / hmm / alternatively,
whole words: NoWait's manipulation check; "—" for a report from before scores kept a thought) and
the routeStage tally; a "!" line for each wiring difference (one arm routed and
the other not — the 10-18 live/bare mix; modelID; power source; powermode; power that changed
mid-run per the runner's driver block). Then every moved fixture with both arms' latencies and
B's first miss. No verdict line: the tool prints the numbers, and the decision rule is Kev's.

A fixture leaves the comparison, and is listed, when it is in only one report, when both reports
carry a fixtureHash for it and the hashes differ (a reworded prompt is a different question), or
when --exclude names it. NO WRITER EMITS fixtureHash YET (ChatEvalScore has no such field; the
harvest plan's 1j adds it), so on every report today the reword check is inert, the tool says so,
and --exclude is the only working path.

Exit 0 on a comparison, 1 when no fixture is left to compare, 2 on input that is not a readable
ChatEval report.

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
Absorbs the scratch flips.py and score.py from the 10-18 thinking evals; the n/a, pass,
latency-only, empty and median rules are run_chateval's, so the two tools agree on every count.
Review: Kev + claude-opus-5-5, 2026-10-18 — review + challenger fold: an empty runs[] exits 2, not a traceback;
content/strict/empty import run_chateval's rules (startswith("respons") would forgive a future "response-format");
unequal repeats are trimmed to the common count (rates biased the sign test toward "B is worse"); the noise line is
n/a at r=1, counts only r≥2 fixtures, shows the r range and no longer claims to be "what a re-run moves"; Δ pp, the
uncorrected p-value count and the ≤5-moved legend; "!" lines for modelID, power source, powermode and mixed power;
strict labelled as confounded with run order. Not folded: a --primary flag (the decision row is Kev's to name
before the run, in the suite's notes, not a CLI default). Confidence 0.8 covers the comparison, not the hash check.
Review: Kev + claude-opus-5-5, 2026-10-18 — reflections: a report that keeps thoughts (ChatEvalScore.thought,
a02580f0) gets the median count of NoWait's words inside them per arm. The words are ThinkBudget.NoWait.words in
Swift; keep the two lists together. Confidence 0.85.
Open: the fixtureHash reword check is unexercised on real data until ChatEvalScore stamps one (plan 1j); if the
Swift key differs from `fixtureHash`, the check stays silently inert — pin the key name when 1j lands.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from run_chateval import (  # one rule per count across the eval tools
    _applicable,
    _empty,
    _latency_only,
    _median,
    _passed,
)

PREVIEW_CHARS = 70
SCORES = ("content", "strict")
# NoWait's openers (ThinkBudget.NoWait.words in Swift), counted as whole words in a kept thought.
REFLECTION = re.compile(r"\b(?:wait|hmm|alternatively)\b", re.IGNORECASE)
UNRESOLVED_MOVES = 5  # 5/0 is p = .0625: at or under this many moved fixtures, p < .05 is out of reach


@dataclass(frozen=True)
class Trial:
    fixture: str
    kind: str
    repeat: int
    content: bool
    strict: bool
    latency_ms: int | None
    preview: str
    empty: bool = False
    think_chars: int | None = None
    route_stage: str | None = None
    fixture_hash: str | None = None
    reflections: int | None = None  # REFLECTION hits in the kept thought; None when the score kept none


def _pick_runs(doc: object, brain: str | None) -> list[dict]:
    if not isinstance(doc, dict) or not isinstance(doc.get("runs"), list):
        raise ValueError("not a ChatEval report (no runs[])")  # noqa: TRY004 — every unreadable input is one ValueError
    runs = doc["runs"]
    if not runs:
        raise ValueError("not a ChatEval report (runs[] is empty)")
    brains = list(dict.fromkeys(str(r.get("brainID")) for r in runs))
    if brain is not None:
        runs = [r for r in runs if r.get("brainID") == brain]
        if not runs:
            raise ValueError(f"no run for brain {brain!r} (it holds {', '.join(brains)})")
    elif len(brains) > 1:
        raise ValueError(f"it holds several brains ({', '.join(brains)}): pick one with --brain")
    return runs


def trials_from_doc(doc: object, brain: str | None = None) -> list[Trial]:
    """Every applicable trial of the document's run (or of `brain`'s, when it holds several);
    ValueError when the document is not a ChatEval report."""
    try:
        return [Trial(fixture=str(s["fixtureID"]), kind=str(s["kind"]), repeat=int(s.get("repeatIndex") or 0),
                      content=_passed(s) or _latency_only(s), strict=_passed(s), latency_ms=s.get("latencyMS"),
                      preview=s.get("answerPreview") or "", empty=_empty(s), think_chars=s.get("thinkChars"),
                      route_stage=s.get("routeStage") or None, fixture_hash=s.get("fixtureHash") or None,
                      reflections=None if s.get("thought") is None else len(REFLECTION.findall(s["thought"])))
                for run in _pick_runs(doc, brain) for s in _applicable(run["scores"])]
    except (AttributeError, KeyError, TypeError) as e:
        raise ValueError(f"not a ChatEval report ({type(e).__name__}: {e})") from e


def wiring(doc: dict, brain: str | None) -> dict:
    """What has to match for two arms to compare: the run's brain and model, the commit, the power source and
    mode, and whether the power changed mid-run (the runner's `driver` block; older reports carry none)."""
    run = _pick_runs(doc, brain)[0]
    prov = doc.get("provenance") or {}
    power = (doc.get("driver") or {}).get("power") or {}
    return {"brain": run.get("brainID"), "model": run.get("modelID"), "commit": prov.get("appCommit"),
            "power": prov.get("powerSource"), "powermode": prov.get("powerMode"),
            "power_mixed": bool(power.get("mixed")), "config": prov.get("buildConfiguration")}


def describe(w: dict) -> str:
    """One provenance line: brain · model · commit · power · powermode."""
    parts = [w["brain"] or "?", w["model"] or "stock", w["commit"] or "commit ?", w["power"] or "power ?"]
    if w["powermode"] is not None:
        parts.append(f"powermode {w['powermode']}")
    if w.get("config") is not None:
        parts.append(f"config {w['config']}")
    return " · ".join(str(x) for x in parts)


def wiring_flags(a: dict, b: dict, routes_a: dict | None, routes_b: dict | None) -> list[str]:
    """A "!" line per difference that moves numbers on its own. The commit is not one (it is usually the
    change under test); an unknown value on one side is not a difference."""
    flags = []
    if (routes_a is None) != (routes_b is None):
        flags.append("! one arm routed and the other never did: the arms were not wired alike (the 10-18 live/bare mix)")
    if a["model"] != b["model"]:
        flags.append(f"! modelID differs (A {a['model'] or 'stock'} · B {b['model'] or 'stock'}): "
                     "every move below includes the model change")
    for key, label in (("power", "power source"), ("powermode", "powermode")):
        if a[key] is not None and b[key] is not None and a[key] != b[key]:
            flags.append(f"! {label} differs (A {a[key]} · B {b[key]}): latency and strict do not compare")
    # 2026-10-25: a Debug arm decodes about half as fast as a Release one, so the latency ceilings (and
    # every p50) move with no model change. An older document without the stamp is unknown, not different.
    config_a, config_b = a.get("config"), b.get("config")
    if config_a is not None and config_b is not None and config_a != config_b:
        flags.append(f"! build configuration differs (A {config_a} · B {config_b}): latency and strict do not compare")
    for arm, w in (("A", a), ("B", b)):
        if w["power_mixed"]:
            flags.append(f"! {arm}'s power changed mid-run (driver block): its latency is not headline-grade")
    return flags


def load_report(path: Path, brain: str | None = None) -> tuple[dict, list[Trial]]:
    """(wiring, trials); ValueError naming the file when it is not a ChatEval report."""
    try:
        doc = json.loads(path.read_text())
        trials = trials_from_doc(doc, brain)
        return wiring(doc, brain), trials
    except ValueError as e:
        raise ValueError(f"{path}: {e}") from e


def by_fixture(trials: list[Trial]) -> dict[str, list[Trial]]:
    out: dict[str, list[Trial]] = {}
    for t in trials:
        out.setdefault(t.fixture, []).append(t)
    return {f: sorted(ts, key=lambda t: t.repeat) for f, ts in out.items()}


def _rate(trials: list[Trial], score: str) -> float:
    return sum(getattr(t, score) for t in trials) / len(trials)


def direction(a: list[Trial], b: list[Trial], score: str = "content") -> str:
    """'up' | 'down' | 'same': the fixture's passes across its repeats, A against B (pair() has
    trimmed both to the same count, so this is a count compare)."""
    pa, pb = sum(getattr(t, score) for t in a), sum(getattr(t, score) for t in b)
    lhs, rhs = pb * len(a), pa * len(b)
    return "up" if lhs > rhs else "down" if lhs < rhs else "same"


def disagrees(trials: list[Trial], score: str = "content") -> bool:
    return len({getattr(t, score) for t in trials}) > 1


def sign_test_p(up: int, down: int) -> float:
    """Exact two-sided sign test: P(a split at least this lopsided | each moved fixture is a coin)."""
    n, k = up + down, min(up, down)
    return min(1.0, 2 * sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n)


def bucket_of(fixture: str, kind: str, prefixes: list[str]) -> str:
    """The first prefix the fixture id starts with, else its kind (reason-hard vs the rest of reasoning)."""
    return next((p for p in prefixes if fixture.startswith(p)), kind)


@dataclass
class Pairing:
    pairs: dict[str, tuple[list[Trial], list[Trial]]] = field(default_factory=dict)
    only_a: list[str] = field(default_factory=list)
    only_b: list[str] = field(default_factory=list)
    changed: list[str] = field(default_factory=list)  # fixtureHash differs: a reworded fixture
    excluded: list[str] = field(default_factory=list)  # --exclude, among the fixtures the reports held
    trimmed: list[str] = field(default_factory=list)  # unequal repeats, cut to the common count
    hashed: bool = False  # some fixture carried a hash on both sides, so the reword check ran


def pair(a: list[Trial], b: list[Trial], *, kinds: Sequence[str] = (), exclude: Sequence[str] = ()) -> Pairing:
    """Group both arms by fixture, set aside what can't be compared (each list sorted), and trim each
    pair to its first min(rA, rB) repeats by repeatIndex, so the sign test's null is a fair coin."""
    if kinds:
        a, b = [t for t in a if t.kind in kinds], [t for t in b if t.kind in kinds]
    ga, gb = by_fixture(a), by_fixture(b)
    out = Pairing()
    for fixture in sorted(set(ga) | set(gb)):
        if fixture in exclude:
            out.excluded.append(fixture)
        elif fixture not in gb:
            out.only_a.append(fixture)
        elif fixture not in ga:
            out.only_b.append(fixture)
        else:
            ta, tb = ga[fixture], gb[fixture]
            ha = {t.fixture_hash for t in ta if t.fixture_hash}
            hb = {t.fixture_hash for t in tb if t.fixture_hash}
            out.hashed = out.hashed or bool(ha and hb)
            if ha and hb and ha != hb:
                out.changed.append(fixture)
                continue
            k = min(len(ta), len(tb))
            if len(ta) != len(tb):
                out.trimmed.append(fixture)
            out.pairs[fixture] = (ta[:k], tb[:k])
    return out


def noise_floor(pairing: Pairing, score: str = "content") -> tuple[int, int, int]:
    """(inside A, inside B, of n): among the n fixtures with two or more repeats, those whose repeats
    disagree inside each arm. One trial can't disagree with itself, so r=1 fixtures are not in n."""
    multi = [(a, b) for a, b in pairing.pairs.values() if len(a) > 1]
    return sum(disagrees(a, score) for a, _ in multi), sum(disagrees(b, score) for _, b in multi), len(multi)


def _tally(pairs: list[tuple[list[Trial], list[Trial]]], score: str) -> dict:
    moves = Counter(direction(a, b, score) for a, b in pairs)
    return {"a": sum(getattr(t, score) for a, _ in pairs for t in a),
            "b": sum(getattr(t, score) for _, b in pairs for t in b),
            "na": sum(len(a) for a, _ in pairs), "nb": sum(len(b) for _, b in pairs),
            "up": moves["up"], "down": moves["down"], "p": sign_test_p(moves["up"], moves["down"]),
            "delta_pp": 100 * sum(_rate(b, score) - _rate(a, score) for a, b in pairs) / len(pairs)}


def bucket_rows(pairing: Pairing, prefixes: list[str]) -> list[dict]:
    """One row per bucket (sorted), then "all": fixtures, and per score the trial passes A and B,
    the fixtures up and down, the mean per-fixture change in pass rate (pp) and the sign-test p."""
    groups: dict[str, list] = {}
    for fixture, (a, b) in pairing.pairs.items():
        groups.setdefault(bucket_of(fixture, a[0].kind, prefixes), []).append((a, b))
    named = [(name, groups[name]) for name in sorted(groups)] + [("all", list(pairing.pairs.values()))]
    return [{"bucket": name, "fixtures": len(pairs), **{s: _tally(pairs, s) for s in SCORES}}
            for name, pairs in named]


def arm_stats(trials: list[Trial]) -> dict:
    """Median latency (lower middle), empty answers, median think chars over the `think_n` trials
    that recorded one (None when none did), the median reflection count over the `thought_n` trials that
    kept a thought (None when none did), and the routeStage tally (None when no trial was routed)."""
    think = [t.think_chars for t in trials if t.think_chars is not None]
    reflections = [t.reflections for t in trials if t.reflections is not None]
    return {"trials": len(trials),
            "median_ms": _median([t.latency_ms for t in trials if t.latency_ms is not None]),
            "empties": sum(t.empty for t in trials),
            "think_chars": _median(think), "think_n": len(think),
            "reflections": _median(reflections), "thought_n": len(reflections),
            "routes": dict(Counter(t.route_stage for t in trials)) if any(t.route_stage for t in trials) else None}


# ── rendering ───────────────────────────────────────────────────────────────

def _route_tally(routes: dict | None) -> str:
    if routes is None:
        return "—"
    return " · ".join(f"{k or 'none'} {v}" for k, v in sorted(routes.items(), key=lambda kv: (kv[0] is None, kv[0] or "")))


def _secs(ms: int | None) -> str:
    return "—" if ms is None else f"{ms / 1000:.1f} s"


def _lats(trials: list[Trial]) -> str:
    return " ".join("?" if t.latency_ms is None else f"{round(t.latency_ms / 1000)}s" for t in trials)


def _trials_cell(t: dict) -> str:
    return f"{t['a']}/{t['na']} → {t['b']}/{t['nb']}"


def _moves_cell(t: dict) -> str:
    return f"+{t['up']}/−{t['down']}"


def _named(label: str, ids: list[str]) -> str:
    return f"{label} ({len(ids)}): {', '.join(ids)}"


def _span(counts: list[int]) -> str:
    lo, hi = min(counts), max(counts)
    return f"{lo}" if lo == hi else f"{lo}–{hi}"


def dropped_line(pairing: Pairing) -> str:
    parts = [_named(label, ids) for label, ids in (("only in A", pairing.only_a), ("only in B", pairing.only_b),
                                                     ("fixtureHash changed", pairing.changed),
                                                     ("excluded", pairing.excluded)) if ids]
    return "dropped: " + (" · ".join(parts) if parts else "none")


def noise_line(pairing: Pairing) -> str:
    label = "repeat disagreement (content)"
    noise_a, noise_b, n = noise_floor(pairing)
    if n == 0:
        return f"{label}: n/a (r=1: one trial can't disagree)"
    reps = _span([len(a) for a, _ in pairing.pairs.values()])
    left_out = "" if n == len(pairing.pairs) else "; r=1 fixtures left out"
    return (f"{label}: A {noise_a}/{n} · B {noise_b}/{n} (r={reps}{left_out}) — sampling noise inside each arm, not on "
            "the +up/−down scale (for that, compare an arm against a re-run of itself)")


def render(names: tuple[str, str], wirings: tuple[dict, dict], pairing: Pairing, prefixes: list[str]) -> str:
    lines = [f"A  {names[0]} — {describe(wirings[0])}", f"B  {names[1]} — {describe(wirings[1])}", "",
             f"compared {len(pairing.pairs)} fixtures · {dropped_line(pairing)}"]
    if pairing.trimmed:
        count = len(pairing.trimmed)
        lines.append(f"  repeats trimmed to the common count on {count} fixture{'s' if count != 1 else ''}: "
                     f"{', '.join(pairing.trimmed)}")
    if not pairing.hashed:
        lines.append("  no fixtureHash on both sides: a reworded fixture is not caught — drop it with --exclude")

    rows = bucket_rows(pairing, prefixes)
    w = max(len("bucket"), *(len(r["bucket"]) for r in rows))
    tw = max(len("trials A → B"), *(len(_trials_cell(r[s])) for r in rows for s in SCORES))
    group_w = tw + 2 + 10 + 2 + 6 + 2 + 7  # trials, fx up/down, Δ pp, sign p
    lines += ["",
              (f"{'':{w}}  {'':>3}   {'content (a latency-only fail passes)':<{group_w}}   "
               "strict (no failing check; latency is confounded with run order)"),
              f"{'bucket':<{w}}  {'fx':>3}   "
              + "   ".join(f"{'trials A → B':<{tw}}  {'fx up/down':<10}  {'Δ pp':>6}  {'sign p':<7}"
                           for _ in SCORES).rstrip()]
    for r in rows:
        cells = "   ".join(f"{_trials_cell(r[s]):<{tw}}  {_moves_cell(r[s]):<10}  {r[s]['delta_pp']:>+6.1f}  "
                           f"{r[s]['p']:<7.3g}" for s in SCORES)
        lines.append(f"{r['bucket']:<{w}}  {r['fixtures']:>3}   {cells}".rstrip())
    lines += [("Δ pp: the mean per-fixture change in pass rate, B − A · sign p: exact, two-sided, over the fixtures "
               "that moved"),
              (f"a row with ≤ {UNRESOLVED_MOVES} fixtures moved cannot reach p < .05: read its p as unresolved, "
               "not as no change"),
              (f"{len(rows) * len(SCORES)} p-values in this table, uncorrected: at .05 about one in twenty crosses "
               "by chance, so the row that decides is named before the run")]

    a_trials = [t for a, _ in pairing.pairs.values() for t in a]
    b_trials = [t for _, b in pairing.pairs.values() for t in b]
    lines += ["", noise_line(pairing)]

    stats = {"A": arm_stats(a_trials), "B": arm_stats(b_trials)}
    lines += ["", "arm  trials   median  empties  think chars (n)  reflections (n)  routeStage"]
    for arm, st in stats.items():
        think = "—" if st["think_chars"] is None else f"{st['think_chars']:,} ({st['think_n']})"
        reflect = "—" if st["reflections"] is None else f"{st['reflections']} ({st['thought_n']})"
        lines.append(f"{arm:<3}  {st['trials']:>6}  {_secs(st['median_ms']):>7}  {st['empties']:>7}  "
                     f"{think:>15}  {reflect:>15}  {_route_tally(st['routes'])}")
    lines += wiring_flags(*wirings, stats["A"]["routes"], stats["B"]["routes"])

    movers = []
    for fixture, (a, b) in pairing.pairs.items():
        d = direction(a, b)
        if d != "same":
            movers.append((d != "up", bucket_of(fixture, a[0].kind, prefixes), fixture, a, b))
    lines += ["", "moved on content (passes per fixture, A → B):" + ("" if movers else " none")]
    fw = max([len(m[2]) for m in movers], default=0)
    bw = max([len(m[1]) for m in movers], default=0)
    for down, bucket, fixture, a, b in sorted(movers):
        pa, pb = sum(t.content for t in a), sum(t.content for t in b)
        lines.append(f"  {'−' if down else '+'} {fixture:<{fw}}  {bucket:<{bw}}  {pa}/{len(a)} → {pb}/{len(b)}  "
                     f"A {_lats(a)} · B {_lats(b)}")
        miss = next((t for t in b if not t.content), None)
        if miss is not None:
            preview = miss.preview.replace("\n", " ").strip()[:PREVIEW_CHARS].rstrip() or "(empty)"
            lines.append(f"      B miss: {preview}")
    return "\n".join(lines)


def _split(value: str) -> list[str]:
    return [x for x in value.split(",") if x]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("a", help="arm A, the baseline: a ChatEval JSON")
    ap.add_argument("b", help="arm B, the change: a ChatEval JSON")
    ap.add_argument("--kinds", default="", help="comma list of task kinds (default: every kind)")
    ap.add_argument("--bucket-prefix", default="",
                    help="comma list: fixtures whose id starts with one get their own bucket (reason-hard)")
    ap.add_argument("--exclude", default="",
                    help="comma list of fixture ids to leave out (reworded fixtures; no report carries fixtureHash yet)")
    ap.add_argument("--brain", help="the run to read when a report holds several brains")
    args = ap.parse_args(argv)

    try:
        loaded = [load_report(Path(p), args.brain) for p in (args.a, args.b)]
    except (OSError, ValueError) as e:
        print(f"✗ {e}", file=sys.stderr)
        return 2
    (wiring_a, a), (wiring_b, b) = loaded
    kinds = _split(args.kinds)
    pairing = pair(a, b, kinds=kinds, exclude=_split(args.exclude))
    if not pairing.pairs:
        held = sorted({t.kind for t in a + b})
        scope = f" for --kinds {','.join(kinds)} (the reports hold: {', '.join(held)})" if kinds else ""
        print(f"✗ no fixtures in common{scope} · {dropped_line(pairing)}", file=sys.stderr)
        return 1
    print(render((Path(args.a).name, Path(args.b).name), (wiring_a, wiring_b), pairing, _split(args.bucket_prefix)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
