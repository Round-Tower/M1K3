#!/usr/bin/env python3
"""Turn a `run.py` output directory into a publishable markdown scorecard.

    ./scorecard.py runs/2026-08-22 [--markdown out.md] [--json out.json]

Mirrors `macos/tools/eval/scorecard.py`'s stance: this reshapes the raw
per-cell JSON `run.py` already wrote — it never re-derives a verdict, and it
fails loudly on a directory shape it doesn't recognise rather than silently
producing an empty table.

Two tripwires exist because the Android 9a day found bugs that don't show up
as ordinary pass/fail — a model can "pass" fixtures at 6 tokens of garbage if
nothing checks the token count, and a model can burn its whole budget
thinking and still technically not fail any single substring check:

  * BROKEN — median output tokens across a cell < 8. The android_armv9.0_1
    (SVE2) CPU-variant-produces-broken-logits bug reproduces as exactly this
    shape: `<think></think>` + end-of-generation at ~6 tokens, on every
    fixture, regardless of what the fixture actually asked.
  * THINKING RUNAWAY — median thinking-block length across a cell > 2000
    chars. The Qwen3.5-0.8B-spent-2048-tokens-reasoning-and-answered-nothing
    bug.

Signed: Kev + claude-fable-5, 2026-08-22, Confidence 0.7 (the reshaping logic
is straightforward and covered by the fixture JSON's own Kotlin-side tests
for shape; the tripwire FLOORS themselves are judgement calls carried over
from the bug reports, not independently re-derived, and this script has not
yet been run against a real device's output). Prior: Unknown.
"""

import argparse
import json
import statistics
import sys
from collections import OrderedDict, defaultdict
from pathlib import Path

BROKEN_LOGITS_TOKEN_FLOOR = 8
THINKING_RUNAWAY_CHAR_FLOOR = 2000


def load_run(run_dir):
    manifest_path = run_dir / "manifest.json"
    if not manifest_path.exists():
        sys.exit(f"{run_dir}: no manifest.json — wrong directory, or run.py never completed")
    manifest = json.loads(manifest_path.read_text())

    cells = []
    for cell in manifest["cells"]:
        if not cell.get("raw") or not Path(cell["raw"]).exists():
            cells.append({**cell, "results": []})
            continue
        report = json.loads(Path(cell["raw"]).read_text())
        cells.append({**cell, "results": report.get("results", []), "run": report.get("run", {})})
    return manifest["header"], cells


def summarise(cells):
    kinds = list(OrderedDict.fromkeys(r["kind"] for c in cells for r in c["results"]))
    table = {c["id"]: defaultdict(lambda: [0, 0]) for c in cells}
    latencies = defaultdict(list)
    tokens = defaultdict(list)
    thinking_chars = defaultdict(list)

    for c in cells:
        for r in c["results"]:
            entry = table[c["id"]][r["kind"]]
            entry[1] += 1
            entry[0] += int(bool(r.get("passed")))
            # A native hang produced no tokens/latency — exclude it from the
            # medians so it can't masquerade as a broken-logits signal.
            if r.get("error", "").startswith("native hang"):
                continue
            latencies[c["id"]].append(r.get("generateMs", 0))
            tokens[c["id"]].append(r.get("tokens", 0))
            if r.get("thinking"):
                thinking_chars[c["id"]].append(len(r["thinking"]))

    return kinds, table, latencies, tokens, thinking_chars


