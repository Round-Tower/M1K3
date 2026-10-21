#!/bin/bash
# release-local.sh <build> — the store release when Xcode Cloud can't build it: the Mac
# .pkg (release-mas.sh), the archive's MLX smoke (ci_post_xcodebuild.sh), and the iOS .ipa,
# all at build number <build>, from this checkout's HEAD. Uploading is upload-local.zsh
# (Kev's, via `!`: the classifier reads altool --upload-app as a production deploy).
#
#   macos/tools/release/release-local.sh 540
#   → /tmp/m1k3-local-540/{mac,ios}/  then the three lines it prints
#
# Why: Xcode Cloud ran out of compute on 2026-10-15 and 537, 538 and 539 each shipped from a
# hand-typed iOS archive, a scratchpad upload script and a scratchpad What to Test script.
# The build number: reuse the CANCELED cloud run's number (it is above every upload and the
# next cloud run takes the one after). An approved version's train is closed: bump
# MARKETING_VERSION first, or altool refuses the upload.
#
# Signed: Kev + claude-opus-5.5, 2026-10-21
# Context: the 537–539 local route, written down once. Archives arm64 like release-mas.sh.
# Confidence: 0.8 — every step ran by hand three times; this wrapper's first run is the next release.
# Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
#
# bash 3.2-safe.
set -euo pipefail

BUILD_NUMBER="${1:?usage: release-local.sh <build number>}"
case "$BUILD_NUMBER" in *[!0-9]*) echo "✗ build number must be digits: $BUILD_NUMBER"; exit 1 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-/tmp/m1k3-local-$BUILD_NUMBER}"
beautify() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --quiet; else cat; fi; }

# A fresh derived dir resolves packages through git; the global fsmonitor daemon holds
# SwiftPM's pipe and the build sits at "Resolve Package Graph" forever (2026-10-19).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false

[ -z "$(git -C "$MACOS_DIR" status --porcelain -- . ':!*.xcodeproj')" ] || {
  echo "✗ uncommitted changes under macos/: a store build comes from a commit"; exit 1; }
echo "▸ M1K3 local release — build $BUILD_NUMBER from $(git -C "$MACOS_DIR" rev-parse --short HEAD) → $OUT"
command -v xcodegen >/dev/null || { echo "✗ xcodegen not installed (brew install xcodegen)"; exit 1; }
(cd "$MACOS_DIR" && xcodegen generate --quiet)

# ── Mac: archive + export + the helper checks (release-mas.sh), then the MLX smoke ──
BUILD_DIR="$OUT/mac" BUILD_NUMBER="$BUILD_NUMBER" "$HERE/release-mas.sh"
CI_XCODEBUILD_EXIT_CODE=0 CI_XCODEBUILD_ACTION=archive CI_ARCHIVE_PATH="$OUT/mac/M1K3.xcarchive" \
  bash "$MACOS_DIR/ci_scripts/ci_post_xcodebuild.sh"

# ── iOS: archive + export (the same app-store-connect options make an .ipa here) ──
echo "▸ iOS archive…"
rm -rf "$OUT/ios"
xcodebuild archive -project "$MACOS_DIR/M1K3.xcodeproj" -scheme M1K3iOS \
  -destination 'generic/platform=iOS' -archivePath "$OUT/ios/M1K3iOS.xcarchive" \
  -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" | beautify
xcodebuild -exportArchive -archivePath "$OUT/ios/M1K3iOS.xcarchive" -exportPath "$OUT/ios/export" \
  -exportOptionsPlist "$HERE/ExportOptions-MAS.plist" -allowProvisioningUpdates | beautify

# ── The artifacts must say what we think they say (an exit code is not a build) ──
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
MAC_INFO="$OUT/mac/M1K3.xcarchive/Products/Applications/M1K3.app/Contents/Info.plist"
# project.yml names the iOS product M1K3 too, so the archive holds M1K3.app.
IOS_INFO="$OUT/ios/M1K3iOS.xcarchive/Products/Applications/M1K3.app/Info.plist"
for info in "$MAC_INFO" "$IOS_INFO"; do
  [ -f "$info" ] || { echo "✗ no $info"; exit 1; }
  got="$(plist "$info" CFBundleVersion)"
  [ "$got" = "$BUILD_NUMBER" ] || { echo "✗ $info is build $got, not $BUILD_NUMBER"; exit 1; }
done
for art in "$OUT"/mac/export/*.pkg "$OUT"/ios/export/*.ipa; do
  [ -f "$art" ] || { echo "✗ export missing: $art"; exit 1; }
done
echo
echo "✓ $(plist "$MAC_INFO" CFBundleShortVersionString) ($BUILD_NUMBER): $(ls "$OUT"/mac/export/*.pkg) · $(ls "$OUT"/ios/export/*.ipa)"
echo "  Next (Kev, via !):  $HERE/upload-local.zsh $OUT"
echo "  Then, once both are VALID (tools/asc/builds.py):"
echo "    $MACOS_DIR/tools/asc/testflight.py notes --build $BUILD_NUMBER --confirm"
echo "  Archives (dSYMs) to keep: mv $OUT/{mac,ios}/*.xcarchive ~/Library/Developer/Xcode/Archives/\$(date +%F)/"
