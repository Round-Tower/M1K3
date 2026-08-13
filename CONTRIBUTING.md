# Contributing to M1K3

Thanks for wanting to help build a private, local AI companion. This page gets
you from clone to green tests, and explains how we work.

## The lay of the land

| Surface | Where | Status |
|---|---|---|
| **macOS app** (the flagship) | [`macos/`](./macos) | Active — this is where contributions land |
| iOS + visionOS shell | [`macos/M1K3iOSApp/`](./macos/M1K3iOSApp) | Active — native SwiftUI on the shared `macos/Sources/` graph (`M1K3iOS`/`M1K3visionOS` targets). This is the Apple mobile/spatial path, **not** `app/`. |
| Python CLI / MCP (the origins) | git history before `7545b4a4` | Archived — cleared from the tree 2026-08-13 |
| 間 AI mobile (KMP) | [`app/`](./app) | Slow burn — the **Android** surface |

Build-from-source instructions for the Mac app live in
[`macos/README.md`](./macos/README.md).

## Ground rules

- **Tests first.** New behaviour comes with a test that fails without the
  change. The Swift suites use [swift-testing](https://developer.apple.com/documentation/testing)
  (`import Testing`, `@Test`) — not XCTest. `swift test --parallel` must be
  green before you open a PR.
- **Privacy is the product.** No telemetry, no analytics, no phoning home.
  Any new network call must be opt-in, visible, and documented. PRs that
  quietly send data anywhere will be declined regardless of how useful the
  feature is.
- **No user data in fixtures.** Test fixtures and eval cases must be synthetic.
- **Small, focused PRs** beat big-bang branches. If a change needs an
  architectural call, open an issue first and let's talk.

## Getting a PR merged

1. Fork, branch, make the change with tests.
2. Run the fast loop locally: `cd macos && swift test --parallel`.
3. If you touched anything under `macos/M1K3App/` (the app shell), also build
   it: `xcodegen generate && xcodebuild -scheme M1K3 -destination
   'platform=macOS' build CODE_SIGNING_ALLOWED=NO | xcbeautify`.
4. Open the PR. CI runs the package tests, an app-shell compile job, and an
   automated first-pass review — read what it says; it's usually right and
   occasionally wrong (feel free to push back with evidence).
5. A maintainer reviews and merges. Merges to `master` feed the TestFlight
   pipeline, so expect merge timing to follow release rhythm rather than
   review completion.

## Style

- Swift is formatted by **swiftformat** and linted by **swiftlint** (advisory).
  Match the code around you; comments explain *why*, not *what*.
- Commit messages follow the pattern in `git log`: `type(scope): what changed
  and why it matters`.

## Provenance (MurphySig)

This repo uses [MurphySig](https://murphysig.dev) — plain-language provenance
comments on significant files (`Signed: <author>, <date>, Confidence <0–1>`).
If you modify a signed file, read the signature first and add a review line
documenting your change. Don't invent signatures for files that lack them.
It's a lightweight convention, not a gate — see [`.murphysig`](./.murphysig).

## Licensing

M1K3 is [Apache-2.0](./LICENSE). By contributing you agree your contribution
is licensed the same way (inbound = outbound). No CLA.

## Questions

Open an issue, or say hi at kevin@round-tower.ie. Security reports go through
[SECURITY.md](./SECURITY.md) — never a public issue.
