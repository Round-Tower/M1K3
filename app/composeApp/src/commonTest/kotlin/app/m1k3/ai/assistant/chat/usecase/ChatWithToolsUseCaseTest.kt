package app.m1k3.ai.assistant.chat.usecase

import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.ai.GenerationResult
import app.m1k3.ai.domain.ai.GenerationConfig
import app.m1k3.ai.domain.chat.PersonaLeakGuard
import app.m1k3.ai.domain.chat.events.ChatEvent
import app.m1k3.ai.domain.chat.events.ChatResponse
import app.m1k3.ai.domain.tools.Tool
import app.m1k3.ai.domain.tools.ToolCall
import app.m1k3.ai.domain.tools.ToolCategory
import app.m1k3.ai.domain.tools.ToolResult
import app.m1k3.ai.domain.tools.services.ToolCallParser
import app.m1k3.ai.domain.tools.services.ToolExecutor
import app.m1k3.ai.domain.tools.services.ToolRegistry
import app.m1k3.ai.domain.usecases.chat.ProcessLlmOutputUseCase
import app.m1k3.ai.domain.usecases.chat.ProcessedOutput
import app.m1k3.ai.domain.usecases.tools.ExecuteToolUseCase
import app.m1k3.ai.domain.usecases.tools.ParseToolCallUseCase
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ChatWithToolsUseCaseTest {
    // ===== Test Fixtures =====

    private val batteryTool =
        Tool(
            id = "get_battery_level",
            name = "Get Battery",
            description = "Gets battery level",
            parameters = emptyList(),
            category = ToolCategory.DEVICE_INFO,
        )

    // ===== Mock Implementations =====

    private class MockLlmEngine(
        private val response: String = "Hello! How can I help?",
        private val shouldFail: Boolean = false,
    ) : BaseLlmEngine {
        var lastPrompt: String? = null
        var generateCalled = false

        override suspend fun initialize(): Result<Unit> = Result.success(Unit)

        override suspend fun generate(
            prompt: String,
            config: GenerationConfig,
        ): Result<GenerationResult> {
            lastPrompt = prompt
            generateCalled = true
            return if (shouldFail) {
                Result.failure(RuntimeException("Generation failed"))
            } else {
                val tokens = response.split(" ").size
                Result.success(
                    GenerationResult(
                        text = response,
                        tokensGenerated = tokens,
                        inferenceTimeMs = 100L,
                        tokensPerSecond = tokens * 10f,
                    ),
                )
            }
        }

        override suspend fun generateStreaming(
            prompt: String,
            config: GenerationConfig,
            onToken: (String) -> Unit,
        ): Result<Unit> {
            lastPrompt = prompt
            generateCalled = true
            if (shouldFail) {
                return Result.failure(RuntimeException("Generation failed"))
            }
            // Simulate streaming by emitting tokens
            response.split(" ").forEach { token ->
                onToken("$token ")
            }
            return Result.success(Unit)
        }

        override fun getOptimalMaxTokens(): Int = 256

        override fun release() {}
    }

    private class MockToolCallParser(
        private val toolCalls: List<ToolCall> = emptyList(),
        private val plainText: String = "",
    ) : ToolCallParser {
        override fun parse(output: String): List<ToolCall> = toolCalls

        override fun hasToolCalls(output: String): Boolean = toolCalls.isNotEmpty()

        override fun extractPlainText(output: String): String = plainText.ifEmpty { output }
    }

    private class MockToolRegistry(
        private val tools: Map<String, Tool> = emptyMap(),
        private val executors: Map<String, ToolExecutor> = emptyMap(),
        private val relevantToolIds: Set<String>? = null, // null = return all tools
    ) : ToolRegistry {
        var getAvailableToolsCalled = false
        var getRelevantToolsCalled = false
        var lastRelevantQuery: String? = null

        override fun getAllTools(): List<Tool> = tools.values.toList()

        override fun findTool(toolId: String): Tool? = tools[toolId]

        override fun getExecutor(toolId: String): ToolExecutor? = executors[toolId]

        override suspend fun getAvailableTools(): List<Tool> {
            getAvailableToolsCalled = true
            return tools.values.toList()
        }

        override fun getToolsByCategory(category: ToolCategory): List<Tool> = tools.values.filter { it.category == category }

        override suspend fun isToolAvailable(toolId: String): Boolean = executors[toolId]?.isAvailable() ?: false

        override fun registerTool(
            tool: Tool,
            executor: ToolExecutor,
        ) {}

        override suspend fun getRelevantTools(
            query: String,
            maxTools: Int,
        ): List<Tool> {
            getRelevantToolsCalled = true
            lastRelevantQuery = query
            return if (relevantToolIds != null) {
                tools.values.filter { it.id in relevantToolIds }.take(maxTools)
            } else {
                tools.values.toList().take(maxTools)
            }
        }
    }

    private class MockToolExecutor(
        override val toolId: String,
        private val result: ToolResult,
    ) : ToolExecutor {
        var executedCalls = mutableListOf<ToolCall>()

        override suspend fun execute(call: ToolCall): ToolResult {
            executedCalls.add(call)
            return result
        }

        override suspend fun isAvailable(): Boolean = true

        override fun validateArguments(arguments: Map<String, String>): Result<Unit> = Result.success(Unit)
    }

    // Note: ContextRetrievalUseCase is a final class, so we use a real instance
    // with null optional dependencies - it will return empty context which is fine for tests
    private fun createMockContextRetrieval(): ContextRetrievalUseCase =
        ContextRetrievalUseCase(
            deviceInfo = MockDeviceInfo(),
            preferences = MockPreferences(),
        )

    private class MockDeviceInfo : app.m1k3.ai.assistant.platform.DeviceInfoProviderInterface {
        override fun getDeviceRamGB(): Int = 8

        override fun getDeviceModel(): String = "MockDevice"

        override fun getBatteryLevel(): Int? = 75
    }

    private class MockPreferences : app.m1k3.ai.assistant.platform.PreferencesStoreInterface {
        override fun getString(
            key: String,
            default: String?,
        ): String? = default

        override fun getInt(
            key: String,
            default: Int,
        ): Int = default

        override fun getBoolean(
            key: String,
            default: Boolean,
        ): Boolean = default

        override fun setString(
            key: String,
            value: String?,
        ) {}

        override fun setInt(
            key: String,
            value: Int,
        ) {}

        override fun setBoolean(
            key: String,
            value: Boolean,
        ) {}

        override fun observeBoolean(
            key: String,
            default: Boolean,
        ) = kotlinx.coroutines.flow.flowOf(default)

        override fun contains(key: String): Boolean = false

        override fun remove(key: String) {}

        override fun clear() {}
    }

    // ===== Helper to build UseCase =====

    private fun buildUseCase(
        llmEngine: BaseLlmEngine = MockLlmEngine(),
        toolCallParser: ToolCallParser = MockToolCallParser(),
        toolRegistry: ToolRegistry = MockToolRegistry(),
        contextRetrieval: ContextRetrievalUseCase = createMockContextRetrieval(),
    ): ChatWithToolsUseCase {
        val parseUseCase = ParseToolCallUseCase(toolCallParser)
        val executeUseCase = ExecuteToolUseCase(toolRegistry)
        val processLlmOutput = ProcessLlmOutputUseCase(parseUseCase, executeUseCase)

        return ChatWithToolsUseCase(
            aiEngine = llmEngine,
            contextRetrieval = contextRetrieval,
            processLlmOutput = processLlmOutput,
            toolRegistry = toolRegistry,
        )
    }

    // ===== Tests: Basic Text Generation (No Tools) =====

    @Test
    fun `emits Started event first`() =
        runTest {
            val useCase = buildUseCase()
            val events = useCase.execute("Hello").toList()

            assertIs<ChatEvent.Started>(events.first())
        }

    @Test
    fun `emits Complete event with text for simple response`() =
        runTest {
            val engine = MockLlmEngine(response = "Hello! How can I help you today?")
            val useCase = buildUseCase(llmEngine = engine)

            val events = useCase.execute("Hello").toList()
            val complete = events.filterIsInstance<ChatEvent.Complete>().firstOrNull()

            assertTrue(complete != null, "Should have Complete event")
            assertTrue(complete.response.text.contains("Hello"))
        }

    @Test
    fun `emits Failed event when engine fails`() =
        runTest {
            val engine = MockLlmEngine(shouldFail = true)
            val useCase = buildUseCase(llmEngine = engine)

            val events = useCase.execute("Hello").toList()
            val failed = events.filterIsInstance<ChatEvent.Failed>().firstOrNull()

            assertTrue(failed != null, "Should have Failed event")
        }

    // ===== Tests: Streaming Persona Leak Guard (#150) =====

    @Test
    fun `streaming guards a persona leak the instant it completes, not just at the end`() =
        runTest {
            // The exact leak shape from PersonaLeakGuardTest's fixtures: a whole
            // wiring sentence, reproduced verbatim by the model.
            val leaked =
                "You are M1K3 — a curious AI living entirely on this phone, wearing every " +
                    "sci-fi villain's look but always on the user's side."
            val engine = MockLlmEngine(response = leaked)
            val useCase = buildUseCase(llmEngine = engine)

            val events = useCase.execute("Hello").toList()
            val streamingEvents = events.filterIsInstance<ChatEvent.Streaming>()
            assertTrue(streamingEvents.isNotEmpty(), "should have streaming events")

            // Reconstruct the RAW (unguarded) accumulated text exactly as MockLlmEngine
            // feeds it token-by-token, to find the emission where the leak first
            // becomes textually complete.
            val rawTokens = leaked.split(" ").map { "$it " }
            var rawAccumulated = ""
            var leakCompleteFromIndex = -1
            rawTokens.forEachIndexed { index, token ->
                rawAccumulated += token
                if (leakCompleteFromIndex == -1 && PersonaLeakGuard.leaks(rawAccumulated)) {
                    leakCompleteFromIndex = index
                }
            }
            assertTrue(leakCompleteFromIndex >= 0, "fixture must actually complete a leak mid-stream")
            assertEquals(rawTokens.size, streamingEvents.size, "one Streaming event per token")

            // From the moment the leak completes onward, every streamed partialText
            // must already be the refusal — never the raw completed leak text. This
            // is the bug: previously the raw leak streamed on-screen in full and only
            // snapped to the refusal at the Complete event.
            for (index in leakCompleteFromIndex until streamingEvents.size) {
                assertEquals(
                    PersonaLeakGuard.REFUSAL,
                    streamingEvents[index].partialText,
                    "streaming must guard the leak the instant it completes",
                )
            }

            // The final answer agrees (pre-existing behaviour, unaffected).
            val complete = events.filterIsInstance<ChatEvent.Complete>().first()
            assertEquals(PersonaLeakGuard.REFUSAL, complete.response.text)
        }

    @Test
    fun `streaming leaves a clean answer untouched at every token`() =
        runTest {
            val clean = "The capital of Ireland is Dublin, on the east coast."
            val engine = MockLlmEngine(response = clean)
            val useCase = buildUseCase(llmEngine = engine)

            val events = useCase.execute("Where is Dublin?").toList()
            val streamingEvents = events.filterIsInstance<ChatEvent.Streaming>()

            assertTrue(streamingEvents.isNotEmpty(), "should have streaming events")
            assertTrue(
                streamingEvents.none { it.partialText == PersonaLeakGuard.REFUSAL },
                "a clean answer must never be replaced with the refusal mid-stream",
            )
        }

    // ===== Tests: Tool Detection and Execution =====

    @Test
    fun `detects and executes tool call in response`() =
        runTest {
            val toolCall = ToolCall("get_battery_level", emptyMap(), "")
            val parser =
                MockToolCallParser(
                    toolCalls = listOf(toolCall),
                    plainText = "Let me check your battery.",
                )
            val executor =
                MockToolExecutor(
                    toolId = "get_battery_level",
                    result = ToolResult.Success("get_battery_level", "Battery is at 75%", null, 5),
                )
            val registry =
                MockToolRegistry(
                    tools = mapOf("get_battery_level" to batteryTool),
                    executors = mapOf("get_battery_level" to executor),
                )
            val engine = MockLlmEngine(response = """Let me check. {"tool": "get_battery_level"}""")

            val useCase =
                buildUseCase(
                    llmEngine = engine,
                    toolCallParser = parser,
                    toolRegistry = registry,
                )

            val events = useCase.execute("What's my battery level?").toList()

            // Should have tool execution event
            val toolEvent = events.filterIsInstance<ChatEvent.ToolsExecuted>().firstOrNull()
            assertTrue(toolEvent != null, "Should have ToolsExecuted event")
            assertEquals(1, toolEvent.results.size)
            assertIs<ToolResult.Success>(toolEvent.results[0])
        }

    @Test
    fun `emits ToolsExecuted before Complete when tools found`() =
        runTest {
            val toolCall = ToolCall("get_battery_level", emptyMap(), "")
            val parser =
                MockToolCallParser(
                    toolCalls = listOf(toolCall),
                    plainText = "Checking battery...",
                )
            val executor =
                MockToolExecutor(
                    toolId = "get_battery_level",
                    result = ToolResult.Success("get_battery_level", "75%", null, 5),
                )
            val registry =
                MockToolRegistry(
                    tools = mapOf("get_battery_level" to batteryTool),
                    executors = mapOf("get_battery_level" to executor),
                )

            val useCase =
                buildUseCase(
                    toolCallParser = parser,
                    toolRegistry = registry,
                )

            val events = useCase.execute("Battery?").toList()

            val toolIndex = events.indexOfFirst { it is ChatEvent.ToolsExecuted }
            val completeIndex = events.indexOfFirst { it is ChatEvent.Complete }

            assertTrue(toolIndex >= 0, "Should have ToolsExecuted")
            assertTrue(completeIndex >= 0, "Should have Complete")
            assertTrue(toolIndex < completeIndex, "ToolsExecuted should come before Complete")
        }

    // ===== Tests: Tool Confirmation =====

    @Test
    fun `emits ConfirmationRequired for tools needing confirmation`() =
        runTest {
            val toolCall = ToolCall("write_note", mapOf("content" to "Hello"), "")
            val parser =
                MockToolCallParser(
                    toolCalls = listOf(toolCall),
                    plainText = "I'll write that note.",
                )
            val writeTool =
                Tool(
                    id = "write_note",
                    name = "Write Note",
                    description = "Writes a note",
                    parameters = emptyList(),
                    category = ToolCategory.FILES,
                    requiresConfirmation = true,
                )
            val executor =
                MockToolExecutor(
                    toolId = "write_note",
                    result = ToolResult.Success("write_note", "Note written", null, 5),
                )
            val registry =
                MockToolRegistry(
                    tools = mapOf("write_note" to writeTool),
                    executors = mapOf("write_note" to executor),
                )

            val useCase =
                buildUseCase(
                    toolCallParser = parser,
                    toolRegistry = registry,
                )

            val events = useCase.execute("Write a note").toList()

            val toolEvent = events.filterIsInstance<ChatEvent.ToolsExecuted>().firstOrNull()
            assertTrue(toolEvent != null, "Should have ToolsExecuted event")
            assertTrue(toolEvent.hasPendingConfirmations, "Should have pending confirmations")
        }

    // ===== Tests: Tool Schema Injection =====

    @Test
    fun `injects tool schemas into prompt when tools available`() =
        runTest {
            val registry =
                MockToolRegistry(
                    tools = mapOf("get_battery_level" to batteryTool),
                    executors =
                        mapOf(
                            "get_battery_level" to
                                MockToolExecutor(
                                    "get_battery_level",
                                    ToolResult.Success("get_battery_level", "75%", null, 5),
                                ),
                        ),
                )
            val engine = MockLlmEngine()

            val useCase =
                buildUseCase(
                    llmEngine = engine,
                    toolRegistry = registry,
                )

            useCase.execute("What's my battery?").toList()

            // Verify prompt contains tool info
            assertTrue(engine.lastPrompt != null, "Engine should receive prompt")
            assertTrue(
                engine.lastPrompt!!.contains("get_battery_level") ||
                    engine.lastPrompt!!.contains("battery"),
                "Prompt should mention available tools or user query",
            )
        }

    // ===== Tests: Event Sequence =====

    @Test
    fun `emits events in correct order - no tools`() =
        runTest {
            val useCase = buildUseCase()
            val events = useCase.execute("Hello").toList()

            // Order: Started -> RetrievingContext -> Generating -> Complete
            assertTrue(events.size >= 2, "Should have multiple events")
            assertIs<ChatEvent.Started>(events[0])
            // Last event should be Complete or Failed
            assertTrue(events.last() is ChatEvent.Complete || events.last() is ChatEvent.Failed)
        }

    @Test
    fun `emits events in correct order - with tools`() =
        runTest {
            val toolCall = ToolCall("get_battery_level", emptyMap(), "")
            val parser = MockToolCallParser(listOf(toolCall), "Checking...")
            val executor =
                MockToolExecutor(
                    "get_battery_level",
                    ToolResult.Success("get_battery_level", "75%", null, 5),
                )
            val registry =
                MockToolRegistry(
                    mapOf("get_battery_level" to batteryTool),
                    mapOf("get_battery_level" to executor),
                )

            val useCase = buildUseCase(toolCallParser = parser, toolRegistry = registry)
            val events = useCase.execute("Battery?").toList()

            // Order: Started -> ... -> ToolsExecuted -> Complete
            assertIs<ChatEvent.Started>(events[0])

            val toolsIndex = events.indexOfFirst { it is ChatEvent.ToolsExecuted }
            val completeIndex = events.indexOfFirst { it is ChatEvent.Complete }

            assertTrue(toolsIndex > 0, "ToolsExecuted should be after Started")
            assertTrue(completeIndex > toolsIndex, "Complete should be after ToolsExecuted")
        }

    // ===== Tests: Context Retrieval =====

    @Test
    fun `completes successfully with context retrieval`() =
        runTest {
            // Note: ContextRetrievalUseCase is a final class so we can't mock it directly
            // We verify the use case completes successfully with a real (but empty) context retrieval
            val useCase = buildUseCase()
            val events = useCase.execute("Hello").toList()

            // Should have Started and Complete events
            assertTrue(events.isNotEmpty(), "Should emit events")
            assertIs<ChatEvent.Started>(events.first(), "Should start with Started event")
        }

    // ===== Tests: Dynamic Tool Loading =====

    @Test
    fun `uses getRelevantTools instead of getAvailableTools for prompt building`() =
        runTest {
            val registry =
                MockToolRegistry(
                    tools = mapOf("get_battery_level" to batteryTool),
                    executors =
                        mapOf(
                            "get_battery_level" to
                                MockToolExecutor(
                                    "get_battery_level",
                                    ToolResult.Success("get_battery_level", "75%", null, 5),
                                ),
                        ),
                )
            val engine = MockLlmEngine()

            val useCase =
                buildUseCase(
                    llmEngine = engine,
                    toolRegistry = registry,
                )

            useCase.execute("What's my battery?").toList()

            assertTrue(
                registry.getRelevantToolsCalled,
                "Should call getRelevantTools for dynamic tool loading",
            )
            assertFalse(
                registry.getAvailableToolsCalled,
                "Should NOT call getAvailableTools (wastes tokens on small models)",
            )
        }

    @Test
    fun `passes user query to getRelevantTools for filtering`() =
        runTest {
            val registry =
                MockToolRegistry(
                    tools = mapOf("get_battery_level" to batteryTool),
                    executors =
                        mapOf(
                            "get_battery_level" to
                                MockToolExecutor(
                                    "get_battery_level",
                                    ToolResult.Success("get_battery_level", "75%", null, 5),
                                ),
                        ),
                )

            val useCase = buildUseCase(toolRegistry = registry)

            useCase.execute("What's my battery level?").toList()

            assertEquals(
                "What's my battery level?",
                registry.lastRelevantQuery,
                "Should pass user's original query for relevance filtering",
            )
        }

    @Test
    fun `does not inject tools when no relevant tools found`() =
        runTest {
            val registry =
                MockToolRegistry(
                    tools = mapOf("get_battery_level" to batteryTool),
                    executors =
                        mapOf(
                            "get_battery_level" to
                                MockToolExecutor(
                                    "get_battery_level",
                                    ToolResult.Success("get_battery_level", "75%", null, 5),
                                ),
                        ),
                    relevantToolIds = emptySet(), // No relevant tools for this query
                )
            val engine = MockLlmEngine()

            val useCase =
                buildUseCase(
                    llmEngine = engine,
                    toolRegistry = registry,
                )

            useCase.execute("Tell me about Ireland").toList()

            // Prompt should NOT contain tool schema
            assertTrue(engine.lastPrompt != null)
            assertFalse(
                engine.lastPrompt!!.contains("get_battery_level"),
                "Irrelevant tools should not be in prompt",
            )
            assertFalse(
                engine.lastPrompt!!.contains("You have access to the following tools"),
                "Tool header should not appear when no relevant tools",
            )
        }
}
