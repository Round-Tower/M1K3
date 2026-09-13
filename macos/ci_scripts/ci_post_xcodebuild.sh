#!/bin/bash
# ci_post_xcodebuild.sh — Xcode Cloud post-build hook for M1K3 (macOS)
#
# Xcode Cloud distributes to TestFlight NATIVELY (configured in the workflow).
# A SwiftPM-only test run cannot load the bundled MLX metallib, however, so a
# successful archive is not yet release evidence. Mac archives run the app's
# headless SelfTest inside the archived bundle before Xcode Cloud can distribute
# it. iOS archives cannot run on the macOS builder; their device acceptance run
# is deliberately a separate, physical-device gate.
set -euo pipefail

echo "=== M1K3 CI: Post-Build ==="
echo "CI_XCODEBUILD_ACTION:    ${CI_XCODEBUILD_ACTION:-unknown}"
echo "CI_XCODEBUILD_EXIT_CODE: ${CI_XCODEBUILD_EXIT_CODE:-unknown}"

if [ "${CI_XCODEBUILD_EXIT_CODE:-1}" = "0" ]; then
  echo "✅ Build/Test succeeded"
else
  echo "❌ Build/Test failed (exit ${CI_XCODEBUILD_EXIT_CODE:-unknown})"
  exit 1
fi

# The hook also runs after non-archive actions. Only the Mac archive has a
# runnable .app; scheme check avoids accidentally trying to execute an iOS app
# on the builder. The explicit M1K3_RELEASE_MLX_SMOKE=0 escape hatch is for
# incident recovery only and leaves an auditable warning in the build log.
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] \
  && [ "${CI_XCODE_SCHEME:-M1K3}" = "M1K3" ]; then
  if [ "${M1K3_RELEASE_MLX_SMOKE:-1}" = "0" ]; then
    echo "⚠️ M1K3_RELEASE_MLX_SMOKE=0 — MLX archive smoke bypassed"
  else
    ARCHIVE_ROOT="${CI_ARCHIVE_PATH:-${CI_AD_HOC_SIGNED_APP_PATH:-}}"
    if [ -z "$ARCHIVE_ROOT" ]; then
      echo "❌ MLX smoke: no CI_ARCHIVE_PATH or CI_AD_HOC_SIGNED_APP_PATH"
      exit 1
    fi
    APP="$(find "$ARCHIVE_ROOT" -maxdepth 5 -type d -name 'M1K3.app' -print -quit)"
    if [ -z "$APP" ]; then
      echo "❌ MLX smoke: M1K3.app not found under $ARCHIVE_ROOT"
      exit 1
    fi
    BIN="$APP/Contents/MacOS/M1K3"
    if [ ! -x "$BIN" ]; then
      echo "❌ MLX smoke: executable missing at $BIN"
      exit 1
    fi

    REPORT="${CI_DERIVED_DATA_PATH:-/tmp}/m1k3-selftest-${CI_BUILD_NUMBER:-archive}.log"
    rm -f "$REPORT"
    echo "--- Running required MLX archive smoke: $BIN"
    # SelfTest writes its own report because an app bundle does not inherit a
    # useful stdout/stderr stream in every Xcode Cloud execution context.
    M1K3_SELFTEST=1 M1K3_SELFTEST_TTFT=1 M1K3_SELFTEST_OUT="$REPORT" "$BIN" &
    SELFTEST_PID=$!
    (
      sleep 900
      if kill -0 "$SELFTEST_PID" 2>/dev/null; then
        echo "❌ MLX smoke timed out after 900 seconds" >&2
        kill "$SELFTEST_PID" 2>/dev/null || true
      fi
    ) &
    WATCHDOG_PID=$!
    if ! wait "$SELFTEST_PID"; then
      kill "$WATCHDOG_PID" 2>/dev/null || true
      wait "$WATCHDOG_PID" 2>/dev/null || true
      echo "❌ MLX smoke process failed"
      exit 1
    fi
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true

    if [ ! -s "$REPORT" ]; then
      echo "❌ MLX smoke wrote no report: $REPORT"
      exit 1
    fi
    cat "$REPORT"
    # SelfTest continues after an individual stage failure so its report is
    # diagnostic. The release gate must be stricter: both Metal embedding and
    # generation must pass, and no stage may report an explicit failure.
    if grep -q '^✗ ' "$REPORT" \
      || ! grep -q '^✓ MLX Qwen3-Embedding embed:' "$REPORT" \
      || ! grep -q '^✓ MLX generate:' "$REPORT"; then
      echo "❌ MLX archive smoke failed — blocking TestFlight distribution"
      exit 1
    fi
    echo "✅ Required MLX archive smoke passed"
  fi
fi

echo "=== Post-Build Complete ==="
