#!/bin/bash
# release-mas.sh — build a Mac App Store .pkg for M1K3 (Apple Distribution +
# MAS entitlements + app-store-connect export). The direct .dmg path is
# release-macos.sh; this is the App Store channel.
#
# Differs from the direct build (release-macos.sh) in exactly three ways:
#   • signs with "Apple Distribution" (not Developer ID)
#   • CODE_SIGN_ENTITLEMENTS → M1K3-MAS.entitlements (no audioanalyticsd). This
#     now MATCHES project.yml's default (the default was inverted to MAS-safe on
#     2026-06-19 so no archive can leak the exception); the override is kept here
#     as belt-and-suspenders + self-documentation. release-macos.sh is the one
#     path that opts back INTO the full M1K3.entitlements.
#   • exports method=app-store-connect → a .pkg for App Store Connect upload
#
# Prereqs: a VALID "Apple Distribution: … (76DJH43A4P)" cert in the keychain,
# the Apple ID account configured in Xcode (for -allowProvisioningUpdates to
# register the App ID app.m1k3 + fetch a Mac App Store profile), and eventually
# an App Store Connect app record for the upload step (not needed to BUILD).
#
# bash 3.2-safe.
set -euo pipefail

SCHEME="M1K3"
APP_NAME="M1K3"
TEAM="76DJH43A4P"

HERE="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$HERE/../.." && pwd)"
PROJECT="$MACOS_DIR/M1K3.xcodeproj"
MAS_ENTITLEMENTS="$MACOS_DIR/M1K3App/M1K3-MAS.entitlements"
EXPORT_OPTS="$HERE/ExportOptions-MAS.plist"
BUILD="${BUILD_DIR:-/tmp/m1k3-mas}"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD/export"

VERSION="$(grep -m1 'MARKETING_VERSION:' "$MACOS_DIR/project.yml" | sed -E 's/.*"([^"]+)".*/\1/')"
# App Store Connect REQUIRES a build number strictly higher than any previously
# uploaded for this MARKETING_VERSION. project.yml pins CURRENT_PROJECT_VERSION=1
# (the direct-DMG path doesn't care), so an ASC upload MUST override it here.
# Pass BUILD_NUMBER=<n> in the env; the archive sets CURRENT_PROJECT_VERSION to it.
BUILD_NUMBER="${BUILD_NUMBER:-}"
beautify() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi; }

echo "▸ M1K3 Mac App Store build — v$VERSION build ${BUILD_NUMBER:-<project default>}  (team $TEAM)"
echo

# ── Toolchain guard ──────────────────────────────────────────────────────────
# MAS artifacts come off STABLE Xcode 26.x only — never a beta toolchain
# (ADR 0001; App Store submission additionally REQUIRES a GA SDK). Bump the
# "26" deliberately when moving to Xcode 27 GA.
XCODE_PATH="$(xcode-select -p)"
XCODE_MAJOR="$(xcodebuild -version | sed -nE 's/^Xcode ([0-9]+).*/\1/p')"
if [ "$XCODE_MAJOR" != "26" ] || echo "$XCODE_PATH" | grep -qi "beta"; then
  echo "✗ MAS builds require stable Xcode 26.x — found Xcode ${XCODE_MAJOR:-?} at $XCODE_PATH"
  echo "  Fix: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

# ── Preflight ────────────────────────────────────────────────────────────────
if ! security find-identity -v 2>/dev/null \
     | grep "Apple Distribution.*$TEAM" | grep -vq "EXPIRED"; then
  echo "✗ No VALID 'Apple Distribution' cert for $TEAM."
  echo "  Xcode → Settings → Accounts → Manage Certificates → ➕ Apple Distribution"
  exit 1
fi
echo "✓ Apple Distribution cert present"
[ -f "$MAS_ENTITLEMENTS" ] || { echo "✗ Missing $MAS_ENTITLEMENTS"; exit 1; }
if [ -z "$BUILD_NUMBER" ]; then
  echo "⚠ BUILD_NUMBER not set — archive will use CURRENT_PROJECT_VERSION from"
  echo "  project.yml (1). App Store Connect will REJECT it unless it's higher than"
  echo "  every prior upload for v$VERSION."
  # Don't sail past this: a warn-and-continue here costs a full archive + upload
  # before ASC rejects it server-side. Interactive → require an explicit y;
  # non-interactive (CI / piped) → hard-fail so an automated run can't waste an
  # upload on the default build number.
  if [ -t 0 ]; then
    printf "  Continue with the project default (1) anyway? [y/N] "
    read -r CONFIRM
    case "$CONFIRM" in
      y | Y) ;;
      *) echo "  Aborted. Re-run as: BUILD_NUMBER=<n> $0"; exit 1 ;;
    esac
  else
    echo "  Non-interactive shell — aborting. Re-run as: BUILD_NUMBER=<n> $0"
    exit 1
  fi
fi
echo

# ── 1. Archive (automatic signing + MAS entitlements) ────────────────────────
# DON'T override CODE_SIGN_IDENTITY: the project uses automatic signing, which
# manages the identity itself (and a manual override conflicts across every SPM
# dependency). The archive is dev-signed; the app-store-connect EXPORT below
# re-signs with Apple Distribution. Only the entitlements are overridden, so the
# embedded app carries the MAS set (no audioanalyticsd).
echo "▸ [1/4] Archiving (MAS entitlements, automatic signing)…"
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation \
  ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION="$BUILD_NUMBER"} \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_ENTITLEMENTS="$MAS_ENTITLEMENTS" | beautify

# ── 2. Export the .pkg (App Store Connect) ───────────────────────────────────
echo "▸ [2/4] Exporting (app-store-connect)…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates | beautify

PKG="$(ls "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1)"
[ -n "$PKG" ] || { echo "✗ Export produced no .pkg"; exit 1; }

# ── 3. Verify the package signature ──────────────────────────────────────────
echo "▸ [3/4] Verifying package…"
pkgutil --check-signature "$PKG" 2>&1 | head -6

# ── 4. Confirm the MAS entitlements made it into the embedded app ────────────
echo "▸ [4/4] Confirming MAS entitlements (no audioanalyticsd)…"
APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/$APP_NAME.app"
if codesign -d --entitlements - "$APP_IN_ARCHIVE" 2>/dev/null | grep -q audioanalyticsd; then
  echo "  ✗ audioanalyticsd entitlement present — MAS will REJECT this"
else
  echo "  ✓ no audioanalyticsd entitlement"
fi

echo
echo "✓ MAS package → $PKG  ($(du -h "$PKG" | cut -f1))"
echo "  Upload with: xcrun altool --upload-app -f \"$PKG\" -t macos \\"
echo "    --apple-id <id> --password <app-specific-pw>   (after the App Store Connect app record exists)"
