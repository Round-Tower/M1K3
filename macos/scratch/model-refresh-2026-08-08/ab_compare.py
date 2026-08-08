#!/usr/bin/env python3
"""Diff two CHATEVAL SelfTest transcripts fixture-by-fixture.

Usage: ab_compare.py <baseline.txt> <candidate.txt> [baseline-label] [candidate-label]

Prints a per-kind pass table, the per-fixture flips (the only rows that
actually carry a decision), and latency. Deliberately dumb text parsing —
the SelfTest transcript IS the artifact, and a parser that guesses would be
worse than one that fails loudly.
"""
import re
import sys
from collections import defaultdict

FIXTURE = re.compile(r"^\s{2}([\w\-.]+) \[([\w\-]+)\]: (PASS|FAIL) \((\d+)ms\)")


def parse(path):
    rows = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = FIXTURE.match(line.rstrip("\n"))
        if m:
            name, kind, verdict, ms = m.groups()
            rows[name] = (kind, verdict == "PASS", int(ms))
    return rows


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a_path, b_path = sys.argv[1], sys.argv[2]
    a_label = sys.argv[3] if len(sys.argv) > 3 else "baseline"
    b_label = sys.argv[4] if len(sys.argv) > 4 else "candidate"

    a, b = parse(a_path), parse(b_path)
    if not a or not b:
        sys.exit(f"parsed {len(a)} baseline / {len(b)} candidate fixtures — refusing to compare")

    shared = sorted(set(a) & set(b))
    only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))

    per_kind = defaultdict(lambda: [0, 0, 0, 0])  # a_pass, b_pass, total, ...
    lat_a = lat_b = 0
    for name in shared:
        kind, a_pass, a_ms = a[name]
        _, b_pass, b_ms = b[name]
        per_kind[kind][0] += int(a_pass)
        per_kind[kind][1] += int(b_pass)
        per_kind[kind][2] += 1
        lat_a += a_ms
        lat_b += b_ms

    print(f"=== A/B over {len(shared)} shared fixtures ===")
    print(f"{'kind':<12} {a_label:>14} {b_label:>14}   delta")
    print("-" * 60)
    ta = tb = tt = 0
    for kind in sorted(per_kind):
        ap, bp, tot, _ = per_kind[kind]
        ta, tb, tt = ta + ap, tb + bp, tt + tot
        d = bp - ap
        flag = "  <<<" if d < 0 else ("  +++" if d > 0 else "")
        print(f"{kind:<12} {ap:>8}/{tot:<5} {bp:>8}/{tot:<5} {d:+3d}{flag}")
    print("-" * 60)
    print(f"{'OVERALL':<12} {ta:>8}/{tt:<5} {tb:>8}/{tt:<5} {tb - ta:+3d}")
    print(f"\nmean latency: {a_label} {lat_a // max(1, len(shared))}ms · "
          f"{b_label} {lat_b // max(1, len(shared))}ms "
          f"({(lat_b / lat_a - 1) * 100:+.0f}%)")

    flips = [(n, a[n], b[n]) for n in shared if a[n][1] != b[n][1]]
    if flips:
        print(f"\n=== {len(flips)} FLIP(S) — the rows that decide it ===")
        for name, (kind, a_pass, _), (_, b_pass, _) in flips:
            arrow = "PASS -> FAIL" if a_pass else "FAIL -> PASS"
            print(f"  [{kind}] {name}: {arrow}")
    else:
        print("\nno fixture flipped verdict")

    if only_a or only_b:
        print(f"\n⚠ unshared fixtures — baseline-only {only_a}, candidate-only {only_b}")


if __name__ == "__main__":
    main()
