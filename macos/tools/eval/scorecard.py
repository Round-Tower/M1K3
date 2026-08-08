#!/usr/bin/env python3
"""Turn a CHATEVAL SelfTest transcript into a publishable scorecard.

    ./scorecard.py <transcript.txt> [--markdown out.md] [--json out.json]

The SelfTest transcript IS the raw artifact — this only reshapes it, and
deliberately fails loudly rather than guessing when the shape is unfamiliar.
A benchmark whose parser silently drops rows is worse than no benchmark.

What it emits:
  * a per-kind pass matrix, one column per brain;
  * per-brain totals and median latency (median, not mean — one 9-minute
    outlier should not redefine a model's typical speed);
  * every failure, with the scorer's own reason, because the failures are
    the part a reader learns from.

Signed: Kev + claude-opus-5, 2026-08-08, Confidence 0.9 (pure text
reshaping over a format this repo controls; the loud-failure stance is the
load-bearing choice). Prior: Unknown.
"""

import argparse
import json
import re
import statistics
import sys
from collections import OrderedDict, defaultdict

BRAIN = re.compile(r"^• chateval brain (\w+) \(([^)]+)\)")
FIXTURE = re.compile(r"^\s{2}([\w\-.]+) \[([\w\-]+)\]: (PASS|FAIL) \((\d+)ms\)")
CHECK = re.compile(r"^\s{4}([✓✗–]) (.+)$")
SAID = re.compile(r"^\s{4}· said: (.*)$")


def parse(path):
    """(brains, rows) — rows are dicts; raises if the file has no fixtures."""
    brains, rows, current, last = OrderedDict(), [], None, None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if m := BRAIN.match(line):
                current = m.group(1)
                brains[current] = m.group(2)
                continue
            if m := FIXTURE.match(line):
                last = {
                    "brain": current, "fixture": m.group(1), "kind": m.group(2),
                    "passed": m.group(3) == "PASS", "ms": int(m.group(4)),
                    "failed_checks": [], "said": None,
                }
                rows.append(last)
                continue
            if (m := SAID.match(line)) and last is not None:
                last["said"] = m.group(1).strip()
                continue
            if (m := CHECK.match(line)) and last is not None and m.group(1) == "✗":
                last["failed_checks"].append(m.group(2).strip())
    if not rows:
        sys.exit(f"{path}: no fixture lines found — wrong file, or the transcript format moved")
    if any(r["brain"] is None for r in rows):
        sys.exit(f"{path}: fixtures appear before any brain header — refusing to guess")
    return brains, rows


def summarise(brains, rows):
    kinds = list(OrderedDict.fromkeys(r["kind"] for r in rows))
    table = {b: defaultdict(lambda: [0, 0]) for b in brains}
    latencies = defaultdict(list)
    for r in rows:
        cell = table[r["brain"]][r["kind"]]
        cell[1] += 1
        cell[0] += int(r["passed"])
        latencies[r["brain"]].append(r["ms"])
    return kinds, table, latencies


def markdown(brains, rows, kinds, table, latencies, source):
    width = max([len("task-kind")] + [len(k) for k in kinds])
    out = ["| " + "kind".ljust(width) + " | " + " | ".join(brains[b] for b in brains) + " |"]
    out.append("|" + "---|" * (len(brains) + 1))
    for kind in kinds:
        cells = []
        best = max((table[b][kind][0] for b in brains), default=0)
        for b in brains:
            passed, total = table[b][kind]
            cell = f"{passed}/{total}" if total else "—"
            if total and passed == best and len(brains) > 1:
                cell = f"**{cell}**"
            cells.append(cell)
        out.append("| " + kind.ljust(width) + " | " + " | ".join(cells) + " |")
    totals, meds = [], []
    for b in brains:
        p = sum(table[b][k][0] for k in kinds)
        t = sum(table[b][k][1] for k in kinds)
        totals.append(f"**{p}/{t}**")
        meds.append(f"{int(statistics.median(latencies[b]))}ms" if latencies[b] else "—")
    out.append("| " + "**TOTAL**".ljust(width) + " | " + " | ".join(totals) + " |")
    out.append("| " + "median latency".ljust(width) + " | " + " | ".join(meds) + " |")

    out.append("\n### Failures\n")
    any_fail = False
    for b in brains:
        fails = [r for r in rows if r["brain"] == b and not r["passed"]]
        if not fails:
            out.append(f"**{brains[b]}** — none.\n")
            continue
        any_fail = True
        out.append(f"**{brains[b]}** ({len(fails)}):\n")
        for r in fails:
            why = "; ".join(r["failed_checks"]) or "no check detail captured"
            out.append(f"- `{r['fixture']}` [{r['kind']}] — {why}")
        out.append("")
    if not any_fail:
        out.append("_No failures recorded._")
    # The kinds whose verdict is explicitly HUMAN get their answers printed in
    # full, because a pass/fail cell tells a reader nothing about whether a joke
    # landed. This is the part of the scorecard you actually read.
    human_kinds = [k for k in ("humour", "interview") if k in kinds]
    if human_kinds:
        out.append("\n### What they actually said\n")
        out.append(
            "_These kinds are scored for engagement and failure modes only — "
            "never for whether the answer is good. That judgment is yours._\n"
        )
        for kind in human_kinds:
            out.append(f"#### {kind}\n")
            fixtures = list(OrderedDict.fromkeys(
                r["fixture"] for r in rows if r["kind"] == kind
            ))
            for fx in fixtures:
                out.append(f"**`{fx}`**\n")
                for b in brains:
                    said = next(
                        (r["said"] for r in rows
                         if r["kind"] == kind and r["fixture"] == fx and r["brain"] == b),
                        None,
                    )
                    out.append(f"- *{brains[b]}*: {said or '_(no answer captured)_'}")
                out.append("")
    out.append(f"\n<sub>Generated by `macos/tools/eval/scorecard.py` from `{source}`.</sub>")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript")
    ap.add_argument("--markdown")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()

    brains, rows = parse(args.transcript)
    kinds, table, latencies = summarise(brains, rows)
    md = markdown(brains, rows, kinds, table, latencies, args.transcript.split("/")[-1])
    if args.markdown:
        open(args.markdown, "w", encoding="utf-8").write(md + "\n")
        print(f"wrote {args.markdown}")
    else:
        print(md)
    if args.json_out:
        payload = {
            "brains": brains,
            "kinds": kinds,
            "results": {
                b: {k: {"passed": table[b][k][0], "total": table[b][k][1]} for k in kinds}
                for b in brains
            },
            "medianLatencyMS": {
                b: int(statistics.median(v)) for b, v in latencies.items() if v
            },
            "rows": rows,
        }
        open(args.json_out, "w", encoding="utf-8").write(json.dumps(payload, indent=2) + "\n")
        print(f"wrote {args.json_out}")


if __name__ == "__main__":
    main()
