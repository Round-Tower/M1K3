package app.m1k3.ai.assistant.chat.usecase

import app.m1k3.ai.assistant.config.GenerationConstants
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.memory.MemoryManager
import app.m1k3.ai.assistant.platform.DeviceInfoProviderInterface
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.assistant.platform.getMemoryTopK
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.chat.EnrichedContext
import app.m1k3.ai.domain.chat.services.ContextAssembler
import app.m1k3.ai.domain.chat.services.ContextRetrieverInterface
import app.m1k3.ai.domain.passages.Passage
import app.m1k3.ai.domain.passages.usecases.RetrievePassagesUseCase
import app.m1k3.ai.domain.rag.services.IntentClassifier

private val logger = Logger.withTag("ContextRetrievalUseCase")

/**
 * ContextRetrievalUseCase - Retrieves relevant context for AI generation.
 *
 * Orchestrates context retrieval from multiple sources:
 * - Conversation History: Recent messages for multi-turn context
 * - RAG: Retrieves facts from knowledge base based on intent
 * - Memory: Retrieves semantic memories from conversation history
 * - Device: Adapts retrieval to device capabilities
 *
 * **Usage:**
 * ```kotlin
 * val useCase = ContextRetrievalUseCase(
 *     deviceInfo = deviceInfoProvider,
 *     preferences = preferencesStore,
 *     database = database,
 *     projectId = "default",
 *     ragEnricher = ragManager,  // Implements RAGEnricherInterface
 *     memoryManager = memoryManager  // Implements MemoryManagerInterface
 * )
 *
 * val result = useCase.retrieveContext("What is photosynthesis?")
 * // Returns: EnrichedContext with conversation history + RAG facts + memories
 * ```
 *
 * **Design Principles:**
 * - Single Responsibility: Only retrieves context, doesn't generate
 * - Fail-Safe: Individual retrieval failures don't break the flow
 * - Device-Adaptive: Adjusts history and memory limits based on device tier
 * - Interface-based: Uses domain interfaces (RAGEnricherInterface, MemoryManagerInterface)
 */
