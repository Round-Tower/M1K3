package app.m1k3.ai.assistant.chat.usecase

import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.ai.NativeChatCapable
import app.m1k3.ai.assistant.chat.GenerationConfigBuilder
import app.m1k3.ai.assistant.chat.QueryType
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.ai.GenerationConfig
import app.m1k3.ai.domain.chat.ChatError
import app.m1k3.ai.domain.chat.EnrichedContext
import app.m1k3.ai.domain.chat.GenerationStats
import app.m1k3.ai.domain.chat.LlmOutputSanitizer
import app.m1k3.ai.domain.chat.StreamingThinkTagParser
import app.m1k3.ai.domain.chat.events.ChatEvent
import app.m1k3.ai.domain.chat.events.ChatResponse
import app.m1k3.ai.domain.chat.services.UnifiedPromptBuilder
import app.m1k3.ai.domain.platform.DeviceContext
import app.m1k3.ai.domain.tools.Tool
import app.m1k3.ai.domain.tools.ToolCall
import app.m1k3.ai.domain.tools.ToolCategory
import app.m1k3.ai.domain.tools.ToolResult
import app.m1k3.ai.domain.tools.services.ToolCallGrammarBuilder
import app.m1k3.ai.domain.tools.services.ToolRegistry
import app.m1k3.ai.domain.usecases.chat.LlmOutputProcessor
import app.m1k3.ai.domain.usecases.chat.ProcessedOutput
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.withContext
import kotlin.time.Clock

private val logger = Logger.withTag("ChatWithToolsUseCase")

/**
 * ChatWithToolsUseCase - Orchestrates chat with tool calling capabilities.
 *
 * This use case extends the basic message flow with:
 * 1. Tool schema injection into prompts
 * 2. Tool call detection in LLM responses
 * 3. Tool execution with confirmation handling
 * 4. Result formatting for display
 *
 * **Flow:**
 * ```
 * User Message
 *      │
 *      ▼
 * Context Retrieval (RAG + Memory)
 *      │
 *      ▼
 * Prompt Building (+ Tool Schemas)
 *      │
 *      ▼
 * LLM Generation
 *      │
 *      ▼
 * Tool Detection & Execution
 *      │
 *      ▼
 * Response Formatting
 * ```
 *
 * **Usage:**
 * ```kotlin
 * val useCase = ChatWithToolsUseCase(
 *     aiEngine = engine,
 *     contextRetrieval = contextRetrievalUseCase,
 *     processLlmOutput = processLlmOutputUseCase,
 *     toolRegistry = toolRegistry
 * )
 *
 * useCase.execute("What's my battery level?").collect { event ->
 *     when (event) {
 *         is ChatEvent.Started -> showThinking()
 *         is ChatEvent.ToolsExecuted -> showToolResults(event.results)
 *         is ChatEvent.Complete -> showResponse(event.response)
 *         is ChatEvent.Failed -> showError(event.error)
 *     }
 * }
 * ```
 */
