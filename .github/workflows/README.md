# M1K3 CI/CD

Lean pipeline that tests **what M1K3 actually ships**. Overhauled 2026-06-06:
the old Node/Playwright "unified test suite" (unified-tests, quick-tests,
release-testing, security-scanning) tested a web dashboard, was perpetually red,
and never covered the Swift Mac MVP — the active surface. It was removed.

## Workflows

| File | Purpose | Triggers |
|------|---------|----------|
| **`ci.yml`** | Tests. `swift-mac` runs `swift test` on the macOS MVP; `app-build` compiles the app shell; `scheme-drift` guards the test scheme. | push to `master`/`develop`, all PRs |
| **`security.yml`** | TruffleHog (verified secrets, repo-wide). | push to `master`/`develop`, all PRs |
| **`nightly-dmg.yml`** | Signed/notarized DMG → GitHub Release (skips until signing secrets are set). | nightly cron, manual |
| **`claude.yml`** | `@claude` assistant on issues/PRs. | `@claude` mentions |
| **`claude-code-review.yml`** | Auto Claude review of **Android/Kotlin** changes. | PRs touching `app/**/*.kt` |
| **`claude-code-review-mac.yml`** | Auto Claude review of **Swift/Mac** changes. | PRs touching `macos/**` |

## Notes & gotchas

- **`swift-mac` needs a runner with Xcode 26+** (the package targets
  `.macOS(.v26)` / swift-tools 6.2). `latest-stable` picks the newest Xcode on
  the image; pin a `macos-26` runner if the hosted image lags. MLX/Metal +
  WhisperKit integration tests are env-gated **off** (they only run from a
  bundled `.app`, never the CLI — see `macos/` project memory).
- **`attic.yml` left with the attic** (2026-08-13): the archived Python surface
  and its curated smoke subset + Bandit gate were cleared from the working
  tree. Git history before `7545b4a4` keeps the whole thing, workflow included.
- **Dropped CodeQL** (needed repo "Code Security" enabled + noisy here) and
  **npm-audit** (no real Node app — the stub `package.json` left with the attic).
