package app.m1k3.ai.assistant.chat

import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.history.ConversationRepository
import app.m1k3.ai.assistant.mocks.MockBaseLlmEngine
import app.m1k3.ai.assistant.mocks.MockDeviceInfoProvider
import app.m1k3.ai.assistant.mocks.TestPreferencesStore
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.test.TestDatabaseFactory
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.tools.Tool
import app.m1k3.ai.domain.tools.ToolCall
import app.m1k3.ai.domain.tools.ToolCategory
import app.m1k3.ai.domain.tools.ToolResult
import app.m1k3.ai.domain.tools.services.ToolExecutor
import app.m1k3.ai.domain.tools.services.ToolRegistry
import app.m1k3.ai.domain.usecases.chat.LlmOutputProcessor
import app.m1k3.ai.domain.usecases.chat.ProcessedOutput
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Tests for ChatScreenViewModel tool calling preference behavior.
 *
 * Verifies that:
 * - Tools can be enabled/disabled via preferences
 * - Tool calling respects the TOOLS_ENABLED preference
 * - Legacy path is used when tools are disabled
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatScreenViewModelToolsTest {
    private val testDispatcher = StandardTestDispatcher()
    private val testScope = TestScope()

    @BeforeTest
    fun setup() {
        Dispatchers.setMain(testDispatcher)
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    // ===== isToolCallingEnabled Tests =====

    @Test
    fun `isToolCallingEnabled returns false when TOOLS_ENABLED preference is false`() {
        val prefs = TestPreferencesStore()
        prefs.setBoolean(PreferenceKeys.TOOLS_ENABLED, false)

        val viewModel =
            createViewModel(
                preferences = prefs,
                toolRegistry = FakeToolRegistry(),
                processLlmOutput = FakeLlmOutputProcessor(),
            )

        assertFalse(viewModel.isToolCallingEnabled)
    }

    @Test
    fun `isToolCallingEnabled returns true when TOOLS_ENABLED is true and registry provided`() {
        val prefs = TestPreferencesStore()
        prefs.setBoolean(PreferenceKeys.TOOLS_ENABLED, true)

        val viewModel =
            createViewModel(
                preferences = prefs,
                toolRegistry = FakeToolRegistry(),
                processLlmOutput = FakeLlmOutputProcessor(),
            )

        assertTrue(viewModel.isToolCallingEnabled)
    }

    @Test
    fun `isToolCallingEnabled returns true by default when registry provided`() {
        // Default should be true (opt-out model)
        val prefs = TestPreferencesStore()

        val viewModel =
            createViewModel(
                preferences = prefs,
                toolRegistry = FakeToolRegistry(),
                processLlmOutput = FakeLlmOutputProcessor(),
            )

        assertTrue(viewModel.isToolCallingEnabled)
    }

    @Test
    fun `isToolCallingEnabled returns false when toolRegistry is null`() {
        val prefs = TestPreferencesStore()
        prefs.setBoolean(PreferenceKeys.TOOLS_ENABLED, true)

        val viewModel =
            createViewModel(
                preferences = prefs,
                toolRegistry = null,
                processLlmOutput = FakeLlmOutputProcessor(),
            )

        assertFalse(viewModel.isToolCallingEnabled)
    }

    @Test
    fun `isToolCallingEnabled returns false when processLlmOutput is null`() {
        val prefs = TestPreferencesStore()
        prefs.setBoolean(PreferenceKeys.TOOLS_ENABLED, true)

        val viewModel =
            createViewModel(
                preferences = prefs,
                toolRegistry = FakeToolRegistry(),
                processLlmOutput = null,
            )

        assertFalse(viewModel.isToolCallingEnabled)
    }

    // ===== Model Switch Tests =====

    @Test
    fun `switchModel updates currentModel in state`() =
        runTest {
            val viewModel =
                createViewModel(
                    preferences = TestPreferencesStore(),
                    engineFactory = { MockBaseLlmEngine() },
                )
            viewModel.initializeEngine()
            advanceUntilIdle()

            assertEquals(LlmModel.default, viewModel.uiState.value.currentModel)

            viewModel.switchModel(LlmModel.FalconH1_90M)
            advanceUntilIdle()

            assertEquals(LlmModel.FalconH1_90M, viewModel.uiState.value.currentModel)
        }

    @Test
    fun `switchModel sets engine to Ready on success`() =
        runTest {
            val viewModel =
                createViewModel(
                    preferences = TestPreferencesStore(),
                    engineFactory = { MockBaseLlmEngine() },
                )
            viewModel.initializeEngine()
            advanceUntilIdle()

            viewModel.switchModel(LlmModel.FalconH1_90M)
            advanceUntilIdle()

            assertTrue(viewModel.uiState.value.engineState is EngineState.Ready)
        }

    @Test
    fun `switchModel sets engine to Failed when factory engine fails init`() =
        runTest {
            val viewModel =
                createViewModel(
                    preferences = TestPreferencesStore(),
                    engineFactory = {
                        MockBaseLlmEngine().apply {
                            setInitializeError(RuntimeException("Unsupported GGUF architecture"))
                        }
                    },
                )
            viewModel.initializeEngine()
            advanceUntilIdle()

            viewModel.switchModel(LlmModel.FalconH1_90M)
            advanceUntilIdle()

            assertTrue(viewModel.uiState.value.engineState is EngineState.Failed)
        }

    @Test
    fun `switchModel releases old engine`() =
        runTest {
            val originalEngine = MockBaseLlmEngine()
            val viewModel =
                createViewModel(
                    preferences = TestPreferencesStore(),
                    aiEngine = originalEngine,
                    engineFactory = { MockBaseLlmEngine() },
                )
            viewModel.initializeEngine()
            advanceUntilIdle()

            viewModel.switchModel(LlmModel.FalconH1_90M)
            advanceUntilIdle()

            assertEquals(1, originalEngine.releaseCallCount)
        }

    // ===== TTS Loading State Tests =====

    @Test
    fun `speakMessage sets isLoadingTts before synthesis`() =
        runTest {
            var capturedLoadingState = false
            // Use a lateinit pattern to capture loading state inside callback
            lateinit var vm: ChatScreenViewModel
            vm =
                createViewModel(
                    preferences = TestPreferencesStore(),
                    onSpeakText = { _ ->
                        capturedLoadingState = vm.uiState.value.isLoadingTts
                    },
                )

            vm.speakMessage("Hello")
            advanceUntilIdle()

            // During speak, isLoadingTts should have been true
            assertTrue(capturedLoadingState)
        }

    @Test
    fun `speakMessage clears isLoadingTts after synthesis`() =
        runTest {
            val viewModel =
                createViewModel(
                    preferences = TestPreferencesStore(),
                    onSpeakText = { /* no-op, completes instantly */ },
                )

            viewModel.speakMessage("Hello")
            advanceUntilIdle()

            assertFalse(viewModel.uiState.value.isLoadingTts)
        }

    // ===== Helper Methods =====

    private fun createViewModel(
        preferences: TestPreferencesStore,
        toolRegistry: ToolRegistry? = null,
        processLlmOutput: LlmOutputProcessor? = null,
        aiEngine: MockBaseLlmEngine = MockBaseLlmEngine(),
        engineFactory: ((LlmModel) -> BaseLlmEngine)? = null,
        onSpeakText: (suspend (String) -> Unit)? = null,
    ): ChatScreenViewModel {
        val database = TestDatabaseFactory.createInMemoryDatabase()
        return ChatScreenViewModel(
            aiEngine = aiEngine,
            conversationRepo = ConversationRepository(database),
            database = database,
            deviceInfo = MockDeviceInfoProvider.midRange(),
            preferences = preferences,
            projectId = "test_project",
            memoryManager = null,
            toolRegistry = toolRegistry,
            processLlmOutput = processLlmOutput,
            engineFactory = engineFactory,
            onSpeakText = onSpeakText,
        )
    }

    // ===== Test Doubles =====

    private class FakeToolRegistry : ToolRegistry {
        override fun getAllTools(): List<Tool> = emptyList()

        override fun getToolsByCategory(category: ToolCategory): List<Tool> = emptyList()

        override suspend fun getAvailableTools(): List<Tool> = emptyList()

        override suspend fun getRelevantTools(
            query: String,
            maxTools: Int,
        ): List<Tool> = emptyList()

        override fun findTool(toolId: String): Tool? = null

        override suspend fun isToolAvailable(toolId: String): Boolean = false

        override fun registerTool(
            tool: Tool,
            executor: ToolExecutor,
        ) {}

        override fun getExecutor(toolId: String): ToolExecutor? = null
    }

    private class FakeLlmOutputProcessor : LlmOutputProcessor {
        override suspend fun execute(
            llmOutput: String,
            confirmedToolIds: Set<String>,
        ): ProcessedOutput = ProcessedOutput.TextOnly(llmOutput)

        override fun hasToolCalls(llmOutput: String): Boolean = false

        override fun extractPlainText(llmOutput: String): String = llmOutput
    }
}