def tripwires(cells, tokens, thinking_chars):
    flags = {}
    for c in cells:
        cell_flags = []

        if c["status"] == "crashed":
            cell_flags.append("CELL CRASHED — no results captured")
        hung = c.get("hung") or [r["fixtureId"] for r in c["results"] if r.get("error", "").startswith("native hang")]
        if hung:
            cell_flags.append(f"HUNG (native, {len(hung)}): {', '.join(hung)}")

        # A native hang is a crash, not garbage output — keep it out of the
        # broken-logits median so the CPU-variant signal stays clean.
        cell_tokens = [
            r["tokens"] for r in c["results"]
            if not r.get("error", "").startswith("native hang")
        ]
        if cell_tokens:
            med = statistics.median(cell_tokens)
            if med < BROKEN_LOGITS_TOKEN_FLOOR:
                cell_flags.append(
                    f"BROKEN — median output {med:.0f} tokens (< {BROKEN_LOGITS_TOKEN_FLOOR}); "
                    "likely a broken CPU-variant/logits issue, not a genuinely bad model"
                )

        cell_thinking = thinking_chars.get(c["id"], [])
        if cell_thinking:
            med = statistics.median(cell_thinking)
            if med > THINKING_RUNAWAY_CHAR_FLOOR:
                cell_flags.append(f"THINKING RUNAWAY — median thinking {med:.0f} chars (> {THINKING_RUNAWAY_CHAR_FLOOR})")

        if cell_flags:
            flags[c["id"]] = cell_flags
    return flags


def markdown(header, cells, kinds, table, latencies, flags, source):
    out = [
        "# Android model-eval scorecard\n",
        f"Device: **{header.get('device', '?')}** · battery {header.get('batteryLevel', '?')}% · "
        f"{header.get('fixtureCount', '?')} fixtures · {header.get('timestamp', '?')}\n",
    ]

    cell_ids = [c["id"] for c in cells]
    width = max([len("task-kind")] + [len(k) for k in kinds])
    out.append("| " + "kind".ljust(width) + " | " + " | ".join(cell_ids) + " |")
    out.append("|" + "---|" * (len(cell_ids) + 1))
    for kind in kinds:
        row = []
        for cid in cell_ids:
            passed, total = table[cid][kind]
            row.append(f"{passed}/{total}" if total else "—")
        out.append("| " + kind.ljust(width) + " | " + " | ".join(row) + " |")

    totals, meds = [], []
    for cid in cell_ids:
        p = sum(table[cid][k][0] for k in kinds)
        t = sum(table[cid][k][1] for k in kinds)
        totals.append(f"**{p}/{t}**")
        meds.append(f"{int(statistics.median(latencies[cid]))}ms" if latencies.get(cid) else "—")
    out.append("| " + "**TOTAL**".ljust(width) + " | " + " | ".join(totals) + " |")
    out.append("| " + "median latency".ljust(width) + " | " + " | ".join(meds) + " |")

    out.append("\n### Tripwires\n")
    if flags:
        for cid, cell_flags in flags.items():
            for flag in cell_flags:
                out.append(f"- **{cid}**: {flag}")
    else:
        out.append("_None fired._")

    out.append("\n### Failures\n")
    any_fail = False
    for c in cells:
        fails = [r for r in c["results"] if not r.get("passed")]
        if not fails:
            continue
        any_fail = True
        out.append(f"**{c['id']}** ({len(fails)}):\n")
        for r in fails:
            why = "; ".join(r.get("failedChecks", [])) or r.get("error") or "no detail captured"
            out.append(f"- `{r['fixtureId']}` [{r['kind']}] — {why}")
        out.append("")
    if not any_fail:
        out.append("_No failures recorded._")

    out.append(f"\n<sub>Generated by `tools/eval/android/scorecard.py` from `{source}`.</sub>")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--markdown")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    header, cells = load_run(run_dir)
    kinds, table, latencies, tokens, thinking_chars = summarise(cells)
    flags = tripwires(cells, tokens, thinking_chars)
    md = markdown(header, cells, kinds, table, latencies, flags, str(run_dir))

    if args.markdown:
        Path(args.markdown).write_text(md + "\n")
        print(f"wrote {args.markdown}")
    else:
        print(md)

    if args.json_out:
        payload = {
            "header": header,
            "kinds": kinds,
            "results": {
                cid: {k: {"passed": table[cid][k][0], "total": table[cid][k][1]} for k in kinds}
                for cid in table
            },
            "medianLatencyMs": {cid: int(statistics.median(v)) for cid, v in latencies.items() if v},
            "flags": flags,
        }
        Path(args.json_out).write_text(json.dumps(payload, indent=2) + "\n")
        print(f"wrote {args.json_out}")


if __name__ == "__main__":
    main()