class ChatWithToolsUseCase(
    private val aiEngine: BaseLlmEngine,
    private val contextRetrieval: ContextRetrievalUseCase,
    private val processLlmOutput: LlmOutputProcessor,
    private val toolRegistry: ToolRegistry,
    private val configBuilder: GenerationConfigBuilder? = null,
    private val promptBuilder: UnifiedPromptBuilder? = null,
    private val grammarBuilder: ToolCallGrammarBuilder = ToolCallGrammarBuilder(),
    /** M1K3 system prompt — injected so personality persists across tool-calling path */
    var systemPrompt: String = "",
    /**
     * Whether the current brain reasons in <think> (ThinkingPolicy). Drives the
     * native template's enable_thinking AND the stream parser's start state:
     * with thinking off the template pre-closes the think block, so a parser
     * that starts "in thinking" would swallow the entire answer.
     */
    var thinkingEnabled: Boolean = true,
    /**
     * Live read of the "Web search in chat" setting (Settings → Grounding).
     * Read fresh on every turn — same pattern as [ContextRetrievalUseCase.isRagEnabled] —
     * so toggling it takes effect on the very next message, not the next launch.
     */
    private val webSearchEnabled: () -> Boolean = { true },
) {
    /** Strips web_search from a candidate tool list when the user has turned it off. */
    private fun applyWebSearchGate(tools: List<Tool>): List<Tool> =
        if (webSearchEnabled()) tools else tools.filterNot { it.id == "web_search" }

    /**
     * Execute the chat flow with tool support.
     *
     * @param prompt The user's message
     * @param confirmedToolIds Tools that have been confirmed by user (for re-execution)
     * @return Flow of ChatEvent for state updates
     */
    fun execute(
        prompt: String,
        confirmedToolIds: Set<String> = emptySet(),
        deviceContext: DeviceContext? = null,
    ): Flow<ChatEvent> =
        channelFlow {
            send(ChatEvent.Started)
            logger.i { "Starting chat flow for: ${prompt.take(50)}..." }

            try {
                // 1. Retrieve context (RAG + memory + history)
                send(ChatEvent.RetrievingContext)
                val context = contextRetrieval.retrieveContext(prompt)
                send(ChatEvent.ContextRetrieved(context))
                logger.d { "Context: hasRAG=${context.hasRagContext}, hasMemory=${context.hasMemoryContext}" }

                // 2. Get relevant tools and build prompt with tool schemas
                val relevantTools = applyWebSearchGate(toolRegistry.getRelevantTools(prompt, maxTools = 3))
                println(
                    "DEBUG(ChatWithTools) TOOLS: ${relevantTools.size} relevant for '${prompt.take(40)}': ${relevantTools.map { it.id }}",
                )

                // 2a. NATIVE CHAT path — when the engine supports chat templates
                // and we have tools, let llama.cpp's common_chat_templates_apply do
                // the heavy lifting: model-native prompt shape + grammar + parser.
                val nativeEngine = aiEngine as? NativeChatCapable
                if (nativeEngine != null && relevantTools.isNotEmpty()) {
                    val startTime = Clock.System.now().toEpochMilliseconds()
                    val handled =
                        runNativeChatPath(
                            nativeEngine = nativeEngine,
                            prompt = prompt,
                            context = context,
                            relevantTools = relevantTools,
                            confirmedToolIds = confirmedToolIds,
                            startTime = startTime,
                            scope = this,
                        )
                    if (handled) return@channelFlow
                    logger.w { "Native chat path did not complete; falling through to legacy path" }
                }

                val fullPrompt = buildPromptWithTools(prompt, context, deviceContext, relevantTools)

                // 3. Build generation config
                // When tools are in play, attach a GBNF grammar so the llama.cpp sampler
                // cannot emit malformed tool-call JSON. Engines that don't understand
                // grammar (ML Kit GenAI etc.) ignore this field.
                val queryType = QueryType.fromIntentCategory(context.intentCategory)
                val toolGrammar =
                    if (relevantTools.isNotEmpty()) {
                        grammarBuilder.build(relevantTools).takeIf { it.isNotBlank() }
                    } else {
                        null
                    }
                // Tool turns: FOCUSED temp + tighter topK + minP>0 — see
                // GenerationConfigBuilder.buildForToolInvocation + task #10.
                val config =
                    if (relevantTools.isNotEmpty() && configBuilder != null) {
                        configBuilder.buildForToolInvocation(queryType)
                    } else {
                        configBuilder?.build(queryType = queryType) ?: GenerationConfig()
                    }.copy(grammar = toolGrammar)

                // 4. Generate response with streaming
                send(ChatEvent.Generating)
                val startTime = Clock.System.now().toEpochMilliseconds()
                val accumulated = StringBuilder()
                var tokenCount = 0
                val thinkParser = StreamingThinkTagParser()

                val result =
                    aiEngine.generateStreaming(
                        prompt = fullPrompt,
                        config = config,
                        onToken = { token ->
                            if (token.isNotEmpty()) {
                                accumulated.append(token)
                                tokenCount++
                                thinkParser.feed(token)
                                trySend(
                                    ChatEvent.Streaming(
                                        partialText = thinkParser.visibleText,
                                        tokenCount = tokenCount,
                                        thinkingPartial = thinkParser.thinkingContent,
                                        isThinking = thinkParser.isThinking,
                                    ),
                                )
                            }
                        },
                    )

                result
                    .onSuccess {
                        val duration = Clock.System.now().toEpochMilliseconds() - startTime
                        val rawResponse = accumulated.toString().trim()

                        logger.d { "Generated $tokenCount tokens in ${duration}ms" }

                        // 5. Process for tool calls
                        logger.d { "Raw LLM response (${rawResponse.length} chars): ${rawResponse.take(200)}" }
                        println("DEBUG(ChatWithTools) Raw response (${rawResponse.length} chars): ${rawResponse.take(300)}")

                        val processed = processLlmOutput.execute(rawResponse, confirmedToolIds)
                        logger.d { "Processed output type: ${processed::class.simpleName}" }
                        println("DEBUG(ChatWithTools) Processed: ${processed::class.simpleName}")

                        when (processed) {
                            is ProcessedOutput.TextOnly -> {
                                // Check if the filter selected KNOWLEDGE tools that the model ignored
                                val knowledgeTools = relevantTools.filter { it.category == ToolCategory.KNOWLEDGE }
                                if (knowledgeTools.isNotEmpty()) {
                                    // Force-execute: the model didn't call the tool, but we know it should
                                    println("DEBUG(ChatWithTools) Force-executing ${knowledgeTools.size} KNOWLEDGE tools the model ignored")
                                    val forceResults = forceExecuteTools(knowledgeTools, prompt)

                                    send(
                                        ChatEvent.ToolsExecuted(
                                            results = forceResults,
                                            hasPendingConfirmations = false,
                                        ),
                                    )

                                    val stats = buildStats(tokenCount, duration, context)
                                    val response =
                                        ChatResponse(
                                            text = LlmOutputSanitizer.strip(processed.text),
                                            stats = stats,
                                            context = context,
                                            toolResults = forceResults,
                                            toolResultsFormatted =
                                                forceResults.joinToString("\n") { r ->
                                                    when (r) {
                                                        is ToolResult.Success -> "${r.toolId}: ${r.output}"
                                                        is ToolResult.Failure -> "${r.toolId}: ${r.error.displayMessage}"
                                                        else -> ""
                                                    }
                                                },
                                        )
                                    send(ChatEvent.Complete(response))
                                } else {
                                    // No KNOWLEDGE tools — just text response
                                    val stats = buildStats(tokenCount, duration, context)
                                    val response =
                                        ChatResponse(
                                            text = LlmOutputSanitizer.strip(processed.text),
                                            stats = stats,
                                            context = context,
                                            toolResults = null,
                                        )
                                    send(ChatEvent.Complete(response))
                                }
                            }

                            is ProcessedOutput.WithTools -> {
                                // Tools detected and executed
                                send(
                                    ChatEvent.ToolsExecuted(
                                        results = processed.toolResults,
                                        hasPendingConfirmations = processed.hasPendingConfirmations,
                                    ),
                                )

                                val stats = buildStats(tokenCount, duration, context)
                                val response =
                                    ChatResponse(
                                        text = LlmOutputSanitizer.strip(processed.plainText),
                                        stats = stats,
                                        context = context,
                                        toolResults = processed.toolResults,
                                        toolResultsFormatted = processed.formatResultsForDisplay(),
                                    )
                                send(ChatEvent.Complete(response))
                            }
                        }
                    }.onFailure { e ->
                        logger.e(e) { "Generation failed" }
                        send(ChatEvent.Failed(mapExceptionToError(e)))
                    }
            } catch (e: Exception) {
                logger.e(e) { "Chat flow error" }
                send(ChatEvent.Failed(mapExceptionToError(e)))
            }
        }

    /**
     * NATIVE CHAT PATH — render via the model's own Jinja template,
     * parse output with its trained tool-call shape.
     *
     * Returns true when the path handled the turn end-to-end (Complete sent);
     * false means the caller should fall through to the prompt-engineered path.
     */
    private suspend fun runNativeChatPath(
        nativeEngine: NativeChatCapable,
        prompt: String,
        context: EnrichedContext,
        relevantTools: List<Tool>,
        confirmedToolIds: Set<String>,
        startTime: Long,
        scope: kotlinx.coroutines.channels.ProducerScope<ChatEvent>,
    ): Boolean {
        val userContent =
            if (context.hasContext) {
                "${context.context}\n\n$prompt"
            } else {
                prompt
            }

        val messagesJson = OaiChatSerializer.messagesJson(systemPrompt.takeIf { it.isNotBlank() }, userContent)
        val toolsJson = OaiChatSerializer.toolsJson(relevantTools)

        logger.i { "Native chat: ${relevantTools.size} tools, ${messagesJson.length}c msgs, ${toolsJson.length}c tools" }
        println("DEBUG(ChatWithTools) NATIVE path: tools=${relevantTools.map { it.id }}")

        scope.send(ChatEvent.Generating)

        var tokenCount = 0
        // Qwen's native chat template ends the prompt with
        //   <|im_start|>assistant\n<think>\n
        // so the model begins generating INSIDE a think block — the `<think>`
        // opener never appears in the token stream. Start the parser already
        // in thinking mode so reasoning routes to thinkingContent and the
        // ThinkingPill gets populated; visible body picks up after </think>.
        val thinkParser = StreamingThinkTagParser(startInThinking = thinkingEnabled)
        // Native path ALWAYS has tools here (caller gates on relevantTools.isNotEmpty()).
        // Use the tool-focused config so small models actually trigger <tool_call>.
        val queryType = QueryType.fromIntentCategory(context.intentCategory)
        val config =
            (configBuilder?.buildForToolInvocation(queryType) ?: GenerationConfig())
                .copy(grammar = null) // native path generates its own grammar

        val result =
            nativeEngine.generateChatNative(
                messagesJson = messagesJson,
                toolsJson = toolsJson,
                config = config,
                enableThinking = thinkingEnabled,
                onToken = { token ->
                    if (token.isNotEmpty()) {
                        tokenCount++
                        thinkParser.feed(token)
                        scope.trySend(
                            ChatEvent.Streaming(
                                partialText = thinkParser.visibleText,
                                tokenCount = tokenCount,
                                thinkingPartial = thinkParser.thinkingContent,
                                isThinking = thinkParser.isThinking,
                            ),
                        )
                    }
                },
            )

        return result.fold(
            onSuccess = { output ->
                val duration = Clock.System.now().toEpochMilliseconds() - startTime
                logger.i {
                    "Native chat done: ${output.content.length}c content, " +
                        "${output.toolCalls.size} tool calls, ${duration}ms"
                }
                println("DEBUG(ChatWithTools) NATIVE result: tools=${output.toolCalls.map { it.name }}")

                if (output.toolCalls.isEmpty()) {
                    // Model answered without tools — hand to the ignored-KNOWLEDGE fallback.
                    val knowledgeTools = relevantTools.filter { it.category == ToolCategory.KNOWLEDGE }
                    val results =
                        if (knowledgeTools.isNotEmpty()) {
                            forceExecuteTools(knowledgeTools, prompt).also { r ->
                                scope.send(ChatEvent.ToolsExecuted(results = r, hasPendingConfirmations = false))
                            }
                        } else {
                            null
                        }
                    val stats = buildStats(tokenCount, duration, context)
                    // Strip any leftover <think>/<tool_call> tags — common_chat_parse
                    // occasionally reports 0 tool calls while the raw stream still
                    // contains the XML scaffolding the model tried to emit.
                    scope.send(
                        ChatEvent.Complete(
                            ChatResponse(
                                text = LlmOutputSanitizer.strip(output.content),
                                stats = stats,
                                context = context,
                                toolResults = results,
                                toolResultsFormatted =
                                    results?.joinToString("\n") { r ->
                                        when (r) {
                                            is ToolResult.Success -> "${r.toolId}: ${r.output}"
                                            is ToolResult.Failure -> "${r.toolId}: ${r.error.displayMessage}"
                                            else -> ""
                                        }
                                    },
                            ),
                        ),
                    )
                    true
                } else {
                    // Execute each native tool call
                    val toolResults = executeNativeToolCalls(output.toolCalls)
                    scope.send(ChatEvent.ToolsExecuted(results = toolResults, hasPendingConfirmations = false))
                    val stats = buildStats(tokenCount, duration, context)
                    scope.send(
                        ChatEvent.Complete(
                            ChatResponse(
                                text = LlmOutputSanitizer.strip(output.content),
                                stats = stats,
                                context = context,
                                toolResults = toolResults,
                                toolResultsFormatted =
                                    toolResults.joinToString("\n") { r ->
                                        when (r) {
                                            is ToolResult.Success -> "${r.toolId}: ${r.output}"
                                            is ToolResult.Failure -> "${r.toolId}: ${r.error.displayMessage}"
                                            else -> ""
                                        }
                                    },
                            ),
                        ),
                    )
                    true
                }
            },
            onFailure = { e ->
                logger.e(e) { "Native chat path failed" }
                false // caller falls through
            },
        )
    }

    /**
     * Run each tool emitted by the native parser. Arguments come as JSON strings
     * (from common_chat_parse) and are converted to `Map<String, String>` for
     * the executor interface, which assumes stringified values.
     */
    private suspend fun executeNativeToolCalls(calls: List<app.m1k3.ai.assistant.ai.NativeToolCall>): List<ToolResult> =
        withContext(Dispatchers.IO) {
            calls.mapNotNull { call ->
                val executor = toolRegistry.getExecutor(call.name) ?: return@mapNotNull null
                val args = parseArgumentsToMap(call.arguments)
                val toolCall = ToolCall(toolId = call.name, arguments = args, rawText = call.arguments)
                try {
                    executor.execute(toolCall)
                } catch (e: Exception) {
                    logger.e(e) { "Native tool '${call.name}' failed" }
                    null
                }
            }
        }

    private fun parseArgumentsToMap(argsJson: String): Map<String, String> {
        if (argsJson.isBlank()) return emptyMap()
        return try {
            val parsed =
                kotlinx.serialization.json.Json
                    .parseToJsonElement(argsJson)
            if (parsed !is kotlinx.serialization.json.JsonObject) return emptyMap()
            parsed.mapValues { (_, v) ->
                when (v) {
                    is kotlinx.serialization.json.JsonPrimitive -> v.content
                    else -> v.toString()
                }
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    /**
     * Force-execute KNOWLEDGE tools when the model ignores them.
     *
     * Small models (Qwen 0.6B) often answer from memory instead of calling
     * web_search. When the ToolFilter selected KNOWLEDGE tools but the model
     * didn't call them, we execute them directly with the user's query.
     */
    private suspend fun forceExecuteTools(
        tools: List<Tool>,
        userQuery: String,
    ): List<ToolResult> =
        withContext(Dispatchers.IO) {
            tools.mapNotNull { tool ->
                val executor = toolRegistry.getExecutor(tool.id) ?: return@mapNotNull null
                val call =
                    ToolCall(
                        toolId = tool.id,
                        arguments = mapOf("query" to userQuery),
                        rawText = "[force-injected by ToolFilter]",
                    )
                try {
                    executor.execute(call)
                } catch (e: Exception) {
                    logger.e(e) { "Force-execute ${tool.id} failed" }
                    null
                }
            }
        }

    private suspend fun buildPromptWithTools(
        userPrompt: String,
        context: EnrichedContext,
        deviceContext: DeviceContext? = null,
        relevantTools: List<Tool>? = null,
    ): String {
        val tools = relevantTools ?: applyWebSearchGate(toolRegistry.getRelevantTools(userPrompt, maxTools = 3))
        logger.i { "TOOLS: ${tools.size} relevant for '${userPrompt.take(40)}': ${tools.map { it.id }}" }
        logger.i { "SYSTEM: ${systemPrompt.take(80)}..." }
        logger.i { "BUILDER: promptBuilder=${promptBuilder != null}" }

        // Use unified builder if available — pass system prompt for M1K3 personality
        promptBuilder?.let { builder ->
            return builder.build(
                userPrompt = userPrompt,
                context = context,
                tools = tools,
                systemPrompt = systemPrompt,
                deviceContext = deviceContext,
            )
        }

        // Legacy fallback (for backwards compatibility)
        return buildString {
            if (context.hasContext) {
                appendLine(context.context)
                appendLine()
            }

            if (tools.isNotEmpty()) {
                appendLine("You have access to the following tools:")
                tools.forEach { tool ->
                    appendLine("- ${tool.id}: ${tool.description}")
                    if (tool.parameters.isNotEmpty()) {
                        tool.parameters.forEach { param ->
                            val req = if (param.required) "required" else "optional"
                            appendLine("    ${param.name} ($req): ${param.description}")
                        }
                    }
                }
                appendLine()
                appendLine("To use a tool, respond with JSON: {\"tool\": \"tool_id\", \"args\": {...}}")
                appendLine()
            }

            append("User: $userPrompt")
        }
    }

    private fun buildStats(
        tokenCount: Int,
        durationMs: Long,
        context: EnrichedContext,
    ): GenerationStats {
        val tokensPerSecond = if (durationMs > 0) tokenCount * 1000f / durationMs else 0f
        return GenerationStats(
            tokenCount = tokenCount,
            durationMs = durationMs,
            tokensPerSecond = tokensPerSecond,
            ragInfo = context.ragInfo,
            ragSources = context.ragSources,
            ragConfidence = context.ragConfidence,
        )
    }

    private fun mapExceptionToError(e: Throwable): ChatError {
        val message = e.message ?: "Unknown error"
        return when {
            message.contains("OutOfMemory", ignoreCase = true) -> ChatError.OutOfMemory(message)
            message.contains("timeout", ignoreCase = true) -> ChatError.Timeout(message)
            message.contains("model", ignoreCase = true) -> ChatError.ModelError(message)
            else -> ChatError.Unknown(message)
        }
    }
}

// ChatEvent and ChatResponse are now imported from domain
