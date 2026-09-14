# M1K3 macOS — distribution automation

Three tools, each doing only what it's best at (the prior knowledge-server's proven split):

| Job | Tool | Where |
|---|---|---|
| Build / sign / **notarize** (direct DMG + App Store .pkg) | **bash** | `../tools/release/release-macos.sh`, `release-mas.sh` |
| **Test + TestFlight + App Store binary** | **Xcode Cloud** | `../ci_scripts/` + a workflow in App Store Connect |
| **ASO: metadata + screenshots + TestFlight notes** | **Fastlane** (metadata-only) | this folder |
| PR tests | GitHub Actions | `../../.github/workflows/` (already there) |

## Fastlane (metadata-only)

```bash
cd macos
bundle install                      # one-time
bundle exec fastlane mac metadata       # push name/subtitle/keywords/description
bundle exec fastlane mac screenshots    # push screenshots_mac/
bundle exec fastlane mac deliver_all    # both
bundle exec fastlane mac beta_metadata  # update TestFlight "What to Test"
```

ASO copy is version-controlled in `metadata_mac/<locale>/` — eight languages:
en-US, de-DE, es-ES, fr-FR, ja, ko, pt-BR, zh-Hans. **The keyword field
(`keywords.txt`) is the real ASO lever** — edit it freely; it's invisible to
users and re-uploadable any time (unlike the bundle ID, which is neither).

### Riffing on the copy

1. Edit any `.txt` under `metadata_mac/<locale>/` (one field per file).
2. `python3 tools/ci/check_store_metadata.py` — Apple counts **characters**, not
   bytes: name/subtitle 30, keywords 100, promo text 170, description 4000.
   CI runs the same check on every PR.
3. `bundle exec fastlane mac metadata` pushes every locale in one go. Promo text
   goes live without a new build; everything else rides the next version.

What each file sets, and where:

- **Shared across Mac, iPhone and Vision Pro (app info):** `name.txt`,
  `subtitle.txt` and `privacy_url.txt`. A subtitle that says "on Mac" therefore
  shows on the iPhone store as well.
- **Mac storefront only:** `description.txt`, `keywords.txt`,
  `promotional_text.txt`, `support_url.txt` and `marketing_url.txt`. The iOS and
  visionOS versions keep their own copies in App Store Connect, and the en-US
  promo text is written differently for each platform on purpose.

Auth: an App Store Connect API key when one is present — the fastlane JSON
format (`key_id`, `issuer_id`, `key`) at `APP_STORE_CONNECT_API_KEY_PATH`, or at
`~/.appstoreconnect/private_keys/asc_api_key.json`. Otherwise `apple_id`
(Appfile) → interactive session login with 2FA. `deliver`'s precheck skips
in-app purchases (`precheck_include_in_app_purchases: false`): precheck cannot
read IAPs under an API key and aborts the upload.

This README is hand-written. The Fastfile sets `FASTLANE_SKIP_DOCS` so a lane
run no longer overwrites it with fastlane's generated lane list (which it did,
2026-09-12).

## Xcode Cloud

The `ci_scripts/` sit next to `M1K3.xcodeproj` so Xcode Cloud finds them.
`ci_post_clone.sh` runs **`xcodegen generate` first** — M1K3's pbxproj is
gitignored, so without it Xcode Cloud has no project to build (the one real
difference from the prior knowledge-server, which commits its pbxproj).

To turn it on: App Store Connect → your app → **Xcode Cloud** → create a workflow,
point it at this repo, scheme **M1K3**. Suggested:
- **Test** workflow on pull requests (runs the M1K3 suite).
- **Beta** workflow on `master`/tags → Archive → **TestFlight** (distributed natively).

Direct notarized DMGs are *not* an Xcode Cloud thing — those stay in
`tools/release/release-macos.sh` (run locally or from GitHub Actions on a tag).
