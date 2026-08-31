# M1K3 for macOS — build from source

The flagship surface: a Mac-native SwiftUI app — on-device MLX inference, live
voice (Kokoro TTS + WhisperKit STT), a personal knowledge graph with RAG, an
embedded agent, a 3D companion, and a local MCP server other agents can call.

**Nothing leaves your Mac.** Models download once from Hugging Face; after
that it runs fully offline (web search is opt-in).

## Requirements

- **macOS 26 (Tahoe)** on **Apple Silicon** — hard requirement: the app uses
  Liquid Glass, on-device Foundation Models, and Metal via MLX.
- **Xcode 26.x** (Swift 6.2 toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and (optional, nicer logs)
  [xcbeautify](https://github.com/cpisciotta/xcbeautify):
  `brew install xcodegen xcbeautify`
- Disk: nothing to download for the default brain (Mini runs on Apple's
  on-device models). Allow ~2–7 GB extra only if you opt into the bigger
  Lil/Big brains.

## Build & run

```bash
git clone https://github.com/Round-Tower/M1K3.git
cd m1k3/macos

# project.yml is the source of truth — M1K3.xcodeproj is generated, not tracked
xcodegen generate

open M1K3.xcodeproj    # then ⌘R (set your own dev team for local signing)
```

Or from the command line:

```bash
xcodebuild -scheme M1K3 -destination 'platform=macOS' build | xcbeautify
# The same package graph also drives the iOS + visionOS shell (M1K3iOSApp/):
xcodebuild -scheme M1K3iOS       -destination 'generic/platform=iOS Simulator'      build | xcbeautify
xcodebuild -scheme M1K3visionOS  -destination 'generic/platform=visionOS Simulator' build | xcbeautify
```

First launch is one screen: say hello (a name is optional) and you're talking —
M1K3 starts on Mini, Apple's built-in on-device model, so there's nothing to
download. Sharper local brains (Lil / Big) are one click away in Settings, or
via the in-chat offer after your first answer; weights download only when you
ask.

> **Signing note:** run with your personal development team. Building with
> `CODE_SIGNING_ALLOWED=NO` compiles fine (CI does it) but the app then runs
> without its sandbox container and will read/write the wrong data locations.

## Tests

The business logic lives in SwiftPM packages and tests without Xcode:

```bash
swift test --parallel                 # the full fast suite (what CI runs)
swift test --filter M1K3KnowledgeTests
```

Tests use **swift-testing** (`import Testing`, `@Test`), not XCTest.

Heavy MLX/Metal integration tests are env-gated off by default —
`M1K3_MLX_INTEGRATION=1 swift test` opts in (downloads a real model and
generates; Apple Silicon only).

## Where things are

| | |
|---|---|
| `M1K3App/` | macOS app shell: SwiftUI views, `AppEnvironment`, settings |
| `M1K3iOSApp/` | iOS + visionOS SwiftUI shell (`M1K3iOS`/`M1K3visionOS` schemes) on the shared `Sources/` graph |
| `Sources/` | SwiftPM modules: agent, inference, knowledge/RAG, voice, MCP |
| `Tests/` | swift-testing suites per module |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is a build artifact) |
| `ROADMAP.md` | What's next — kept current |
| `PLAN.md` | Historical build log / decision record (append-only, signed) |
| `docs/` | ADRs, model choices, MCP setup, release pipeline |

## MCP server

The running app serves MCP over HTTP at `http://127.0.0.1:4242/mcp` —
knowledge search, documents, voice, and `ask_m1k3` (ask the resident AI).
See [`docs/MCP_SETUP.md`](./docs/MCP_SETUP.md) to wire it into Claude Code or
any MCP client.

## Contributing

See [`CONTRIBUTING.md`](../CONTRIBUTING.md) at the repo root. Found a bug?
In the app: **Settings → Report an issue…** generates a redacted diagnostic
you can attach to a [GitHub issue](https://github.com/Round-Tower/M1K3/issues).
