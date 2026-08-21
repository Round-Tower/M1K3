package app.m1k3.ai.assistant.di

import android.content.Context
import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.ai.LlamaCppEngine
import app.m1k3.ai.assistant.ai.download.HttpModelDownloadManager
import app.m1k3.ai.assistant.ai.download.ModelDownloadWorker
import app.m1k3.ai.assistant.app.AndroidDatabaseInitializer
import app.m1k3.ai.assistant.app.IDatabaseInitializer
import app.m1k3.ai.assistant.app.InitializationViewModel
import app.m1k3.ai.assistant.app.LoggerAdapter
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.database.AndroidDatabaseFactory
import app.m1k3.ai.assistant.database.DatabaseConfig
import app.m1k3.ai.assistant.database.DatabaseFactory
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.embedding.EmbeddingEngine
import app.m1k3.ai.assistant.embedding.EmbeddingEngineManager
import app.m1k3.ai.assistant.embedding.EmbeddingEngineManagerImpl
import app.m1k3.ai.assistant.embedding.EmbeddingModelManager
import app.m1k3.ai.assistant.history.ConversationRepository
import app.m1k3.ai.assistant.history.ExportManager
import app.m1k3.ai.assistant.history.HistoryViewModel
import app.m1k3.ai.assistant.history.SearchRepository
import app.m1k3.ai.assistant.memory.MemoryManager
import app.m1k3.ai.assistant.onboarding.OnboardingDownloadState
import app.m1k3.ai.assistant.onboarding.OnboardingViewModel
import app.m1k3.ai.assistant.platform.DateTimeProvider
import app.m1k3.ai.assistant.platform.DeviceInfoProvider
import app.m1k3.ai.assistant.platform.DeviceInfoProviderInterface
import app.m1k3.ai.assistant.platform.PreferencesStore
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.assistant.tools.AndroidToolRegistry
import app.m1k3.ai.assistant.tts.AudioEffectsProcessor
import app.m1k3.ai.assistant.tts.AudioPlayer
import app.m1k3.ai.assistant.tts.KokoroTtsEngine
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.assistant.voice.KokoroOrPlatformSpeaker
import app.m1k3.ai.assistant.voice.Speaker
import app.m1k3.ai.assistant.voice.TextToSpeechSpeaker
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.ModelDownloadManager
import app.m1k3.ai.domain.chat.services.UnifiedPromptBuilder
import app.m1k3.ai.domain.platform.DateTimeProviderInterface
import app.m1k3.ai.domain.platform.DeviceTier
import app.m1k3.ai.domain.tools.services.ToolRegistry
import app.m1k3.ai.domain.tts.TtsEngine
import app.m1k3.ai.domain.tts.Voice
import app.m1k3.ai.domain.usecases.chat.LlmOutputProcessor
import kotlinx.coroutines.launch
import org.koin.androidx.viewmodel.dsl.viewModel
import org.koin.core.module.dsl.*
import org.koin.dsl.module

/**
 * Android platform module
 *
 * Provides Android-specific dependencies:
 * - SQLDelight Android driver
 * - Android Context
 * - AI Engines (LlamaCppEngine — the real chat path. ML Kit GenAI/OnDeviceAi
 *   was a parallel engine never wired into ChatScreenViewModel; cut 2026-08.)
 */
