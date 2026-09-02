# M1K3 — macOS distribution

Three channels, one signed build foundation. Sequenced by what's unblocked.

## 1. Direct `.dmg` (Developer ID) — **ready now**

The invite-now / Homebrew-cask path. Works with the current entitlements, no
feature loss.

```bash
# one-time, per machine:
xcrun notarytool store-credentials "M1K3-notary" \
  --apple-id "you@round-tower.ie" --team-id 76DJH43A4P \
  --password "<app-specific-password from appleid.apple.com>"

# then, to cut a release:
macos/tools/release/release-macos.sh              # signed + notarized + stapled DMG
macos/tools/release/release-macos.sh --skip-notarize   # local test build (no Gatekeeper pass elsewhere)
```

Output: `/tmp/m1k3-release/M1K3-<version>.dmg` (drag-to-Applications layout).
Signing identity: **Developer ID Application: Round Tower Software Studios Ltd
(76DJH43A4P)** — already installed.

### Homebrew cask (after the first hosted DMG)
A cask formula points at the hosted `.dmg` URL + its sha256. Add once m1k3.app
serves the DMG; `brew install --cask m1k3` then tracks releases. (Formula TODO —
needs the public download URL first.)

## 2. Mac App Store — **entitlements cleared; needs an Apple Distribution cert**

MAS requires sandbox (✅ already on) and rejects two entitlements the *direct*
build ships:

```
com.apple.security.temporary-exception.mach-lookup.global-name → com.apple.audioanalyticsd
com.apple.security.exception.mach-lookup.global-name           → com.apple.audioanalyticsd
```

`M1K3App/M1K3-MAS.entitlements` is the same set **minus** those two.

**Tested 2026-06-14:** the system voice (AVSpeechSynthesizer) speaks fine with the
re-signed MAS entitlements — the audioanalyticsd exception was over-cautious (the
note that added it was confidence 0.6). So **no code change, no product compromise:
MAS keeps both voices** (system + Kokoro). The direct build keeps the exception
untouched (zero risk to the shipping DMG); only the MAS build drops it.

Remaining to ship on MAS (all phase-2, in order):
1. **Apple Distribution cert** — not yet in the keychain (only Developer ID is).
   Get it: Xcode → Settings → Accounts → Manage Certificates → ➕ Apple Distribution,
   or developer.apple.com → Certificates.
2. **Build config** — a MAS configuration that uses `M1K3-MAS.entitlements` + an
   `app-store-connect` export (`ExportOptions-MAS.plist`, ready). Wired + verified
   once the cert exists (can't sign a MAS archive without it).
3. **App Store Connect** — app record + listing. ASO lives here: title, subtitle,
   keyword field (NOT the bundle ID), screenshots, category. Then review.

Everything else (network client+server for the loopback MCP, mic, screen-recording
via TCC for calls) is MAS-compatible.

## 3. iOS + visionOS — **native, in-repo**

The Apple mobile/spatial surface is the native SwiftUI shell under
`../../M1K3iOSApp/` (`M1K3iOS` / `M1K3visionOS` targets), built on the SAME
`Sources/` package graph as the Mac app — NOT the KMP `app/` (that's the Android
effort). The on-device ladder is **Mini + Lil only** (Big is excluded on mobile;
`M1K3iOSApp/AppCore.swift`). Release path: the SAME Xcode Cloud `Release` workflow
as the Mac — a second Archive action (`M1K3iOS`, platform iOS) uploads into the one
universal `app.m1k3` record on every master merge (`../../docs/XCODE_CLOUD_RELEASE.md`
§3). No local script: Xcode Cloud signs and exports itself. The lane's
preconditions (universal bundle ID, privacy manifest, own Info.plist) are pinned
by `../ci/check_store_targets.py`. See `../../docs/IOS_VISIONOS_PORT.md`.

---
*Bundle/app ID is `app.m1k3` across platforms (reverse-DNS of m1k3.app) —
registered UNIVERSAL, so Mac + iOS + visionOS builds share one record (universal
purchase). It's invisible to users and immutable post-launch — ASO lives in the
store listing, never the ID. (The mobile targets briefly carried `.ios`/`.visionos`
suffixes until 2026-09-02; those had no record to upload into.)*
