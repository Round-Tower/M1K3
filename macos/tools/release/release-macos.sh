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
# Release artifacts come off STABLE Xcode 27.x only — never a beta toolchain
# (ADR 0001: release signing/notarization stays pinned to stable). With
# Xcode-beta.app installed side-by-side, one stray xcode-select would otherwise
# silently make this DMG a beta build. Bumped 26 → 27 on 2026-09-15 (Xcode 27.0
# GA, 27A266a, is the installed toolchain); bump again deliberately at the next GA.
XCODE_PATH="$(xcode-select -p)"
XCODE_MAJOR="$(xcodebuild -version | sed -nE 's/^Xcode ([0-9]+).*/\1/p')"
if [ "$XCODE_MAJOR" != "27" ] || echo "$XCODE_PATH" | grep -qi "beta"; then
  echo "✗ Release builds require stable Xcode 27.x — found Xcode ${XCODE_MAJOR:-?} at $XCODE_PATH"
  echo "  Fix: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

# A release must name an immutable source revision. Archiving a tree with local
# edits makes the DMG impossible to reproduce from its advertised commit and is
# particularly easy to do while iterating on App Store screenshots. The nightly
# workflow checks out a clean SHA by construction; this protects the manual
# Developer-ID lane. Incident recovery may opt out explicitly, leaving a loud
# breadcrumb in the terminal and CI log.
REPO_ROOT="$(cd "$MACOS_DIR/.." && pwd)"
GIT_BIN="/usr/bin/git"
[ -x "$GIT_BIN" ] || { echo "✗ System git not available at $GIT_BIN"; exit 1; }
if ! GIT_STATUS="$("$GIT_BIN" -C "$REPO_ROOT" status --porcelain --untracked-files=no)"; then
  echo "✗ Could not determine worktree status — refusing to archive."
  exit 1
fi
if [ "${M1K3_ALLOW_DIRTY_RELEASE:-0}" != "1" ] && [ -n "$GIT_STATUS" ]; then
  echo "✗ Refusing to archive a dirty worktree. Commit or stash the tracked changes first."
  echo "  Emergency override only: M1K3_ALLOW_DIRTY_RELEASE=1 $0"
  "$GIT_BIN" -C "$REPO_ROOT" status --short
  exit 1
fi
if [ "${M1K3_ALLOW_DIRTY_RELEASE:-0}" = "1" ]; then
  echo "⚠️ M1K3_ALLOW_DIRTY_RELEASE=1 — archive is NOT reproducible from HEAD"
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
# The embedded `m1k3` CLI has its own pair. Its project DEFAULT is the sandboxed
# set; the DMG's copy must be unsandboxed or `m1k3 connect cursor` can't write
# ~/.cursor/mcp.json and `m1k3 connect claude` can't exec the claude binary.
#
# ⚠️ These are passed as the two per-target VARIABLES the project indirects
# through (M1K3_APP_ENTITLEMENTS / M1K3_CLI_ENTITLEMENTS), never as a global
# CODE_SIGN_ENTITLEMENTS: an xcodebuild setting on the command line applies to
# EVERY target, so the old global override would now stamp the app's
# entitlements — sandbox, mic, calendars, the audioanalyticsd exception — onto
# a command-line helper that needs none of them.
CLI_ENTITLEMENTS="$MACOS_DIR/M1K3CLI/m1k3-direct.entitlements"
# Preflight: fail fast with a clear message if either entitlements file is
# missing (deleted/renamed), rather than a cryptic xcodebuild error mid-archive.
# Mirrors release-mas.sh's check on its MAS_ENTITLEMENTS.
[ -f "$DIRECT_ENTITLEMENTS" ] || { echo "✗ Missing $DIRECT_ENTITLEMENTS"; exit 1; }
[ -f "$CLI_ENTITLEMENTS" ] || { echo "✗ Missing $CLI_ENTITLEMENTS"; exit 1; }
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
  M1K3_APP_ENTITLEMENTS="$DIRECT_ENTITLEMENTS" \
  M1K3_CLI_ENTITLEMENTS="$CLI_ENTITLEMENTS" \
  DEVELOPMENT_TEAM="$TEAM" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} | beautify

# ── 2. Export the signed .app ────────────────────────────────────────────────
echo "▸ [2/6] Exporting (Developer ID)…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" | beautify
[ -d "$APP" ] || { echo "✗ Export produced no $APP_NAME.app"; exit 1; }

