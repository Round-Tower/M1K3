# M1K3 - Local AI Assistant

@.claude/project-memory.md

> **⚠️ Orientation (2026-08-13):** The **live product** is the Mac-native SwiftUI
> app under **`macos/`** (`M1K3App/`) — see `macos/CLAUDE.md`, `macos/PLAN.md` and
> `.claude/project-memory.md`. The same portable `macos/Sources/` package graph
> also drives a native **iOS + visionOS** SwiftUI shell under `macos/M1K3iOSApp/`
> (`M1K3iOS` / `M1K3visionOS` targets) — see `macos/docs/IOS_VISIONOS_PORT.md`.
> The legacy Python surface (CLI, RAG engine, web avatar, PWA, Tauri popover —
> pre-Mac-app, last meaningful work Jan 2026) was archived under `attic/` and
> then **cleared from the working tree on 2026-08-13** — git history before
> `7545b4a4` keeps all of it (`git checkout 7545b4a4 -- attic` resurrects the
> tree, old repo-root layout intact). The live MCP surface is the Mac app's
> in-app HTTP server (`.mcp.json` points at `127.0.0.1:4242/mcp`).

Privacy-focused local AI companion for macOS — MLX inference, live voice,
knowledge graph + RAG, and an MCP server.

## Pointers

- **`macos/CLAUDE.md`** — the live product: build, test, architecture. Start here.
- **`macos/README.md`** — human-facing build-from-source.
- **`macos/docs/IOS_VISIONOS_PORT.md`** — the native iOS + visionOS SwiftUI shell
  (`macos/M1K3iOSApp/`) on the shared package graph. This — not `app/` — is the
  Apple mobile/spatial surface.
- **`app/CLAUDE.md`** — M1K3 for Android (Kotlin Multiplatform, slow burn — the **Android** surface).
- **The attic** — the original Python CLI, avatar experiments, and era docs
  live in git history before `7545b4a4` (the tour starts at `attic/README.md`
  there). Cleared from the tree 2026-08-13; nothing under `macos/` or `app/`
  depends on it.
- **`CONTRIBUTING.md` / `SECURITY.md`** — public-repo contributor surface.

## graphify

This project *can* carry a knowledge graph at graphify-out/ (god nodes, community structure, cross-file relationships) — but it's gitignored/regenerable, so a fresh clone has none.

Rules:
- ⚠️ **Only if `graphify-out/graph.json` exists.** The last local build (2026-06-14) is materially stale — it predates the entire iOS/visionOS shell and the `M1K3MemoryChatBridge`/`M1K3MCPLog` modules. There is no `graphify` binary on PATH — it runs via the graphify *skill*, not a shell command. Until rebuilt (via the skill), prefer direct reads under `macos/`.
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
