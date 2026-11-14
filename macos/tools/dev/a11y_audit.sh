#!/bin/zsh
# M1K3 — accessibility audit (Xcode's `performAccessibilityAudit` on the live screens).
#
#   tools/dev/a11y_audit.sh mac [screen ...]
#   tools/dev/a11y_audit.sh ios <simulator-or-device-udid> [--largest-text] [screen ...]
#
# Runs the audit UI tests (UITests/Screengrab*/AccessibilityAudit*) against the
# app launched under M1K3_SCREENGRAB=1 — the ISOLATED store root and the demo
# persona, never your data — and prints one combined report: every issue Xcode
# raised, by screen. Screens to pass: onboarding, chat, documents, memories,
# settings-brain-at-home, settings-privacy, voice (none = all). A report is named
# for the plate whose launch recipe reached the screen (settings-privacy → privacy-label).
#
# Mac: quit the live M1K3 app first (same bundle id: the MCP port and the
# single-instance guard collide) and leave the Mac alone for the run. The audit
# measures contrast off the screen, so M1K3 has to stay in front.
#
# iOS: `--largest-text` sets the Simulator to the largest accessibility text
# size for the run and puts it back after — the pass that speaks to the store's
# Larger Text label. A Simulator cannot run the MLX brains, so screens that sit
# behind one come back NOT REACHED there; a physical device reaches them all.
#
# What this does NOT prove: that VoiceOver or Voice Control lets someone finish
# a task. That is a hand run, and no store accessibility label is claimed without it.
#
# Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.55 (the iOS suite ran on a Simulator
# by a bare xcodebuild and the collector filed its reports; THIS script and the Mac lane are
# unrun, and --largest-text is untried — verify-by-launch), Prior: Unknown
# Review: Kev + claude-fable-5.2, 2026-11-14 — the Mac lane ends with a11y_contrast.py: each contrast
# finding measured on the screen's picture (the first run's 31 were 18 false, 11 real, 2 off-picture).
# `M1K3_A11Y_APPEARANCE=light|dark` pins the Mac app's appearance for the run, so both get measured.
# Review: Kev + claude-fable-5.2, 2026-11-14 — the contrast step runs for the phone too. On a real device the
# picture is the app's window on the owner's phone: turn on a Focus first, or a banner lands in the attachment.
set -euo pipefail

target=${1:?mac|ios}; shift
root=${0:A:h:h:h}                       # macos/
scratch=${TMPDIR:-/tmp}/m1k3-a11y
dd=${M1K3_A11Y_DD:-$scratch/dd-$target}   # reuse a warm DerivedData if you have one
xcresult=$scratch/$target.xcresult
out=$scratch/report-$target
mkdir -p "$scratch"; rm -rf "$xcresult" "$out"; mkdir -p "$out"

largest=0
case $target in
  mac)
    scheme=M1K3; testTarget=M1K3ScreengrabUITests; className=AccessibilityAuditUITests; dest='platform=macOS'
    if pgrep -x M1K3 >/dev/null; then
      echo "quit the live M1K3 app first (pgrep -x M1K3): the audit launches its own, and the two collide"; exit 2
    fi
    ;;
  ios)
    udid=${1:?simulator or device udid}; shift
    if [[ ${1:-} == --largest-text ]]; then largest=1; shift; fi
    scheme=M1K3iOS; testTarget=M1K3iOSScreengrabUITests; className=AccessibilityAuditiOSUITests; dest="id=$udid"
    ;;
  *) echo "target must be mac or ios"; exit 2 ;;
esac

# Screen names → test methods (kebab → CamelCase: settings-privacy → testSettingsPrivacy).
only=()
for screen in "$@"; do
  method=test$(print -r -- "$screen" | perl -pe 's/(^|-)(\w)/\U$2/g')
  only+=(-only-testing:"$testTarget/$className/$method")
done
(( ${#only} )) || only=(-only-testing:"$testTarget/$className")

restore_text() { xcrun simctl ui "$udid" content_size "$previous" >/dev/null 2>&1 || true }
if (( largest )); then
  xcrun simctl bootstatus "$udid" -b >/dev/null
  previous=$(xcrun simctl ui "$udid" content_size)
  xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
  trap restore_text EXIT INT TERM   # an aborted run must not leave the Simulator at the largest size
  echo ">>> text size: accessibility-extra-extra-extra-large (was $previous)"
fi

cd "$root"
xcodegen generate >/dev/null
set +e
xcodebuild test -project M1K3.xcodeproj -scheme "$scheme" -destination "$dest" \
  -derivedDataPath "$dd" -resultBundlePath "$xcresult" \
  -skipPackagePluginValidation -skipMacroValidation \
  "${only[@]}" \
  TEST_RUNNER_M1K3_A11Y_OUT="$([[ $target == mac ]] && print -r -- "$out")" \
  TEST_RUNNER_M1K3_SCREENGRAB_RUN="$(date +%s)" \
  TEST_RUNNER_M1K3_A11Y_APPEARANCE="${M1K3_A11Y_APPEARANCE:-}" \
  2>&1 | xcbeautify --quiet
rc=$pipestatus[1]
set -e

# The reports are attachments named a11y-<screen> (the Mac lane also wrote them directly).
if [[ -d $xcresult ]]; then
  export_dir=$scratch/attachments-$target
  rm -rf "$export_dir"; mkdir -p "$export_dir"
  xcrun xcresulttool export attachments --path "$xcresult" --output-path "$export_dir" >/dev/null 2>&1 || true
  if [[ -f $export_dir/manifest.json ]]; then
    python3 "$root/tools/dev/a11y_collect.py" "$export_dir" "$out" || echo "warn: could not file the reports from the xcresult"
  fi
fi

echo
echo "=== accessibility audit · $target$( (( largest )) && echo ' · largest text') ==="
found=0
for report in "$out"/*.txt(N); do
  found=1
  echo; echo "--- ${report:t:r}"; cat "$report"
done
if (( ! found )); then
  echo "no report was written — no screen was audited (xcodebuild exit=$rc)"
  (( rc )) || rc=3   # nothing audited is never a pass, whatever xcodebuild said
fi
if (( found )); then
  # Xcode's audit gives no number: re-measure each contrast finding on the screen's own picture.
  echo; echo "=== contrast, measured (4.5:1 is the bar) ==="
  "$root/tools/dev/a11y_contrast.py" "$out" || true
fi
echo
echo "xcodebuild test exit=$rc · reports in $out"
exit $rc