actual val platformModule =
    module {
        /**
         * DatabaseFactory for Android — SQLCipher-backed encrypted DB.
         *
         * First cold-start after shipping SQLCipher runs a one-shot wipe of the
         * legacy plaintext DB so SupportOpenHelperFactory doesn't try to open
         * unencrypted bytes. In active development with no prod users; the
         * wipe is idempotent and gated on a SharedPreferences marker.
         */
        single { AndroidDatabaseFactory(get<Context>()) }
        single {
            wipeLegacyPlaintextDbIfNeeded(get<Context>())
            DatabaseFactory(driver = get<AndroidDatabaseFactory>().buildEncryptedDriver())
        }

        // ===== Platform Abstractions =====

        /**
         * DeviceInfoProvider
         *
         * Provides device information for adaptive generation:
         * - RAM for token limit scaling
         * - Device model for debugging
         * - Battery level for power-aware generation
         */
        single<DeviceInfoProviderInterface> {
            DeviceInfoProvider(get<Context>())
        }

        /**
         * DateTimeProvider
         *
         * Provides date/time context for prompts:
         * - Current time for context-aware greetings
         * - Locale for formatting
         */
        single<DateTimeProviderInterface> {
            DateTimeProvider()
        }

        /**
         * PreferencesStore
         *
         * SharedPreferences wrapper for feature flags and settings.
         * Thread-safe with reactive observation support.
         */
        single<PreferencesStoreInterface> {
            PreferencesStore(get<Context>())
        }

        // ===== Embedding Engine =====

        /**
         * EmbeddingEngineManager
         *
         * Manages lifecycle and initialization of embedding engines.
         * Provides thread-safe singleton pattern with lazy model loading.
         *
         * Must call initialize() in MainActivity to load the ONNX model.
         */
        single<EmbeddingEngineManager> {
            EmbeddingEngineManagerImpl(get<Context>(), sharedEngine = get<EmbeddingEngine>())
        }

        /**
         * EmbeddingEngine
         *
         * Provides text-to-vector embeddings for semantic search and RAG.
         * Uses EmbeddingModelManager to select between MiniLM (default) and Gemma (optional).
         *
         * Model selection:
         * - MiniLM-L6-v2 (384-dim, 80MB, built-in)
         * - Embedding Gemma (512-dim, 180MB, dynamic module)
         *
         * Note: Engine is created but NOT loaded. Call EmbeddingEngineManager.initialize() in MainActivity to load model.
         */
        single<EmbeddingEngine> {
            val manager = EmbeddingModelManager(get<Context>())
            manager.getEmbeddingEngine()
        }

        // ===== TTS Engine Layer =====

        /**
         * AudioEffectsProcessor
         *
         * DSP effects for TTS audio output (RadioChat, Intercom, etc.).
         * Stateless — singleton is fine.
         */
        single { AudioEffectsProcessor() }

        /**
         * AudioPlayer
         *
         * AudioTrack-based playback for synthesized audio.
         * 24kHz mono PCM float (Kokoro native format).
         */
        single { AudioPlayer() }

        /**
         * TtsEngine (Kokoro)
         *
         * On-device text-to-speech via ONNX Runtime.
         * INT8 quantized model (~90MB). Daniel voice default.
         *
         * Note: Call loadModel() before first synthesis.
         */
        single<TtsEngine> {
            KokoroTtsEngine(get<Context>())
        }

        /**
         * Speaker — the spoken-audio sink voice mode AND "speak replies aloud"
         * both use. Kokoro when it's loaded and healthy; Android's platform
         * TextToSpeech when it isn't (Kokoro's ONNX synth has a logged
         * "/encoder/bert/Expand invalid shape" failure mode — this is the
         * floor that never fails silently under it).
         */
        single<Speaker> {
            val prefs = get<PreferencesStoreInterface>()
            KokoroOrPlatformSpeaker(
                kokoro = get<TtsEngine>(),
                platform = TextToSpeechSpeaker(get<Context>()),
                playAudio = { audio ->
                    val warmed =
                        get<AudioEffectsProcessor>()
                            .apply(audio, app.m1k3.ai.domain.tts.TtsEffect.Chain.M1K3_DEFAULT)
                    get<AudioPlayer>().playToCompletion(warmed)
                },
                stopAudio = { get<AudioPlayer>().stop() },
                voice = {
                    val voiceId =
                        prefs.getString(
                            app.m1k3.ai.assistant.platform.PreferenceKeys.SELECTED_VOICE,
                            Voice.default.id,
                        ) ?: Voice.default.id
                    Voice.findById(voiceId) ?: Voice.default
                },
            )
        }

        // ===== AI Engine Layer =====

        /**
         * LlamaCppEngine (BaseLlmEngine implementation)
         *
         * Used as fallback when ML Kit GenAI is not available.
         * Also used directly for fine-grained LLM control.
         */
        single<BaseLlmEngine> {
            // Use whichever model the user installed during onboarding.
            // SELECTED_M1K3_TIER is saved as "mini" | "lil" | "big" when the
            // download completes. Default to Gemma3_1B (Lil M1K3) if not set.
            val prefs = get<PreferencesStoreInterface>()
            val tierKey =
                prefs.getString(
                    app.m1k3.ai.assistant.platform.PreferenceKeys.SELECTED_M1K3_TIER,
                    "lil",
                ) ?: "lil"
            val model: LlmModel =
                when (tierKey) {
                    "mini" -> LlmModel.Qwen35_0B8
                    "big" -> LlmModel.Gemma4_E2B
                    else -> LlmModel.Qwen35_2B // "lil" + fallback
                }
            val overridePath = get<ModelDownloadManager>().getModelPath(model.id)
            LlamaCppEngine(get<Context>(), model, overrideModelPath = overridePath)
        }

        // ===== Model Download Manager =====

        /**
         * HttpModelDownloadManager
         *
         * Downloads GGUF model files from HuggingFace to internal storage.
         * Used for large models (Gemma 4 E2B) that can't be bundled in APK.
         */
        single<ModelDownloadManager> {
            HttpModelDownloadManager(
                context = get<Context>(),
            )
        }

        // ===== Tool Calling Infrastructure =====

        /**
         * Android Tool Registry
         *
         * Registers Android-specific tools:
         * - Device info (battery, time)
         * - System controls (flashlight)
         * - App launchers (camera, browser, settings)
         */
        single<ToolRegistry> {
            AndroidToolRegistry(
                context = get<Context>(),
            )
        }

        // ===== Personal Knowledge (Passages) =====

        /**
         * PassageRepository — SQLCipher-backed storage for user-imported notes + docs.
         * Day-one retrieval is keyword LIKE; embedding-backed search lands with the
         * embedding pipeline wiring.
         */
        /**
         * PassageEmbedder — semantic vectors for passage save + search.
         * Null-tolerant: if the engine fails to load, repo degrades to keyword LIKE.
         */
        single<app.m1k3.ai.domain.passages.services.PassageEmbedder> {
            app.m1k3.ai.assistant.passages.EngineBackedPassageEmbedder(
                engine = get<EmbeddingEngine>(),
            )
        }

        /**
         * VectorIndex — in-memory top-K cache of passage embeddings.
         *
         * Baseline [LinearScanVectorIndex] holds vectors deserialized for the
         * lifetime of the process, so search avoids pulling every embedded
         * row on every query. The repository lazy-warms it from the DB on
         * the first search after launch.
         *
         * Scoped as `single` so one index per app process; survives ViewModel
         * recreation but not process death (DB is the source of truth — a
         * rebuild on cold start is fine).
         */
        single<app.m1k3.ai.domain.passages.services.VectorIndex> {
            app.m1k3.ai.domain.passages.services
                .LinearScanVectorIndex()
        }

        single<app.m1k3.ai.domain.passages.repositories.PassageRepository> {
            app.m1k3.ai.assistant.passages.SqlDelightPassageRepository(
                database = get<MaDatabase>(),
                embedder = get<app.m1k3.ai.domain.passages.services.PassageEmbedder>(),
                vectorIndex = get<app.m1k3.ai.domain.passages.services.VectorIndex>(),
            )
        }

        /**
         * RetrievePassagesUseCase — thin domain wrapper called from ContextRetrievalUseCase.
         * Guards against blank queries / non-positive limits before hitting storage.
         */
        single {
            app.m1k3.ai.domain.passages.usecases.RetrievePassagesUseCase(
                repository = get(),
            )
        }

        /**
         * PassageChunker — paragraph-aware greedy chunker for personal-doc ingestion.
         * Stateless, safe to share.
         */
        single {
            app.m1k3.ai.domain.passages.services
                .PassageChunker()
        }

        /**
         * ImportTextUseCase — orchestrates chunk + persist for user-imported text.
         * UUID ids and `System.currentTimeMillis()` clock are Android-native fine.
         */
        single {
            app.m1k3.ai.domain.passages.usecases.ImportTextUseCase(
                chunker = get(),
                repository = get(),
                idProvider = {
                    java.util.UUID
                        .randomUUID()
                        .toString()
                },
                clock = { System.currentTimeMillis() },
            )
        }

        // ===== MemoryManager =====
        // MemoryManager is NOT registered as a singleton because it requires projectId scoping.
        // It is created inline in the ChatScreenViewModel factory below.

        // ===== Initialization Layer =====

        /**
         * AndroidDatabaseInitializer
         *
         * Handles database initialization and knowledge import.
         * Registered as singleton to ensure single initialization flow.
         */
        single<IDatabaseInitializer> {
            val logger = Logger.withTag("DatabaseInitializer")
            AndroidDatabaseInitializer(
                context = get<Context>(),
                logger = LoggerAdapter(logger),
            )
        }

        // ===== ViewModel Layer =====

        /**
         * InitializationViewModel
         *
         * Manages app initialization state (knowledge import).
         * Database is created by Koin and injected.
         * Registered as ViewModel for proper lifecycle management.
         */
        viewModel {
            InitializationViewModel(
                database = get<MaDatabase>(),
                databaseInitializer = get<IDatabaseInitializer>(),
            )
        }

        /**
         * ChatScreenViewModel (optional projectId parameter)
         *
         * Main chat interface ViewModel with full dependency injection.
         * Accepts optional projectId via parametersOf(), defaults to "default".
         *
         * Usage:
         * ```kotlin
         * // With default projectId
         * val chatViewModel = koinViewModel<ChatScreenViewModel>()
         *
         * // With custom projectId
         * val chatViewModel = koinViewModel<ChatScreenViewModel> {
         *     parametersOf("my-project")
         * }
         * ```
         */
        viewModel { params ->
            val projectId = params.getOrNull<String>() ?: "default"
            val context = get<Context>()

            // MemoryManager is scoped per project — created here with projectId
            val memoryManager =
                MemoryManager(
                    chunker = get<app.m1k3.ai.domain.memory.services.SemanticChunker>(),
                    repository = get<app.m1k3.ai.assistant.memory.MemoryDataSource>(),
                    importanceCalculator = get<app.m1k3.ai.domain.memory.ImportanceCalculator>(),
                    memoryRanker = get<app.m1k3.ai.assistant.memory.MemoryRanker>(),
                    projectId = projectId,
                    // embeddingRepository and vectorSearchRepository left null for now —
                    // basic ops (stats, recent, pin) work; create/retrieve need embeddings (Priority 6)
                )

            ChatScreenViewModel(
                aiEngine = get<BaseLlmEngine>(),
                conversationRepo = get<ConversationRepository>(),
                database = get<MaDatabase>(),
                deviceInfo = get<DeviceInfoProviderInterface>(),
                preferences = get<PreferencesStoreInterface>(),
                projectId = projectId,
                memoryManager = memoryManager,
                passageRetriever = get<app.m1k3.ai.domain.passages.usecases.RetrievePassagesUseCase>(),
                toolRegistry = get<ToolRegistry>(),
                processLlmOutput = get<LlmOutputProcessor>(),
                dateTimeProvider = get<DateTimeProviderInterface>(),
                engineFactory = { model ->
                    val downloadManager = get<ModelDownloadManager>()
                    val overridePath = downloadManager.getModelPath(model.id)
                    LlamaCppEngine(context, model, overrideModelPath = overridePath)
                },
                isModelDownloaded = { model ->
                    get<ModelDownloadManager>().isModelAvailable(model.id)
                },
                deleteModel = { model ->
                    get<ModelDownloadManager>().deleteModel(model.id)
                },
                downloadModel = { model, onProgress ->
                    val httpManager = get<ModelDownloadManager>() as HttpModelDownloadManager
                    @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
                    kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                        httpManager.download(model).collect { progress ->
                            val state =
                                when (progress) {
                                    is app.m1k3.ai.assistant.ai.download.DownloadProgress.Starting -> {
                                        app.m1k3.ai.assistant.chat.ModelDownloadState
                                            .Starting(model.displayName)
                                    }

                                    is app.m1k3.ai.assistant.ai.download.DownloadProgress.InProgress -> {
                                        app.m1k3.ai.assistant.chat.ModelDownloadState.InProgress(
                                            modelName = model.displayName,
                                            progressPercent = progress.progressPercent,
                                            downloadedMB = progress.bytesDownloaded / 1_000_000,
                                            totalMB = progress.totalBytes / 1_000_000,
                                        )
                                    }

                                    is app.m1k3.ai.assistant.ai.download.DownloadProgress.Complete -> {
                                        app.m1k3.ai.assistant.chat.ModelDownloadState
                                            .Complete(model.displayName)
                                    }

                                    is app.m1k3.ai.assistant.ai.download.DownloadProgress.Failed -> {
                                        app.m1k3.ai.assistant.chat.ModelDownloadState
                                            .Failed(model.displayName, progress.error)
                                    }
                                }
                            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                                onProgress(state)
                            }
                        }
                    }
                },
                onSpeakText = { text -> get<Speaker>().speak(text) },
                userNameProvider = {
                    app.m1k3.ai.assistant.context
                        .UserNameProvider(context)
                        .getUserFirstName()
                },
                toolExecutionDataSource = get<app.m1k3.ai.assistant.tools.ToolExecutionDataSource>(),
            )
        }

        /**
         * OnboardingViewModel
         *
         * Drives the first-launch experience: tier detection, model download,
         * and onboarding-complete persistence.
         */
        viewModel {
            val deviceInfo = get<DeviceInfoProviderInterface>()
            val httpManager = get<ModelDownloadManager>() as HttpModelDownloadManager
            OnboardingViewModel(
                getDeviceTier = {
                    val ramGB = deviceInfo.getDeviceRamGB()
                    when {
                        ramGB >= 12 -> DeviceTier.FLAGSHIP
                        ramGB >= 8 -> DeviceTier.HIGH_END
                        ramGB >= 6 -> DeviceTier.MID_RANGE
                        ramGB >= 4 -> DeviceTier.BUDGET
                        else -> DeviceTier.LOW_END
                    }
                },
                // WorkManager download — survives screen lock, Doze, backgrounding
                downloadModel = { model ->
                    val ctx = get<Context>()
                    ModelDownloadWorker.enqueue(ctx, model) // KEEP — safe to call repeatedly
                    ModelDownloadWorker.observeAsFlow(ctx, model) // observe by name, not UUID
                },
                prefs = get<PreferencesStoreInterface>(),
            )
        }

        /**
         * HistoryViewModel
         *
         * Manages conversation history UI state.
         * Handles search, export, and conversation management.
         */
        viewModel {
            HistoryViewModel(
                conversationRepository = get<ConversationRepository>(),
                searchRepository = get<SearchRepository>(),
                exportManager = get<ExportManager>(),
            )
        }
    }

/**
 * One-shot migration: delete the pre-SQLCipher plaintext `ma_ai.db` on first
 * cold-start after the SQLCipher cutover, so [SupportOpenHelperFactory]
 * doesn't fail opening plaintext bytes with an encrypted driver.
 *
 * Idempotent via a SharedPreferences marker; re-runs are no-ops. Safe at
 * current phase: active development, no prod users.
 */
private fun wipeLegacyPlaintextDbIfNeeded(context: Context) {
    val prefs = context.getSharedPreferences("ma_db_meta", Context.MODE_PRIVATE)
    if (prefs.getBoolean("sqlcipher_initialized", false)) return
    context.deleteDatabase(DatabaseConfig.DATABASE_NAME)
    prefs.edit().putBoolean("sqlcipher_initialized", true).apply()
}
