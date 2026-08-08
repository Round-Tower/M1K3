#!/bin/bash
# release-macos.sh — build a signed, notarized, stapled M1K3.dmg for DIRECT
# distribution (outside the Mac App Store). Developer ID + notarytool + hdiutil.
#
# The Mac App Store is a SEPARATE pipeline (Apple Distribution cert,
# app-store-connect export, no audioanalyticsd mach-lookup exception — see
# the entitlements note). This script is the invite-now / Homebrew-cask path.
#
# ONE-TIME SETUP (per machine) — store a notary credential in the keychain:
#   xcrun notarytool store-credentials "M1K3-notary" \
#     --apple-id "you@round-tower.ie" --team-id 76DJH43A4P \
#     --password "<app-specific-password from appleid.apple.com>"
#
# Then: macos/tools/release/release-macos.sh [--skip-notarize]
#
# bash 3.2-safe (stock macOS). Fails fast; prints what it would sign with.
set -euo pipefail

SCHEME="M1K3"
APP_NAME="M1K3"
TEAM="76DJH43A4P"
NOTARY_PROFILE="M1K3-notary"

HERE="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$HERE/../.." && pwd)"          # …/macos
PROJECT="$MACOS_DIR/M1K3.xcodeproj"
EXPORT_OPTS="$HERE/ExportOptions.plist"
BUILD="${BUILD_DIR:-/tmp/m1k3-release}"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD/export"
APP="$EXPORT_DIR/$APP_NAME.app"

