# M1K3 for Android (Kotlin Multiplatform)

@.claude/project-memory.md

Privacy-first AI companion via Kotlin Multiplatform. Your device is the cloud — on-device chat, user-initiated network only (see ADR-0006).

Note on naming: the product is **M1K3**. The internal `Ma*` class/file
prefix (`MaTheme`, `MaButton`, `MaBridge`, …) is a historical
design-system prefix from an earlier working name — it is not
user-facing and is not being renamed (see `.claude/project-memory.md`).

## Commands
```bash
# Build
./gradlew :composeApp:assembleDebug
./gradlew :composeApp:installDebug

# Test
./gradlew :composeApp:testDebugUnitTest           # Unit tests
./gradlew :composeApp:connectedDebugAndroidTest   # Instrumented

# Single test class
./gradlew :composeApp:testDebugUnitTest --tests "*.MemoryRepositoryTest"
```

## Test Performance

**gradle.properties is optimized for fast test execution:**
- Parallel builds (6 workers)
- Kotlin incremental compilation + caching
- ParallelGC for faster builds
- Kapt optimization for annotation processing

**TDD + Domain-First Workflow:**
1. **Domain first** - Can this logic live in `domain/`? If yes, put it there.
2. Write failing test first (Red)
3. Implement minimal code to pass (Green)
4. Refactor while keeping tests green
5. Use `runCurrent()` in coroutine tests to avoid `advanceUntilIdle()` cleanup issues
6. Disable background jobs in ViewModels during tests with constructor params

## Structure

Two Gradle modules — `:shared` (pure Kotlin domain) and `:composeApp`
(Android app, Compose Multiplatform UI + Android platform code):

```
├── shared/src/
│   ├── commonMain/kotlin/app/m1k3/ai/domain/
│   │   ├── ai/               # LlmModel, M1K3Tier, InferenceTuning
│   │   ├── voice/            # VoiceLoopMachine, SilenceEndpointer
│   │   ├── chat/             # ChatFormat, ContextAssembler
│   │   ├── rag/              # Intent, IntentClassifier
│   │   ├── memory/           # MemoryChunk, SemanticChunker
│   │   ├── passages/         # Personal-knowledge domain
│   │   ├── repositories/     # Interfaces (Knowledge, Memory)
│   │   └── usecases/         # Business logic orchestration
│   └── commonTest/
├── composeApp/src/
│   ├── commonMain/kotlin/app/m1k3/ai/assistant/
│   │   ├── ai/               # AI interfaces, BaseLlmEngine
│   │   ├── chat/              # ChatScreenViewModel, ChatUiState
│   │   ├── voice/              # VoiceLoopController, VoiceTurnRunner
│   │   ├── embedding/           # EmbeddingEngine, EmbeddingEngineManager
│   │   ├── memory/                # MemoryManager, MemoryDataSource
│   │   ├── design/                 # Ma* design system (see naming note above)
│   │   └── di/                      # Koin modules
│   ├── androidMain/         # Android implementations
│   │   ├── ai/ma/            # Ma — our llama.cpp JNI bridge
│   │   ├── embedding/         # MiniLM, Gemma engines
│   │   ├── stt/, tts/          # Speech recognition, text-to-speech
│   │   ├── ui/                  # VoiceScreen, ChatScreen, SettingsScreen
│   │   └── tools/                # AndroidToolRegistry, executors
│   └── commonTest/
└── docs/adr/                # Architecture decision records
```

## Stack (from libs.versions.toml)
- **Kotlin**: 2.2.20
- **Compose Multiplatform**: 1.9.2
- **SQLDelight**: 2.0.2 (+ SQLCipher AES-256 at rest)
- **ONNX Runtime**: 1.23.2
- **Target**: Android API 27+

## AI Models
- **Mini M1K3** — Qwen3.5 0.8B, <4GB RAM devices.
- **Lil M1K3** — Qwen3.5 2B, 4–8GB RAM devices.
- **Big M1K3** — Gemma 4 E2B, 8GB+ RAM devices.
- All served via `Ma` (our own JNI bridge to llama.cpp), GGUF Q4_K_M,
  GBNF grammar-constrained native tool calling. See `M1K3Tier.kt`.
- **MiniLM-L6**: embeddings (384-dim, ONNX).

## Key Patterns
- Sealed classes for UI state
- `expect`/`actual` for platform code
- Koin for DI (`di/` modules)
- Flow for async streams

## Domain Layer First (IMPORTANT)

**All shareable business logic goes in `domain/` as pure Kotlin—no platform dependencies.**

This is as important as TDD:
1. **Testable** - Unit tests run instantly without emulators/mocks
2. **Shareable** - Works across Android, iOS, Desktop
3. **Maintainable** - Clear separation from platform noise

### Domain Structure
```
domain/
├── entities/        # Data classes (Tool, Intent, MemoryChunk)
├── services/        # Interfaces + pure implementations
├── repositories/    # Data access interfaces
└── usecases/        # Business logic orchestration
```

### When to Use Domain Layer
- Business logic (validation, calculation, transformation)
- Use cases (orchestrating multiple operations)
- Entity definitions (data models)
- Service interfaces (contracts for platform implementations)

### When NOT to Use Domain Layer
- Android Intents, Context, Views
- iOS UIKit, CoreData
- Platform-specific APIs (Camera, Sensors)

### Pattern: Interface in Domain, Implementation in Platform
```kotlin
// domain/repositories/MemoryRepository.kt
interface MemoryRepository {
    suspend fun search(query: String): List<MemoryChunk>
}

// androidMain/.../MemoryRepositoryImpl.kt
class MemoryRepositoryImpl(context: Context) : MemoryRepository {
    // Android-specific implementation
}
```

## Privacy
- **Your device is the cloud.** Chat inference runs 100% on-device.
- **INTERNET permission** granted for user-initiated network: `HttpModelDownloadManager` (HuggingFace GGUF downloads) and `WebSearchExecutor` (DuckDuckGo). See `docs/adr/0006-user-initiated-network.md`.
- **No analytics, telemetry, or crash reporting** — enforced at dependency-classpath level by `ManifestPrivacyTest`.
- **SQLCipher** for encrypted storage (AES-256).

## Docs
- Build/architecture overview: `README.md`
- AI details (historical design rationale, banner-guarded): `AI_ARCHITECTURE.md`
- ADRs (kept current): `docs/adr/`
- Reference architecture (Mac-native flagship): `../macos/CLAUDE.md`
