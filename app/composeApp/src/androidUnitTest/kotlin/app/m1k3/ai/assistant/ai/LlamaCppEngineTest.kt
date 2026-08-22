package app.m1k3.ai.assistant.ai

import androidx.test.core.app.ApplicationProvider
import app.m1k3.ai.assistant.ai.ma.FakeMaInferenceBackend
import app.m1k3.ai.domain.ai.GenerationConfig
import app.m1k3.ai.domain.ai.LlmModel
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * TDD Tests for LlamaCppEngine with Ma inference backend.
 *
 * Uses [FakeMaInferenceBackend] to verify engine behaviour without
 * native code. Uses Robolectric for Android Context.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LlamaCppEngineTest {
    private lateinit var fakeBackend: FakeMaInferenceBackend
    private lateinit var engine: LlamaCppEngine
    private lateinit var tempModelFile: File

    @Before
    fun setUp() {
        fakeBackend = FakeMaInferenceBackend()
        tempModelFile = File.createTempFile("test_model", ".gguf")

        engine =
            LlamaCppEngine(
                context = ApplicationProvider.getApplicationContext(),
                model = LlmModel.Gemma3_1B,
                overrideModelPath = tempModelFile.absolutePath,
                backend = fakeBackend,
                deviceRamGbOverride = 8,
            )
    }

    @After
    fun tearDown() {
        tempModelFile.delete()
    }

    // ===== initialize() =====

    @Test
    fun `initialize calls backend init with resolved model path`() =
        runTest {
            fakeBackend.initHandle = 42L

            val result = engine.initialize()

            assertTrue(result.isSuccess)
            assertTrue(fakeBackend.initCalled)
            assertEquals(tempModelFile.absolutePath, fakeBackend.lastInitPath)
        }

    @Test
    fun `initialize calls backend init with the app's native library dir`() =
        runTest {
            fakeBackend.initHandle = 42L
            val context = ApplicationProvider.getApplicationContext<android.content.Context>()

            engine.initialize()

            // The bridge scans this directory once per process for libggml-cpu-*.so
            // runtime-dispatch variants — see MaInferenceBackend.init's KDoc. A
            // Context is never guaranteed to report a non-null dir (e.g. some test
            // doubles), so the engine always hands the bridge a non-null String.
            assertEquals(context.applicationInfo.nativeLibraryDir ?: "", fakeBackend.lastInitNativeLibDir)
        }

    @Test
    fun `initialize returns failure when backend returns zero handle`() =
        runTest {
            fakeBackend.initHandle = 0L

            val result = engine.initialize()

            assertTrue(result.isFailure)
            assertTrue(result.exceptionOrNull()?.message?.contains("load") == true)
        }

    @Test
    fun `initialize is idempotent - only calls backend once`() =
        runTest {
            fakeBackend.initHandle = 1L

            engine.initialize()
            engine.initialize()

            assertEquals(1, fakeBackend.initCallCount)
        }

    @Test
    fun `initialize after release re-initializes`() =
        runTest {
            fakeBackend.initHandle = 1L
            engine.initialize()
            engine.release()
            engine.initialize()

            assertEquals(2, fakeBackend.initCallCount)
        }

    // ===== generate() =====

    @Test
    fun `generate fails when not initialized`() =
        runTest {
            val result = engine.generate("hello", GenerationConfig())

            assertTrue(result.isFailure)
            assertTrue(result.exceptionOrNull()?.message?.contains("initialize") == true)
        }

    @Test
    fun `generate calls backend with stored handle and prompt`() =
        runTest {
            fakeBackend.initHandle = 99L
            fakeBackend.generateResponse = "Hello world"
            engine.initialize()

            val result = engine.generate("test prompt", GenerationConfig())

            assertTrue(result.isSuccess)
            assertEquals("Hello world", result.getOrThrow().text)
            assertEquals(99L, fakeBackend.lastGenerateHandle)
        }

    @Test
    fun `generate passes temperature from config`() =
        runTest {
            fakeBackend.initHandle = 1L
            engine.initialize()

            engine.generate("prompt", GenerationConfig(temperature = 0.3f))

            assertEquals(0.3f, fakeBackend.lastGenerateTemperature)
        }

    @Test
    fun `generate returns failure on empty response`() =
        runTest {
            fakeBackend.initHandle = 1L
            fakeBackend.generateResponse = ""
            engine.initialize()

            val result = engine.generate("prompt", GenerationConfig())

            assertTrue(result.isFailure)
        }

    @Test
    fun `generate strips stop tokens from response`() =
        runTest {
            fakeBackend.initHandle = 1L
            fakeBackend.generateResponse = "Good answer<end_of_turn>"
            engine.initialize()

            val result = engine.generate("prompt", GenerationConfig())

            assertTrue(result.isSuccess)
            assertEquals("Good answer", result.getOrThrow().text)
        }

    @Test
    fun `generate returns metrics in result`() =
        runTest {
            fakeBackend.initHandle = 1L
            fakeBackend.generateResponse = "Four word response here"
            engine.initialize()

            val result = engine.generate("prompt", GenerationConfig())

            assertTrue(result.isSuccess)
            val genResult = result.getOrThrow()
            assertTrue(genResult.tokensGenerated > 0)
            assertTrue(genResult.inferenceTimeMs >= 0)
        }

    // ===== generateStreaming() =====

    @Test
    fun `generateStreaming fails when not initialized`() =
        runTest {
            val result = engine.generateStreaming("hello", GenerationConfig()) {}

            assertTrue(result.isFailure)
        }

    @Test
    fun `generateStreaming emits true streaming tokens via callback`() =
        runTest {
            fakeBackend.initHandle = 1L
            fakeBackend.generateResponse = "Hello world"
            fakeBackend.streamingTokens = listOf("Hello", " ", "world")
            engine.initialize()

            val received = mutableListOf<String>()
            val result =
                engine.generateStreaming("prompt", GenerationConfig()) { token ->
                    received.add(token)
                }

            assertTrue(result.isSuccess)
            assertEquals(listOf("Hello", " ", "world"), received)
        }

    @Test
    fun `generateStreaming passes onToken callback to backend`() =
        runTest {
            fakeBackend.initHandle = 1L
            fakeBackend.generateResponse = "test"
            engine.initialize()

            engine.generateStreaming("prompt", GenerationConfig()) {}

            // Verify backend was called with a callback (not null)
            assertTrue(fakeBackend.generateCalled)
        }

    @Test
    fun `generateStreaming returns failure on empty response`() =
        runTest {
            fakeBackend.initHandle = 1L
            fakeBackend.generateResponse = ""
            engine.initialize()

            val result = engine.generateStreaming("prompt", GenerationConfig()) {}

            assertTrue(result.isFailure)
        }

    // ===== release() =====

    @Test
    fun `release calls backend release with stored handle`() =
        runTest {
            fakeBackend.initHandle = 55L
            engine.initialize()

            engine.release()

            assertTrue(fakeBackend.releaseCalled)
            assertEquals(55L, fakeBackend.lastReleaseHandle)
        }

    @Test
    fun `release when not initialized does not crash`() {
        // Should not throw even if never initialized
        engine.release()
    }

    // ===== getOptimalMaxTokens() — delegates to InferenceTuning matrix =====

    @Test
    fun `getOptimalMaxTokens returns 2560 for HIGH_END + mini-scale model`() {
        // Default fixture: 8GB RAM (HIGH_END) × Gemma3_1B (parameterCount=1B, isMini).
        // Matrix cell HIGH_END/mini sets maxTokens=2560.
        assertEquals(2560, engine.getOptimalMaxTokens())
    }

    @Test
    fun `getOptimalMaxTokens returns 3072 for FLAGSHIP + mini-scale model`() {
        val highRamEngine =
            LlamaCppEngine(
                context = ApplicationProvider.getApplicationContext(),
                model = LlmModel.Gemma3_1B,
                overrideModelPath = tempModelFile.absolutePath,
                backend = fakeBackend,
                deviceRamGbOverride = 12,
            )
        // FLAGSHIP/mini cell: requestedCtx=8192 capped by model.maxContextTokens=4096,
        // maxTokens=3072 (well under ctx-64).
        assertEquals(3072, highRamEngine.getOptimalMaxTokens())
    }

    @Test
    fun `getOptimalMaxTokens returns 768 for LOW_END device`() {
        val lowRamEngine =
            LlamaCppEngine(
                context = ApplicationProvider.getApplicationContext(),
                model = LlmModel.Gemma3_1B,
                overrideModelPath = tempModelFile.absolutePath,
                backend = fakeBackend,
                deviceRamGbOverride = 2,
            )
        // LOW_END cell is uniform: maxTokens=768 regardless of model size.
        assertEquals(768, lowRamEngine.getOptimalMaxTokens())
    }
}
