# M1K3 for Android — a local, private AI companion

> On-device chat. Your device is the cloud — network is a tool you wield,
> not a default. See `docs/adr/0006-user-initiated-network.md`.

## Overview

M1K3 for Android is the mobile companion to
[M1K3](../macos/CLAUDE.md) (the Mac-native SwiftUI flagship), built with
Kotlin Multiplatform. Every inference, every memory, every conversation
stays on your device.

### Brain ladder

M1K3 matches its intelligence to your hardware (`M1K3Tier.kt`) — every
device gets the best M1K3 it can carry:

| Tier | Device RAM | Model | Feel |
|------|-----------|-------|------|
| **Mini M1K3** | <4GB | Qwen3.5 0.8B | Fast and focused |
| **Lil M1K3** | 4–8GB | Qwen3.5 2B | Sharp and capable |
| **Big M1K3** | 8GB+ | Gemma 4 E2B | Full intelligence |

Highest tier the device can support is recommended at first launch; users
can downgrade in onboarding if preferred.

### Key features

- **On-device chat** — llama.cpp via our own `Ma` JNI bridge
  (`composeApp/src/androidMain/cpp/llama.cpp` submodule). Native
  GBNF grammar-constrained tool calling.
- **Full-screen voice mode** — M1K3 owns the turn boundary (not the
  recogniser): silence/politeness-aware endpointing, barge-in, spoken
  replies via platform TTS by default.
- **Personal knowledge (RAG)** — import your own notes/text as Passages;
  embedding-backed retrieval with keyword fallback. No bundled trivia
  corpus — your content is the corpus.
- **Semantic memory** — importance-scored memory chunks, retrieved by
  vector search, feeding conversational context.
- **Eco metrics** — `cloudBytesAvoided` vs. what a cloud round-trip would
  have cost, plus real bytes for the two user-initiated network paths.
- **Dot-matrix / 3D avatar hero** — Filament-based, emotion-driven.

### Privacy, stated once

Chat inference runs 100% on-device. Network is user-initiated only — model
downloads (HuggingFace GGUF) and the web-search tool — nothing else.
No analytics, telemetry, or crash-reporting SDKs; enforced at
dependency-classpath level by `ManifestPrivacyTest`. Conversations are
encrypted at rest with SQLCipher. See `docs/adr/0006-user-initiated-network.md`
for the full contract and its addenda.

## Quick start

### Prerequisites

- Android Studio Ladybug (2024.2.1+)
- JDK 17+
- Android device/emulator with API 27+ (Android 8.0+)

### Build & run

```bash
git clone https://github.com/Round-Tower/m1k3.git
cd m1k3/app

# Build debug APK
./gradlew :composeApp:assembleDebug

# Install on connected device
./gradlew :composeApp:installDebug
```

### Test

```bash
# Fast unit tests (shared domain + composeApp)
./gradlew :shared:jvmTest :composeApp:testDebugUnitTest

# Single test class
./gradlew :composeApp:testDebugUnitTest --tests "*.MemoryManagerTest"

# Instrumented (needs a device/emulator — privacy invariants live here)
./gradlew :composeApp:connectedDebugAndroidTest
```

## Structure

Two Gradle modules — `:shared` (pure Kotlin domain, portable to a future
iOS target) and `:composeApp` (the Android app, Compose Multiplatform UI +
Android platform implementations):

```
app/
├── shared/
│   └── src/
│       ├── commonMain/kotlin/app/m1k3/ai/domain/   # Pure domain logic
│       │   ├── ai/          # LlmModel, M1K3Tier, InferenceTuning
│       │   ├── voice/       # VoiceLoopMachine, SilenceEndpointer
│       │   ├── memory/      # Memory domain entities
│       │   ├── rag/         # Intent, IntentClassifier
│       │   └── passages/    # Personal-knowledge domain
│       └── commonTest/
├── composeApp/
│   └── src/
│       ├── commonMain/kotlin/app/m1k3/ai/assistant/
│       │   ├── ai/          # AI interfaces, BaseLlmEngine
│       │   ├── chat/        # ChatScreenViewModel, ChatUiState
│       │   ├── voice/       # VoiceLoopController, VoiceTurnRunner
│       │   ├── memory/      # MemoryManager, MemoryDataSource
│       │   ├── embedding/   # EmbeddingEngine, EmbeddingEngineManager
│       │   ├── design/      # Ma* design system (internal prefix, see CLAUDE.md)
│       │   └── di/          # Koin modules
│       ├── androidMain/     # Android implementations
│       │   ├── ai/ma/       # Ma — our llama.cpp JNI bridge
│       │   ├── embedding/   # MiniLM/Gemma engines
│       │   ├── stt/, tts/   # Speech recognition, text-to-speech
│       │   └── ui/          # VoiceScreen, ChatScreen, SettingsScreen
│       └── commonTest/
└── docs/adr/                # Architecture decision records
```

### Tech stack

Current versions live in `gradle/libs.versions.toml` — treat that as
canonical.

| Layer | Technology |
|-------|------------|
| **UI** | Compose Multiplatform 1.9.2 |
| **AI engine** | `Ma` — our own JNI bridge to llama.cpp (submodule) |
| **Models** | Qwen3.5 0.8B / 2B (Mini/Lil), Gemma 4 E2B (Big), GGUF Q4_K_M |
| **Database** | SQLDelight 2.0.2 + SQLCipher (AES-256 at rest) |
| **Embeddings** | MiniLM-L6 (384-dim, ONNX) |
| **Native tool calling** | GBNF grammar-constrained decoding |
| **DI** | Koin |
| **Build** | AGP 9.0.1, Kotlin 2.2.20, NDK 28.2.13676358 (pinned) |

## Related documentation

- [CLAUDE.md](CLAUDE.md) — project instructions (build/test commands,
  TDD/domain-first workflow, structure).
- [AI_ARCHITECTURE.md](AI_ARCHITECTURE.md) — historical design rationale
  (privacy model, RAG structure, eco metrics); read its staleness banner
  first.
- [docs/adr/](docs/adr/) — architecture decision records, kept current.
- [../macos/CLAUDE.md](../macos/CLAUDE.md) — M1K3's Mac-native flagship
  (SwiftUI), the reference architecture this Android app follows for
  voice-mode UX and the brain-tier naming.

## License

Part of the M1K3 project. See root `LICENSE` file.

---

**Last meaningful refresh:** 2026-08-21. For current state, prefer
`.claude/project-memory.md` and `git log` over this file.
