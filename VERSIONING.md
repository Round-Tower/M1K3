# Versioning

One user-facing version per release, shared across every surface. `1.0.0` is
the store debut.

## The scheme

**Semantic versioning, three components: `MAJOR.MINOR.PATCH`.**

- **MAJOR** — a new era of the product (the store launch is 1).
- **MINOR** — features (new senses, new brains, new surfaces).
- **PATCH** — fixes.

A release bumps the version **everywhere in one commit** (the three files
below), so no surface can drift.

## Where each platform reads it

| Surface | Source of truth | Build number |
|---|---|---|
| macOS (TestFlight / MAS / nightly DMG) | `macos/project.yml` → `MARKETING_VERSION` | **Xcode Cloud auto-managed** — increments per cloud build, no repo commit. The repo's `CURRENT_PROJECT_VERSION: "1"` only feeds local/nightly builds, which never ship to a store. |
| Android (Play) | `app/composeApp/build.gradle.kts` → `versionName` | `versionCode = MAJOR×10000 + MINOR×100 + PATCH` (so `1.0.0` → `10000`, `1.2.3` → `10203`). Monotonic and derivable — never hand-pick an unrelated integer. |
| Desktop (Compose, unshipped) | `app/composeApp/build.gradle.kts` → `packageVersion` | — |

The App Store Connect **version string must match `MARKETING_VERSION`
exactly** when creating/submitting a store version (the current draft record
should read `1.0.0`).

## Release checklist (versioning part)

1. Pick the new version by the scheme above.
2. Update `MARKETING_VERSION`, `versionName`, and `versionCode` (derived) in
   one commit: `chore(release): v<X.Y.Z>`.
3. Merge to `master` → Xcode Cloud archives with the new version and mints the
   build number itself.
4. Android: build the AAB from the same commit; Play rejects a reused
   `versionCode`, which is the guard the scheme exists to satisfy.

<!--
Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.9 (the Mac half is the
already-live Xcode Cloud behaviour, written down; the Android scheme is the
standard derivable-versionCode pattern, chosen ahead of the first Play upload
so there is no legacy integer to migrate around). Prior: none (new file).
-->
