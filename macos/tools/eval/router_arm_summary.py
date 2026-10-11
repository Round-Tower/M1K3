#!/usr/bin/env python3
"""router_arm_summary.py — the router arm's eight ChatEval JSONs (Lil and Big x off / routing /
head / chain) as one table, plus a verdict per flag.

    python3 macos/tools/eval/router_arm_summary.py --date 2026-10-10 [--dir macos/docs/evals]

Cells are named `<date>-router-arm-<brain>-<config>-x3-ac.json` (router_arm.sh writes them):
  off      flags off (the shipping default)
  routing  toolRouterAllTiers (the app's own route, dispatch on)
  head     routing + the group head (toolGroupRouter)
  chain    routing + two-tool chains (toolChain)

Only the tool-use and open-chat kinds count; a not-applicable trial is out of every count.
The two-tool `tool-chain-*` fixtures (#512) get their own column and stay OUT of the verdict:
every stub's canned output tells a native loop it is done ("no further search needed"), so
`off` can only fail them while a dispatch chain runs both tools up front — a win by
construction, not a measurement, until the stubs are chain-aware (follow-up).

Verdict, per brain and flag, against `off` (the brief's rule):
  flip      iff accuracy is >= off's WITHIN ONE FIXTURE, in both kinds, AND the median turn is faster.
  keep off  otherwise, naming which test failed.
A fixture passes when a MAJORITY of its repeats pass (no failing check), so x3 noise on one
fixture cannot flip a default by itself; "within one fixture" is a one-fixture tolerance.
The latency test is the median over every counted trial, strictly lower than off's.

Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 (rule from the brief; the
fixture-majority reading of "within one fixture" is mine — see the docs/BENCHMARKS.md router-arm
section). Prior: none (new file).
Review: same day, code-quality fold — the chain fixtures leave the verdict (the stub bias above)
and get a `chain fx` column.
Review: Kev + claude-opus-5-5, 2026-10-10 — a `picked by` column from each score's routeStage; a head cell whose
head never picked is "untested", not a flip (the 10-09 arm's head never fired); Mini's baseline is `routing`.
Review: Kev + claude-opus-5-5, 2026-10-10 — an `all` config (routing + head + chains together, what the Mac ships).
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path

KINDS = ("tool-use", "open-chat")
CONFIGS = ("off", "routing", "head", "chain", "all")  # all: routing + head + chains, what ships
FLAGS = CONFIGS[1:]
TOLERANCE_FIXTURES = 1
CHAIN_PREFIX = "tool-chain-"  # ChatEvalFixturesTests pins the name
_NAME = re.compile(r"router-arm-(?P<brain>[a-z]+)-(?P<config>[a-z]+)-x\d+-")


@dataclass(frozen=True)
class Trial:
    fixture: str
    kind: str
    latency_ms: int
    ok: bool
    stage: str | None = None  # the router stage that picked the tool (head / picker / agent)

    @property
    def is_chain(self) -> bool:
        return self.fixture.startswith(CHAIN_PREFIX)


@dataclass
class Cell:
    brain: str
    config: str
    trials: list[Trial] = field(default_factory=list)

    def of(self, kind: str | None, chain: bool | None = False) -> list[Trial]:
        """`chain`: False leaves the tool-chain-* fixtures out, True keeps only them, None takes all."""
        return [t for t in self.trials
                if (kind is None or t.kind == kind) and (chain is None or t.is_chain == chain)]

    def passed(self, kind: str, chain: bool | None = False) -> tuple[int, int]:
        rows = self.of(kind, chain)
        return sum(t.ok for t in rows), len(rows)

    def fixtures_passed(self, kind: str, chain: bool | None = False) -> tuple[int, int]:
        by_fixture: dict[str, list[bool]] = {}
        for t in self.of(kind, chain):
            by_fixture.setdefault(t.fixture, []).append(t.ok)
        return sum(2 * sum(v) > len(v) for v in by_fixture.values()), len(by_fixture)

    def stage_counts(self) -> dict[str, int]:
        """How often each router stage picked, over every routed turn (a turn may pick twice)."""
        counts: dict[str, int] = {}
        for t in self.trials:
            for stage in (t.stage or "").split(","):
                if stage:
                    counts[stage] = counts.get(stage, 0) + 1
        return counts

    def median_ms(self, kind: str | None = None) -> float | None:
        rows = [t.latency_ms for t in self.of(kind, chain=None)]
        return statistics.median(rows) if rows else None


def parse_cell_name(path: Path) -> tuple[str, str]:
    match = _NAME.search(path.name)
    if not match:
        raise ValueError(f"{path.name}: not a router-arm cell (<date>-router-arm-<brain>-<config>-x3-ac.json)")
    return match["brain"], match["config"]


def _is_not_applicable(score: dict) -> bool:
    return [(c.get("name"), c.get("outcome")) for c in score.get("checks", [])] == [("applicable", "skip")]


def load_cell(path: Path) -> Cell:
    brain, config = parse_cell_name(path)
    doc = json.loads(path.read_text())
    cell = Cell(brain, config)
    for run in doc.get("runs", []):
        for s in run.get("scores", []):
            if s.get("kind") not in KINDS or _is_not_applicable(s):
                continue
            ok = not any(c.get("outcome") == "fail" for c in s.get("checks", []))
            cell.trials.append(Trial(s.get("fixtureID", "?"), s["kind"], int(s.get("latencyMS", 0)), ok,
                                     s.get("routeStage")))
    return cell


def load_dir(directory: Path, date: str) -> dict[tuple[str, str], Cell]:
    cells = {}
    for path in sorted(directory.glob(f"{date}-router-arm-*.json")):
        cell = load_cell(path)
        cells[(cell.brain, cell.config)] = cell
    return cells


# Mini already routes in shipping (miniToolDispatch is on), so its baseline is the routing cell;
# its `off` row (no route at all) is shown but is not what users have.
BASELINES = {"mini": "routing"}


def baseline_config(brain: str) -> str:
    return BASELINES.get(brain, "off")


def verdict(off: Cell | None, other: Cell | None) -> str:
    if off is None or other is None or not off.trials or not other.trials:
        return "no data"
    # 2026-10-09: a head that never fired read as a head that won. No head pick, no verdict.
    if other.config == "head" and not other.stage_counts().get("head"):
        return "untested (the head never picked)"
    reasons = []
    for kind in KINDS:
        base, now = off.fixtures_passed(kind)[0], other.fixtures_passed(kind)[0]
        if now < base - TOLERANCE_FIXTURES:
            reasons.append(f"accuracy {kind} {now} < {base} fixtures")
    base_ms, now_ms = off.median_ms(), other.median_ms()
    if now_ms is None or base_ms is None or not now_ms < base_ms:
        reasons.append("latency not faster")
    return "flip" if not reasons else "keep off (" + "; ".join(reasons) + ")"


def _ms(value: float | None) -> str:
    return "-" if value is None else f"{value / 1000:.1f} s"


def render(cells: dict[tuple[str, str], Cell]) -> str:
    lines = ["| brain | config | tool-use | open-chat | chain fx | picked by | median (tool-use) | median (all) "
             "| verdict |",
             "|---|---|---|---|---|---|---|---|---|"]
    for brain in sorted({b for b, _ in cells}, key=lambda b: (b != "lil", b)):
        base = baseline_config(brain)
        for config in CONFIGS:
            cell = cells.get((brain, config))
            if cell is None:
                lines.append(f"| {brain} | {config} | - | - | - | - | - | - | missing |")
                continue
            rates = []
            for kind in KINDS:
                p, n = cell.passed(kind)
                fp, fn = cell.fixtures_passed(kind)
                rates.append(f"{p}/{n} ({fp}/{fn} fx)")
            cp, cn = cell.fixtures_passed("tool-use", chain=True)
            if config == base:
                v = "baseline"
            elif brain in BASELINES and config == "off":
                v = "not shipping (no route)"
            else:
                v = verdict(cells.get((brain, base)), cell)
            stages = cell.stage_counts()
            picked = " · ".join(f"{k} {stages[k]}" for k in ("head", "picker", "agent") if k in stages) or "-"
            lines.append(f"| {brain} | {config} | {rates[0]} | {rates[1]} | {cp}/{cn} fx | {picked} "
                         f"| {_ms(cell.median_ms('tool-use'))} | {_ms(cell.median_ms())} | {v} |")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--date", required=True, help="the run date prefix, YYYY-MM-DD")
    ap.add_argument("--dir", default=str(Path(__file__).resolve().parents[2] / "docs/evals"))
    args = ap.parse_args(argv)
    cells = load_dir(Path(args.dir), args.date)
    if not cells:
        print(f"✗ no {args.date}-router-arm-*.json in {args.dir}", file=sys.stderr)
        return 1
    print(render(cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())