SKIP_NOTARIZE=0
[ "${1:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=1

# Version from project.yml (single source of truth).
VERSION="$(grep -m1 'MARKETING_VERSION:' "$MACOS_DIR/project.yml" | sed -E 's/.*"([^"]+)".*/\1/')"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

beautify() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi; }

echo "▸ M1K3 release — v$VERSION  (team $TEAM)"
echo

# ── Toolchain guard ──────────────────────────────────────────────────────────
# Release artifacts come off STABLE Xcode 26.x only — never a beta toolchain
# (ADR 0001: release signing/notarization stays pinned to stable). With
# Xcode-beta.app installed side-by-side, one stray xcode-select would otherwise
# silently make this DMG a beta build. Bump the "26" here deliberately at GA.
XCODE_PATH="$(xcode-select -p)"
XCODE_MAJOR="$(xcodebuild -version | sed -nE 's/^Xcode ([0-9]+).*/\1/p')"
if [ "$XCODE_MAJOR" != "26" ] || echo "$XCODE_PATH" | grep -qi "beta"; then
  echo "✗ Release builds require stable Xcode 26.x — found Xcode ${XCODE_MAJOR:-?} at $XCODE_PATH"
  echo "  Fix: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

# ── Preflight ────────────────────────────────────────────────────────────────
if ! security find-identity -p codesigning -v 2>/dev/null \
     | grep -q "Developer ID Application.*$TEAM"; then
  echo "✗ No 'Developer ID Application' cert for team $TEAM in the keychain."
  echo "  Get it from developer.apple.com → Certificates, or Xcode → Settings → Accounts → Manage Certificates."
  exit 1
fi
echo "✓ Developer ID Application cert present"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗ Notary profile '$NOTARY_PROFILE' not found. One-time setup:"
    echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "      --apple-id \"you@round-tower.ie\" --team-id $TEAM --password \"<app-specific-password>\""
    echo "  (or re-run with --skip-notarize to produce an unnotarized build for local testing)"
    exit 1
  fi
  echo "✓ Notary profile '$NOTARY_PROFILE' present"
fi
echo

# ── 1. Archive (Release, Developer ID, hardened runtime) ─────────────────────
# The project DEFAULT entitlements are the App-Store-safe set (M1K3-MAS, no
# audioanalyticsd). The DIRECT build explicitly opts back into the full set
# (M1K3.entitlements, with the audioanalyticsd mach-lookup exception for the
# AVSpeechSynthesizer system-voice path) — the one place that exception is
# allowed to ship. Keeps the DMG's runtime behaviour identical to before the
# default was inverted; only this archive carries the exception.
DIRECT_ENTITLEMENTS="$MACOS_DIR/M1K3App/M1K3.entitlements"
# Preflight: fail fast with a clear message if the entitlements file is missing
# (deleted/renamed), rather than a cryptic xcodebuild error mid-archive. Mirrors
# release-mas.sh's check on its MAS_ENTITLEMENTS.
[ -f "$DIRECT_ENTITLEMENTS" ] || { echo "✗ Missing $DIRECT_ENTITLEMENTS"; exit 1; }
# ── Signing style ─────────────────────────────────────────────────────────────
# Local machines carry an Apple Development cert, so the project's Automatic
# signing archives fine (dev-signs, then re-signs Developer ID at export). CI
# keychains carry ONLY the Developer ID Application identity — Automatic fails
# at archive ("No signing certificate 'Mac Development' found", nightly run
# 29027965918), so M1K3_SIGN_STYLE=manual archives directly with Developer ID
# (macOS Developer ID needs no provisioning profile; export re-signs as before).
# Local runs keep Automatic — set nothing.
SIGN_ARGS=()
if [ "${M1K3_SIGN_STYLE:-automatic}" = "manual" ]; then
  echo "▸ Manual signing (Developer ID Application) — single-identity keychain mode"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application")
fi

echo "▸ [1/6] Archiving…"
rm -rf "$ARCHIVE"
# ${arr[@]+...} guard: bash 3.2 + set -u treats an EMPTY array expansion as
# unbound — the guard expands to nothing instead of erroring.
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation \
  CODE_SIGN_ENTITLEMENTS="$DIRECT_ENTITLEMENTS" \
  DEVELOPMENT_TEAM="$TEAM" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} | beautify

# ── 2. Export the signed .app ────────────────────────────────────────────────
echo "▸ [2/6] Exporting (Developer ID)…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" | beautify
[ -d "$APP" ] || { echo "✗ Export produced no $APP_NAME.app"; exit 1; }

# ── 3. Notarize + staple the .app (offline first-launch) ─────────────────────
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  echo "▸ [3/6] Notarizing the app…"
  APP_ZIP="$BUILD/$APP_NAME-app.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$APP_ZIP"
else
  echo "▸ [3/6] Skipping notarize (--skip-notarize)"
fi

# ── 4. Build the DMG (drag-to-Applications layout) ───────────────────────────
echo "▸ [4/6] Packaging DMG…"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
echo "  → $DMG"

# ── 5. Sign + notarize + staple the DMG ──────────────────────────────────────
# Code-sign the DMG container itself (not just the app inside) with the same
# Developer ID, so `spctl --assess` passes on the .dmg and it can't be tampered
# with. Then notarize + staple the signed DMG.
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  echo "▸ [5/6] Signing + notarizing the DMG…"
  DEVID="$(security find-identity -p codesigning -v 2>/dev/null \
            | grep "Developer ID Application.*$TEAM" | head -1 \
            | sed -E 's/.*"(.*)".*/\1/')"
  codesign --force --sign "$DEVID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# ── 6. Verify ────────────────────────────────────────────────────────────────
echo "▸ [6/6] Verifying…"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1 || true
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  echo -n "  Gatekeeper (app): "; spctl -a -vv "$APP" 2>&1 | tail -1
  # Assert the DMG container itself is notarized-accepted (--type install), not
  # just the app inside it — this is the whole point of step 5's DMG signing.
  echo -n "  Gatekeeper (dmg): "; spctl -a -vv --type install "$DMG" 2>&1 | tail -1
  echo -n "  Staple (dmg):     "; xcrun stapler validate "$DMG" 2>&1 | tail -1
fi
echo
echo "✓ Done → $DMG  ($(du -h "$DMG" | cut -f1))"
# NB: if/fi, not `[ … ] && echo` — as the script's last line the latter returns
# the test's exit status (1 when notarizing), failing the script on SUCCESS and
# false-failing the nightly-dmg CI step.
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  echo "  ⚠ Unnotarized — for local testing only; Gatekeeper will block it on other Macs."
fi
