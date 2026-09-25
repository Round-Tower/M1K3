# CLAUDE.md — macos/

Guidance for Claude Code under `macos/`, the **live product**: M1K3, private on-device AI
with live voice, a knowledge graph, document memory, an embedded agent, call transcription,
a 3D avatar and an MCP server. The **macOS 26** app (`M1K3App/`, Swift 6.2, Liquid Glass +
on-device Foundation Models) is the primary shipping surface; the same `Sources/` package
graph drives the iOS 26 / visionOS 26 shell in `M1K3iOSApp/` (`M1K3iOS` / `M1K3visionOS`
targets in `project.yml`). `../app/` is the separate KMP Android effort.

Read on demand, not up front: `docs/MODULE_MAP.md` (every package target and its role;
the doc-drift CI job pins it to `Package.swift`), `ROADMAP.md` (what's next, kept live),
`PLAN.md` (the signed build log — append, never rewrite), `../.claude/project-memory.md`
(the session chronicle — its last block, only when continuing a thread).

## Build & test

```bash
swift test --parallel                        # what CI runs; swift-testing, not XCTest
swift test --filter BrainCatalogueTests      # one suite ("Suite/test" for one test)
swift build -c release --product M1K3MCP     # the stdio MCP server binary
xcodegen generate                            # project.yml is the source of truth; M1K3.xcodeproj is a gitignored artifact
xcodebuild -scheme M1K3 -destination 'platform=macOS' -skipPackagePluginValidation build | xcbeautify
```

- **CI** (`../.github/workflows/ci.yml`, `macos-26` runner, `M1K3_MLX_INTEGRATION=0`):
  `swift test --parallel` gates every compilable PR; the App-shell and iOS+visionOS
  xcodebuild jobs run on a PR only when the diff touches what they compile, and on every
  Swift-touching push to master/develop (a docs- or tools-only push skips them). Python under `tools/` is tested by the guards job, not the
  Swift job. **Pushing to `master` starts Xcode Cloud → TestFlight** — the one `Release`
  workflow archives `M1K3` + `M1K3iOS` into the single `app.m1k3` store record, so a master
  push is a release action; `tools/ci/check_store_targets.py` pins the bundle-ID /
  privacy-manifest / Info.plist invariants it depends on.
- **No short wall-clock bounds in tests.** Swift Testing starts every test at once; on the
  3-core runner wall time is mostly pool wait. Separate the two outcomes by ≥ 30 s or
  assert which side acted (`tools/ci/check_wall_clock_bounds.py` enforces it).
- **Landing:** `tools/ci/land.sh <PR> [--passes N]` gates on `tools/ci/pr_watch.py`, whose
  rules are pinned in `test_pr_watch.py`; the size-tiered loop is in `../CLAUDE.md`. Master
  has no required status checks — that rule is the gate. Verify a merge by `state` +
  `mergedAt`, never by an exit code.

## The metallib wall

`swift test` cannot run MLX/Metal — the metallib resolves only inside a built `.app`. So
MLX / WhisperKit / Kokoro code is verified two ways: unit tests on the pure policy layers
against fakes (`M1K3_MLX_INTEGRATION=1` and `M1K3_AUDIO_INTEGRATION=1` switch on the heavy
and the speaker-playing suites — locally, never in CI; the audio one is the SYSTEM voice,
Kokoro is MLX/Metal and cannot run under `swift test` at all), and **`SelfTest.swift`** in
`M1K3App/`, the headless on-device harness: drop a `.m1k3-selftest.json` in
`~/Library/Containers/app.m1k3/Data/` keyed by env-var name (`M1K3_SELFTEST=1`, `_MODEL`,
`_MEMLOOP`, `_CHATEVAL`, `_KEYEVAL`, `_MEMSTAT`, `_MEMBLOCK`, `_OUT` — the file header
explains each), launch the `.app`, read the report. Mini (AFM) on macOS 27 is the
exception: `M1K3_AFM_EVAL=1 swift test --filter MiniLiveEvalTests`. A change touching
MLX / Metal / RealityKit / voice is **verify-by-launch** — name the verify owed rather than
claiming it proven from `swift test`.

## Architecture in one breath

Protocol-seam first: pure, dependency-free logic in the core targets so `swift test`
drives TDD in seconds; heavy backends (MLX, WhisperKit, Kokoro/MLX, GRDB) isolated behind
protocols in their own targets. `M1K3App/` is a thin shell; `AppEnvironment` (+ its
`AppEnvironment+*.swift` extensions) is the composition root. Target by target:
`docs/MODULE_MAP.md`.

- **Brains** (`BrainTier.swift`): Mini (Apple Foundation Models — or `LFM2.5-1.2B` shown as
  Mini where Apple Intelligence is blocked), Lil (`Qwen3-4B-Instruct-2507-4bit-DWQ-2510`),
  Big (`gemma-4-12B-it-4bit`, 16 GB floor, excluded on mobile). First run is Mini-first
  (`HelloView`); Lil/Big are opt-in upgrades. The why: `docs/MODEL_CHOICES.md`.
- **Tool calling** (`LocalAgent.run`): native when the brain has a resolvable tool-call
  format — Qwen3 → `.json`, gemma-4 → `.gemma4` — else the ReAct floor.
- **MCP, two surfaces:** the in-app HTTP server on `127.0.0.1:4242/mcp` while the app
  runs (`M1K3App/MCPHostController.swift`), and the `M1K3MCP` stdio binary
  (`docs/MCP_SETUP.md`). `ask_m1k3` is submit-and-poll: ~8 s inline, then a job id for
  `get_answer`; `list_jobs` recovers lost ids.

## Conventions specific to this repo

- **Everything is `app.m1k3`** — bundle ID, log subsystem, Keychain, sandbox container
  (renamed from `dev.murphysig.M1K3` 2026-06-14; translate old refs on read). MLX weights
  live inside the container under `Library/Application Support/models/<org>/<repo>/`,
  never Caches (macOS purged the brains twice, #92). `DEVELOPMENT_TEAM` is pinned in
  `project.yml` — a stable signing identity keeps Keychain/TCC grants.
- **`Package.swift` pins mlx-swift-lm to a main REVISION** (`e3d4a20e`, 2026-09-05, for
  #516/#533/#514/#575; back to a tag when one carries #516). `newCache(parameters:)`
  throws there. Dep bumps are probe-first (`swift package resolve` — the WhisperKit /
  swift-transformers `Tokenizers` clash) and **every bump owes a gemma-4 native tool-call
  smoke**: `M1K3_SELFTEST_CHATEVAL=1 M1K3_SELFTEST_CHATEVAL_BRAINS=big
  M1K3_SELFTEST_CHATEVAL_KINDS=tool-use` (the 08-08 bump took tool-use 5/5 → 0/5 and only
  the smoke caught it).
- `xcodebuild` needs `-skipPackagePluginValidation` (mlx-swift's `CudaBuild` plugin).
- **`rg -rn` is a footgun** — `-r` is `--replace`. Use `rg -n`.
- Parallel sessions share `macos/.build` and the index: commit from an isolated worktree
  off `origin/master` and stage only your own paths (`git add -A` sweeps other sessions'
  uncommitted files).
- SwiftLint pre-commit is advisory; pre-existing length/cyclomatic violations on large
  files are a standing "don't chase" set.
- **Docs move in the same commit as the code.** A new `.library` product, app surface, or
  type moved between the app and `Sources/` updates `docs/MODULE_MAP.md` (CI-pinned), the
  surface tables in `../README.md` / `../CONTRIBUTING.md`, and `docs/IOS_VISIONOS_PORT.md`.

<!-- Signed: Kev + claude-fable-5.1, 2026-09-25, Confidence 0.85, Prior: Unknown (the file
carried no signature). Leaned from 254 lines / 23 KB to ~90 lines: the Module map moved to
docs/MODULE_MAP.md (drift checker repointed), CI + landing detail lives in ../CLAUDE.md and
.github/workflows/README.md, SelfTest key prose lives in the file header. Every fact kept is
one a cold session needs before its first edit. Open: anything that turns out to be missed
on turn one goes back — measure at the next /retro. -->
