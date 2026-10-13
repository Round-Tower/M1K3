#!/bin/zsh
# tdd.sh — the fast inner loop: build ONE test target and run only its tests.
#
#   tools/dev/tdd.sh M1K3VoiceTests             # every test in that target
#   tools/dev/tdd.sh M1K3VoiceTests VoiceMood   # only tests whose id matches VoiceMood (a regex)
#
# Why: `swift test --filter X` rebuilds every one of the 30 per-target test
# bundles that depend on what you touched, then runs an XCTest pass that finds
# nothing (the suite is all Swift Testing). Measured 2026-10-13 on a warm tree,
# two paired rounds after a one-line edit in M1K3Voice: `swift test --filter`
# took 20.4 s and 18.8 s, this script 14.5 s and 13.2 s (about 30% less).
#
# The inner loop only. Other bundles are not rebuilt here, so run the full
# `swift test --parallel --disable-xctest` before pushing.
#
# Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.8 (timings are one
# machine, warm). Prior: none (new file).

set -euo pipefail

target=${1:?usage: tools/dev/tdd.sh <TestTarget> [name filter]}
name=${2:-}
cd "${0:A:h}/../.."   # macos/

swift build --target "$target"

log=$(mktemp -t m1k3-tdd)
trap 'rm -f "$log"' EXIT
# Swift Testing ids are "<Target>.<Suite>/<test>()", so the anchored prefix keeps
# the run inside the bundle `swift build --target` just relinked.
swift test --skip-build --disable-xctest --filter "^${target}\\..*${name}" 2>&1 | tee "$log"

ran=$(grep -oE 'Test run with [0-9]+ tests' "$log" | awk '{ s += $4 } END { print s + 0 }')
if (( ran == 0 )); then
  print -u2 "tdd.sh: no tests matched ${target}${name:+ / $name} — a typo would otherwise pass silently"
  exit 1
fi
