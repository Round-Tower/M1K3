#!/bin/bash
# ci_pre_xcodebuild.sh — Xcode Cloud pre-build hook for M1K3 (macOS)
set -euo pipefail

echo "=== M1K3 CI: Pre-Build ==="
echo "CI_XCODEBUILD_ACTION: ${CI_XCODEBUILD_ACTION:-unknown}"
echo "CI_WORKFLOW:          ${CI_WORKFLOW:-unknown}"
echo "CI_BRANCH:            ${CI_BRANCH:-unknown}"
echo "CI_COMMIT:            ${CI_COMMIT:-unknown}"

# M1K3 is privacy-first — NO Firebase/analytics plist to verify (unlike the prior knowledge-server app).
# Just confirm xcodegen actually produced the project in post-clone.
#
# CI_PRIMARY_REPOSITORY_PATH is NOT exported in every action phase — in the
# `test-without-building` phase it's unbound, and `set -u` then aborts this hook
# with "unbound variable" (build 57's Test action, exit 1). It's only meaningful
# while there's a repo checkout to verify, so skip the check when it's absent.
REPO="${CI_PRIMARY_REPOSITORY_PATH:-}"
if [ -z "$REPO" ]; then
  echo "--- CI_PRIMARY_REPOSITORY_PATH unset in the ${CI_XCODEBUILD_ACTION:-?} phase — skipping project check."
  # An archive that lands here uploads with an empty "What to Test" — say so.
  [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] && echo "⚠️ archive without a repo path: TestFlight notes NOT set for this build."
  echo "=== Pre-Build Complete ==="
  exit 0
fi
PROJ="$REPO/macos/M1K3.xcodeproj"
if [ -d "$PROJ" ]; then
  echo "--- M1K3.xcodeproj present ✓"
else
  echo "❌ M1K3.xcodeproj MISSING — xcodegen failed in post-clone; the build will have nothing to compile."
  exit 1
fi

# TestFlight's "What to Test" comes from macos/TestFlight/WhatToTest.<locale>.txt;
# only an archive uploads, and each platform gets its own notes.
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
  bash "$REPO/macos/ci_scripts/select_what_to_test.sh" "$REPO/macos/TestFlight" "${CI_PRODUCT_PLATFORM:-}"
fi

echo "=== Pre-Build Complete ==="
