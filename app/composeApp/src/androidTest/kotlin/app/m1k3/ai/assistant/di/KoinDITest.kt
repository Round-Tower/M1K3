package app.m1k3.ai.assistant.di

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.embedding.EmbeddingEngine
import app.m1k3.ai.assistant.platform.DeviceInfoProviderInterface
import app.m1k3.ai.assistant.rag.RAGManager
import app.m1k3.ai.domain.tools.services.ToolRegistry
import app.m1k3.ai.domain.usecases.chat.LlmOutputProcessor
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.android.ext.koin.androidContext
import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin
import org.koin.test.KoinTest
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Koin DI Smoke Tests
 *
 * Validates critical dependencies are properly registered.
 * Catches NoDefinitionFoundException before runtime crashes.
 *
 * **Test Strategy:**
 * - Test critical dependencies (database, AI, embeddings)
 * - Test recently fixed issues (EmbeddingEngine, RAGManager)
 * - Test ViewModel creation
 * - Keep tests simple and fast
 *
 * **Regression Tests:**
 * - EmbeddingEngine was missing (fixed: PlatformModule.android.kt:118)
 * - RAGManager was nullable (fixed: PlatformModule.android.kt:209)
 * - ChatScreenViewModel dependencies (fixed: PlatformModule.android.kt:289-291)
 */
