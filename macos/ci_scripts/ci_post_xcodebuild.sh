#!/bin/bash
# ci_post_xcodebuild.sh — Xcode Cloud post-build hook for M1K3 (macOS)
#
# Xcode Cloud distributes to TestFlight NATIVELY (configured in the workflow).
# A SwiftPM-only test run cannot load the bundled MLX metallib, however, so a
# successful archive is not yet release evidence. Mac archives run the app's
# headless SelfTest inside the archived bundle before Xcode Cloud can distribute
# it. iOS archives cannot run on the macOS builder; their device acceptance run
# is deliberately a separate, physical-device gate.
#
# Review: Kev + claude-opus-5, 2026-09-13 — run 349 failed "wrote no report": the
# archived app is sandboxed, so the smoke now runs an ad-hoc, unsandboxed COPY of
# it (the archive is untouched); the watchdog timer can no longer hold the hook
# open after a pass. Proven by running this script on run 349's own archive.
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
    if [ ! -x "$APP/Contents/MacOS/M1K3" ]; then
      echo "❌ MLX smoke: executable missing in $APP"
      exit 1
    fi

    # The archived app is SANDBOXED: its SelfTest can only write inside its own
    # container, which a shell may not read back (app-data privacy). Run 349
    # exited 0 with "wrote no report" for exactly this reason. So the smoke runs
    # a COPY of the archived bundle, ad-hoc re-signed with no sandbox — same
    # binary, same metallib — and the archive itself is never touched. NOT the
    # same weights path: unsandboxed, Application Support resolves outside the
    # container, so a fresh Xcode Cloud VM downloads the SelfTest models on the
    # first run (a sandboxed run on a fresh VM would have downloaded too). Proven
    # on run 349's own binary: every stage passed in 13 s — on a dev Mac whose
    # unsandboxed model cache was already warm, so expect a slower cloud run.
    SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/m1k3-smoke.XXXXXX")"
    cp -R "$APP" "$SMOKE_DIR/M1K3.app"
    cat > "$SMOKE_DIR/smoke.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.network.client</key><true/></dict></plist>
PLIST
    if ! codesign --force --deep --sign - --entitlements "$SMOKE_DIR/smoke.entitlements" \
      "$SMOKE_DIR/M1K3.app" >/dev/null 2>&1; then
      echo "❌ MLX smoke: could not ad-hoc re-sign the smoke copy"
      exit 1
    fi
    BIN="$SMOKE_DIR/M1K3.app/Contents/MacOS/M1K3"

    REPORT="$SMOKE_DIR/m1k3-selftest-${CI_BUILD_NUMBER:-archive}.log"
    rm -f "$REPORT"
    echo "--- Running required MLX archive smoke: $BIN"
    # SelfTest writes its own report because an app bundle does not inherit a
    # useful stdout/stderr stream in every Xcode Cloud execution context.
    M1K3_SELFTEST=1 M1K3_SELFTEST_TTFT=1 M1K3_SELFTEST_OUT="$REPORT" "$BIN" &
    SELFTEST_PID=$!
    # The watchdog's timer must not outlive a kill: a bare `sleep 900` survives
    # its killed subshell, keeps the hook's stdout open, and makes a GREEN smoke
    # hold the build for the full 15 minutes. The timer runs detached from the
    # output streams and the subshell kills it on TERM.
    (
      trap 'kill "$TIMER_PID" 2>/dev/null; exit 0' TERM
      sleep 900 </dev/null >/dev/null 2>&1 &
      TIMER_PID=$!
      wait "$TIMER_PID"
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
