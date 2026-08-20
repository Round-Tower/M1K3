# 間 AI - On-Device Mobile AI

@.claude/project-memory.md

Privacy-first AI companion via Kotlin Multiplatform. Your device is the cloud — on-device chat, user-initiated network only (see ADR-0006).

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
```
├── composeApp/src/
│   ├── commonMain/kotlin/app/m1k3/ai/assistant/
│   │   ├── domain/          # Pure Kotlin business logic (IMPORTANT)
│   │   │   ├── tools/       # Tool entities, services, registry
│   │   │   ├── chat/        # ChatFormat, ContextAssembler
│   │   │   ├── rag/         # Intent, IntentClassifier
│   │   │   ├── memory/      # MemoryChunk, SemanticChunker
│   │   │   ├── repositories/# Interfaces (Knowledge, Memory)
│   │   │   └── usecases/    # Business logic orchestration
│   │   ├── ai/              # AI interfaces, BaseLlmEngine
│   │   ├── chat/            # ChatScreenViewModel, ChatUiState
│   │   ├── embedding/       # EmbeddingEngine, EmbeddingEngineManager
│   │   ├── memory/          # MemoryManager, MemoryDataSource
│   │   ├── knowledge/       # SemanticRetrievalService
│   │   ├── config/          # GenerationConstants
│   │   └── di/              # Koin modules
│   ├── androidMain/         # Android implementations
│   │   ├── ai/ondevice/     # LlamaCpp, MlKitGenAi engines
│   │   ├── embedding/       # MiniLM, Gemma engines
│   │   └── tools/           # AndroidToolRegistry, executors
│   └── iosMain/             # iOS (future)
└── docs/adr/                # Architecture decision records
```

## Stack (from libs.versions.toml)
- **Kotlin**: 2.2.20
- **Compose Multiplatform**: 1.9.2
- **SQLDelight**: 2.0.2
- **ONNX Runtime**: 1.23.2
- **Target**: Android API 27+, iOS 15+ (future)

## AI Models
- **SmolLM2-360M**: Primary LLM (LlamaCpp engine)
- **MlKitGenAi**: Google's on-device AI (fallback)
- **Gemma/MiniLM**: Embeddings (384-dim)
- **Qwen2.5-Coder**: Code generation (dynamic module)

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
- Architecture: `ARCHITECTURE.md`
- AI details: `AI_ARCHITECTURE.md`
- ADRs: `docs/adr/`