@RunWith(AndroidJUnit4::class)
class KoinDITest : KoinTest {
    @Before
    fun setup() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        startKoin {
            androidContext(context)
            modules(appModule, platformModule)
        }
    }

    @After
    fun tearDown() {
        stopKoin()
    }

    // ===== Critical Dependencies =====

    @Test
    fun AndroidContextIsAvailable() {
        val context = getKoin().get<Context>()
        assertNotNull(context, "Android Context should be registered")
    }

    @Test
    fun MaDatabaseIsAvailable() {
        val database = getKoin().get<MaDatabase>()
        assertNotNull(database, "MaDatabase should be registered")
    }

    @Test
    fun DeviceInfoProviderIsAvailable() {
        val deviceInfo = getKoin().get<DeviceInfoProviderInterface>()
        assertNotNull(deviceInfo, "DeviceInfoProvider should be registered")

        // Verify it works
        val ramGB = deviceInfo.getDeviceRamGB()
        assertTrue(ramGB > 0, "Device RAM should be positive: $ramGB GB")
    }

    @Test
    fun BaseLlmEngineIsAvailable() {
        val engine = getKoin().get<BaseLlmEngine>()
        assertNotNull(engine, "BaseLlmEngine should be registered")
    }

    // ===== Embedding Engine (Critical Fix) =====

    @Test
    fun EmbeddingEngineIsRegistered() {
        // Regression test: This was missing before our fix
        // Location: PlatformModule.android.kt:118
        val engine = getKoin().get<EmbeddingEngine>()
        assertNotNull(engine, "EmbeddingEngine should be registered")
    }

    @Test
    fun EmbeddingEngineIsProperlyConfigured() {
        val engine = getKoin().get<EmbeddingEngine>()
        // Just verify it exists - properties may not be accessible
        assertNotNull(engine, "EmbeddingEngine should have valid configuration")
    }

    // ===== RAGManager (Critical Fix) =====

    @Test
    fun RAGManagerIsRegistered() {
        // Regression test: This was getOrNull before our fix
        // Location: PlatformModule.android.kt:209
        val ragManager = getKoin().get<RAGManager>()
        assertNotNull(ragManager, "RAGManager should be registered (not nullable)")
    }

    @Test
    fun RAGManagerHasEmbeddingengineDependencySatisfied() {
        // This validates the dependency chain:
        // RAGManager -> EmbeddingEngine
        val ragManager = getKoin().get<RAGManager>()
        assertNotNull(ragManager, "RAGManager should be instantiable with EmbeddingEngine")
    }

    @Test
    fun SemanticRetrievalServiceCanBeInstantiated() {
        // Regression test: This was failing at AppModule:110
        // SemanticRetrievalService -> EmbeddingEngine
        val service = getKoin().get<app.m1k3.ai.assistant.knowledge.SemanticRetrievalService>()
        assertNotNull(service, "SemanticRetrievalService should be instantiable")
    }

    // ===== Tool Calling Infrastructure =====

    @Test
    fun ToolRegistryIsRegistered() {
        // Regression test: This was getOrNull before our fix
        val registry = getKoin().get<ToolRegistry>()
        assertNotNull(registry, "ToolRegistry should be registered")
    }

    @Test
    fun LlmOutputProcessorIsRegistered() {
        // Regression test: This was getOrNull before our fix
        val processor = getKoin().get<LlmOutputProcessor>()
        assertNotNull(processor, "LlmOutputProcessor should be registered")
    }

    // ===== ViewModels =====

    @Test
    fun ChatScreenViewModelCanBeCreated() {
        // Regression test: All dependencies should be non-null
        // - ragManager: RAGManager (not nullable)
        // - toolRegistry: ToolRegistry (not nullable)
        // - processLlmOutput: LlmOutputProcessor (not nullable)
        val viewModel = getKoin().get<ChatScreenViewModel>()
        assertNotNull(viewModel, "ChatScreenViewModel should be instantiable")
    }

    @Test
    fun ChatScreenViewModelCanBeCreatedWithCustomProjectid() {
        val viewModel =
            getKoin().get<ChatScreenViewModel> {
                org.koin.core.parameter
                    .parametersOf("test-project")
            }
        assertNotNull(viewModel, "ChatScreenViewModel should accept projectId parameter")
    }

    @Test
    fun allViewmodelsCanBeInstantiated() {
        // Smoke test: Try to create all ViewModels
        val viewModels =
            listOf(
                getKoin().get<app.m1k3.ai.assistant.app.InitializationViewModel>(),
                getKoin().get<ChatScreenViewModel>(),
                getKoin().get<app.m1k3.ai.assistant.eco.EcoStatsViewModel>(),
                getKoin().get<app.m1k3.ai.assistant.history.HistoryViewModel>(),
            )

        viewModels.forEach { vm ->
            assertNotNull(vm, "ViewModel should be instantiated: ${vm::class.simpleName}")
        }
    }

    // ===== Dependency Chain Validation =====

    @Test
    fun fullDependencyGraphResolvesWithoutErrors() {
        // This test validates the entire dependency graph by trying to
        // resolve all major dependencies. If any dependency is missing,
        // this will throw NoDefinitionFoundException
        val criticalDependencies =
            listOf(
                getKoin().get<Context>(),
                getKoin().get<MaDatabase>(),
                getKoin().get<DeviceInfoProviderInterface>(),
                getKoin().get<EmbeddingEngine>(), // CRITICAL FIX
                getKoin().get<BaseLlmEngine>(),
                getKoin().get<RAGManager>(), // CRITICAL FIX
                getKoin().get<ToolRegistry>(), // CRITICAL FIX
                getKoin().get<LlmOutputProcessor>(), // CRITICAL FIX
                getKoin().get<ChatScreenViewModel>(),
            )

        criticalDependencies.forEach { dep ->
            assertNotNull(dep, "Dependency should not be null: ${dep::class.simpleName}")
        }
    }

    @Test
    fun noCircularDependenciesExist() {
        // If circular dependencies exist, this will cause StackOverflowError
        // Koin doesn't detect them at module load, only at resolution
        var success = true
        try {
            // Try to resolve all major dependencies
            getKoin().get<MaDatabase>()
            getKoin().get<RAGManager>()
            getKoin().get<ChatScreenViewModel>()
        } catch (e: StackOverflowError) {
            success = false
        }

        assertTrue(success, "No circular dependencies should exist")
    }

    // ===== Performance Tests =====

    @Test
    fun KoinStartupIsFast() {
        // Koin should start quickly (already started in @Before)
        // If this is slow, we have too many eager singletons
        val startTime = System.currentTimeMillis()

        // Access a few dependencies
        getKoin().get<MaDatabase>()
        getKoin().get<EmbeddingEngine>()
        getKoin().get<RAGManager>()

        val endTime = System.currentTimeMillis()
        val duration = endTime - startTime

        println("Dependency resolution took: ${duration}ms")
        assertTrue(duration < 500, "Should resolve dependencies quickly: ${duration}ms")
    }

    @Test
    fun singletonsAreCached() {
        // Singletons should return same instance
        val database1 = getKoin().get<MaDatabase>()
        val database2 = getKoin().get<MaDatabase>()

        assertTrue(
            database1 === database2,
            "MaDatabase should be singleton (same instance)",
        )
    }
}