class ContextRetrievalUseCase(
    private val deviceInfo: DeviceInfoProviderInterface,
    private val preferences: PreferencesStoreInterface,
    private val database: MaDatabase? = null,
    private val projectId: String? = null,
    private val memoryManager: MemoryManager? = null,
    private val passageRetriever: RetrievePassagesUseCase? = null,
    private val contextAssembler: ContextAssembler = ContextAssembler(),
    private val intentClassifier: IntentClassifier = IntentClassifier(),
) : ContextRetrieverInterface {
    /**
     * Retrieve context for a given prompt.
     *
     * @param prompt The user's query
     * @return EnrichedContext containing all retrieved context
     */
    override suspend fun retrieveContext(prompt: String): EnrichedContext {
        val retrievalErrors = mutableListOf<String>()
        var conversationHistory = ""
        var ragContext = ""
        var intentCategory = "GENERAL"
        var ragInfo: String? = null
        var ragSources: String? = null
        var ragConfidence: Double? = null
        var memoryContext = ""

        // 1. Conversation history retrieval (for multi-turn context)
        if (database != null && projectId != null) {
            conversationHistory = retrieveConversationHistory(retrievalErrors)
        }

        // 2. Early intent check - skip RAG for conversational queries
        val (intent, intentConfidence) = intentClassifier.classifyWithConfidence(prompt)
        intentCategory = intent.category
        val shouldRetrieveKnowledge = intentClassifier.requiresKnowledgeRetrieval(intent)

        // 3. Knowledge retrieval via personal-knowledge Passage path.
        if (isRagEnabled() && shouldRetrieveKnowledge) {
            if (passageRetriever != null) {
                val ragResult = retrievePassagesContext(prompt, retrievalErrors)
                ragContext = ragResult.context
                ragInfo = ragResult.ragInfo
                ragSources = ragResult.ragSources
                ragConfidence = ragResult.ragConfidence
            } else {
                logger.w { "Retrieval skipped: passageRetriever not injected" }
            }
        } else {
            when {
                !isRagEnabled() -> {
                    logger.d { "Retrieval disabled in preferences" }
                }

                !shouldRetrieveKnowledge -> {
                    logger.d {
                        "Skipping retrieval for ${intent.category} query (confidence: ${(intentConfidence * 100).toInt()}%)"
                    }
                }
            }
        }

        // 4. Semantic memory retrieval (if available)
        if (memoryManager != null) {
            memoryContext = retrieveMemoryContext(prompt, retrievalErrors)
        }

        // 5. Combine contexts using domain service
        val combinedContext = contextAssembler.assembleContext(conversationHistory, ragContext, memoryContext)

        return EnrichedContext(
            context = combinedContext,
            conversationHistory = conversationHistory,
            intentCategory = intentCategory,
            ragInfo = ragInfo,
            ragSources = ragSources,
            ragConfidence = ragConfidence,
            hasConversationHistory = conversationHistory.isNotEmpty(),
            hasRagContext = ragContext.isNotEmpty(),
            hasMemoryContext = memoryContext.isNotEmpty(),
            retrievalErrors = retrievalErrors.toList(),
        )
    }

    /**
     * Check if RAG is enabled in preferences.
     */
    override fun isRagEnabled(): Boolean = preferences.getBoolean(PreferenceKeys.RAG_ENABLED, true)

    /**
     * Get the memory topK value based on device tier.
     */
    fun getMemoryTopK(): Int = deviceInfo.getMemoryTopK()

    /**
     * Get the number of conversation history messages to include based on device tier.
     * Higher-end devices can handle more context.
     */
    fun getConversationHistoryLimit(): Int {
        val ramGb = deviceInfo.getDeviceRamGB()
        return when {
            ramGb >= 12 -> 10

            // Flagship: last 10 messages (5 turns)
            ramGb >= 8 -> 8

            // High-end: last 8 messages (4 turns)
            ramGb >= 6 -> 6

            // Mid-range: last 6 messages (3 turns)
            else -> 4 // Budget: last 4 messages (2 turns)
        }
    }

    // ===== Private Methods =====

    /**
     * Retrieve recent conversation history for multi-turn context.
     *
     * **Important:** Small models (Gemma 270M) get confused by transcript format.
     * We only extract key topics from USER messages to provide context.
     *
     * **Why no assistant responses?**
     * Including previous assistant responses creates a feedback loop - if the model
     * gives a bad/refusing response, that gets fed back as context and the model
     * continues the refusal pattern. User topics are sufficient for follow-ups.
     */
    private fun retrieveConversationHistory(errors: MutableList<String>): String {
        return try {
            val limit = getConversationHistoryLimit()
            val messages =
                database!!
                    .messageQueries
                    .getRecentMessagesForProject(projectId!!, limit.toLong())
                    .executeAsList()
                    .reversed() // Reverse to get chronological order (oldest first)

            if (messages.isEmpty()) {
                return ""
            }

            // Only extract topics from USER messages (not assistant responses)
            val userMessages = messages.filter { it.role == "user" }

            if (userMessages.isEmpty()) {
                return ""
            }

            // Get meaningful topics (skip greetings)
            val topics =
                userMessages
                    .mapNotNull { msg ->
                        val content = msg.content.trim()
                        if (content.length > 10 && !content.lowercase().matches(Regex("^(hi|hey|hello|what's up|sup)\\b.*"))) {
                            content.take(100)
                        } else {
                            null
                        }
                    }.takeLast(3) // Last 3 meaningful queries

            if (topics.isEmpty()) {
                return ""
            }

            val history = "Recent topics discussed: ${topics.joinToString("; ")}"
            logger.d { "Retrieved context from ${userMessages.size} user messages" }
            history
        } catch (e: Exception) {
            logger.w(e) { "Conversation history retrieval failed" }
            errors += "history: ${e.message ?: e::class.simpleName}"
            ""
        }
    }

    /**
     * Personal-knowledge retrieval path — queries the [RetrievePassagesUseCase]
     * for passages relevant to the user's prompt and formats them as inline context.
     *
     * Returns an empty [RagResult] when no passages match or on any failure —
     * keeps the chat flow resilient to storage/embedding hiccups.
     */
    private suspend fun retrievePassagesContext(
        prompt: String,
        errors: MutableList<String>,
    ): RagResult =
        try {
            val topK = 3
            val passages = passageRetriever!!.execute(prompt, topK)
            if (passages.isEmpty()) {
                RagResult(context = "", ragInfo = null, ragSources = null, ragConfidence = null)
            } else {
                val ctx = formatPassages(passages)
                val info = "📖 ${passages.size} passage${if (passages.size == 1) "" else "s"}"
                RagResult(
                    context = ctx,
                    ragInfo = info,
                    ragSources = passages.map(Passage::sourceId).distinct().joinToString("; "),
                    ragConfidence = null,
                )
            }
        } catch (e: Exception) {
            logger.w(e) { "Passage retrieval failed" }
            errors += "passages: ${e.message ?: e::class.simpleName}"
            RagResult(context = "", ragInfo = null, ragSources = null, ragConfidence = null)
        }

    private fun formatPassages(passages: List<Passage>): String = passages.joinToString(" ") { it.content.trim() }.let { "Context: $it" }

    private suspend fun retrieveMemoryContext(
        prompt: String,
        errors: MutableList<String>,
    ): String =
        try {
            val topK = deviceInfo.getMemoryTopK()
            val result = memoryManager!!.retrieveRelevantMemories(prompt, topK)

            result.getOrNull()?.let { contextResult ->
                if (contextResult.selectedMemories.isNotEmpty()) {
                    contextResult.selectedMemories
                        .take(topK)
                        .joinToString("\n") { memory ->
                            val truncatedContent = memory.content.take(GenerationConstants.MemoryPreview.MAX_CONTENT_LENGTH)
                            val suffix = if (memory.content.length > GenerationConstants.MemoryPreview.MAX_CONTENT_LENGTH) "..." else ""
                            "Memory: $truncatedContent$suffix"
                        }.also {
                            logger.d { "Added ${contextResult.selectedMemories.size} memories to context" }
                        }
                } else {
                    ""
                }
            } ?: ""
        } catch (e: Exception) {
            logger.w(e) { "Memory retrieval failed" }
            errors += "memory: ${e.message ?: e::class.simpleName}"
            ""
        }

    /**
     * Internal result from RAG retrieval.
     */
    private data class RagResult(
        val context: String,
        val ragInfo: String?,
        val ragSources: String?,
        val ragConfidence: Double?,
    )
}

// EnrichedContext is now imported from app.m1k3.ai.domain.chat.EnrichedContext
