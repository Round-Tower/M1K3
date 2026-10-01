#!/bin/bash
# select_what_to_test.sh <TestFlight dir> <CI_PRODUCT_PLATFORM>
#
# Xcode Cloud uploads TestFlight/WhatToTest.<locale>.txt (beside the project) as
# each build's "What to Test". One universal record means one folder for three
# platforms, so the notes live per platform in TestFlight/notes/<platform>.<locale>.txt
# and this copies the archiving platform's set into place. A platform with no
# notes gets none: an empty field beats telling iPhone testers to try the Mac CLI.
# Builds 438/439 shipped with the field empty because nothing set it at all.
#
# Signed: Kev + claude-opus-5.5, 2026-10-01, Confidence 0.8 (the folder contract
#   is Apple's "Including notes for testers"; the per-platform swap is the
#   CI_PRODUCT_PLATFORM pattern; first live proof is the next Cloud archive).
# Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
set -euo pipefail

dir="${1:?usage: select_what_to_test.sh <TestFlight dir> <platform>}"
platform="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
[ -n "$platform" ] || { echo "--- What to Test: no platform given — leaving notes unset."; exit 0; }

shopt -s nullglob
copied=0
for notes in "$dir/notes/$platform."*.txt; do
  locale="$(basename "$notes" .txt)"
  locale="${locale#"$platform".}"
  cp "$notes" "$dir/WhatToTest.$locale.txt"
  copied=$((copied + 1))
done
echo "--- What to Test: $copied locale(s) of $platform notes in place."