# ── 2b. The embedded CLI must NOT be sandboxed on this channel ───────────────
# `m1k3 connect cursor` writes ~/.cursor/mcp.json and `m1k3 connect claude`
# execs the claude binary; a sandboxed helper can do neither, and would write
# into its own container while reporting success. This is the one place that
# mistake is catchable — the entitlements come from a build VARIABLE, so a
# typo in M1K3_CLI_ENTITLEMENTS fails silently at runtime, months later.
CLI_BIN="$APP/Contents/Helpers/m1k3"
[ -f "$CLI_BIN" ] || { echo "✗ No m1k3 helper in $APP_NAME.app"; exit 1; }
# FAIL-CLOSED. A bare `… | grep -q app-sandbox` reads an EMPTY pipeline as
# "not sandboxed" — so the one mistake this check exists to catch would sail
# through on any Xcode where the flags or the timing differ. Capture first,
# demand a real plist, then judge. Verified on this Xcode (2026-09-11): a
# helper signed with the EMPTY direct entitlements still prints
# `<plist version="1.0"><dict/></plist>`, so `<plist` is a sound liveness
# token; an unsigned binary prints nothing at all.
CLI_ENT="$(codesign -d --entitlements - --xml "$CLI_BIN" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)"
case "$CLI_ENT" in
  *"<plist"*) ;;
  *)
    echo "✗ Entitlements could not be READ from $CLI_BIN — refusing to guess."
    echo "  (codesign -d --entitlements - --xml | plutil -convert xml1 produced no plist.)"
    exit 1 ;;
esac
case "$CLI_ENT" in
  *com.apple.security.app-sandbox*)
    echo "✗ The embedded m1k3 helper is SANDBOXED — the DMG build must use"
    echo "  M1K3CLI/m1k3-direct.entitlements (check M1K3_CLI_ENTITLEMENTS above)."
    exit 1 ;;
esac
echo "✓ m1k3 helper is unsandboxed (direct-distribution entitlements)"

# ── The helper must actually RUN ─────────────────────────────────────────────
# Entitlements being right proves nothing about launching. A sandboxed tool with
# no `__TEXT,__info_plist` section has no bundle id for the sandbox to build a
# container from, and libsystem_secinit traps before main(): exit 133, zero
# bytes out. Build 362, in App Review for 1.0.0, carried exactly that (found 2026-09-18) while
# the check above passed. So: the section must be there, and `--help` — which
# touches no network and no file — must answer. Same check on both channels.
# Captured first, THEN grepped: under `set -o pipefail` a live `otool | grep -q`
# can fail on a MATCH — grep -q exits at the first hit, otool takes SIGPIPE (141)
# on its next write, and pipefail reports that instead of grep's 0.
CLI_LOAD_COMMANDS="$(otool -l "$CLI_BIN")"
grep -q __info_plist <<<"$CLI_LOAD_COMMANDS" || {
  echo "✗ The m1k3 helper has no __TEXT,__info_plist section — a sandboxed copy traps at launch."
  echo "  (project.yml: GENERATE_INFOPLIST_FILE + CREATE_INFOPLIST_SECTION_IN_BINARY on M1K3CLI.)"
  exit 1
}
CLI_HELP_RC=0
CLI_HELP="$("$CLI_BIN" --help 2>/dev/null)" || CLI_HELP_RC=$?
if [ "$CLI_HELP_RC" -ne 0 ] || [ -z "$CLI_HELP" ]; then
  echo "✗ The m1k3 helper does not run: \`m1k3 --help\` exited $CLI_HELP_RC with ${#CLI_HELP} bytes of output."
  echo "  (133 = trace trap in sandbox init; see the comment above.)"
  exit 1
fi
echo "✓ m1k3 helper launches (--help answered)"

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
# `hdiutil create` fails "Resource busy" now and then on GitHub's macOS runners
# (a system daemon still holds the fresh image) — the 2026-09-24 nightly died
# here after a clean build, export and notarize. Retry with a short back-off
# before calling it a failure; the `until` condition keeps `set -e` out of it.
DMG_ATTEMPTS=5
dmg_attempt=1
until hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG" >/dev/null; do
  if [ "$dmg_attempt" -ge "$DMG_ATTEMPTS" ]; then
    echo "✗ hdiutil create failed $DMG_ATTEMPTS times" >&2
    exit 1
  fi
  echo "  hdiutil create failed (attempt $dmg_attempt/$DMG_ATTEMPTS); retrying in $((dmg_attempt * 5)) s" >&2
  # "Resource busy" is usually the create's own temporary image failing to
  # detach — force it loose and drop any partial image, or the next attempt
  # can fail the same way for the same reason (best effort: never fatal).
  hdiutil detach "/Volumes/$APP_NAME $VERSION" -force >/dev/null 2>&1 || true
  rm -f "$DMG"
  sleep $((dmg_attempt * 5))
  dmg_attempt=$((dmg_attempt + 1))
done
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
