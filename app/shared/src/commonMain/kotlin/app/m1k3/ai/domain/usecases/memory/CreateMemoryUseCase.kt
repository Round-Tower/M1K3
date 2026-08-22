package app.m1k3.ai.domain.usecases.memory

import app.m1k3.ai.domain.memory.ConversationContext
import app.m1k3.ai.domain.memory.ImportanceCalculator
import app.m1k3.ai.domain.memory.services.SemanticChunker
import app.m1k3.ai.domain.repositories.EmbeddingRepository
import app.m1k3.ai.domain.repositories.MemoryRepository
import kotlin.time.Clock

/**
 * CreateMemoryUseCase - Orchestrates memory creation from messages
 *
 * Domain use case extracted from SemanticMemoryManager.android.kt.
 * Pure Kotlin, no Android dependencies (Context, Log, etc.).
 *
 * **Philosophy:**
 * Quality over quantity. Only store important content.
 * Chunk semantically, embed efficiently, store reliably.
 *
 * **Orchestration Steps:**
 * ```
 * 1. Calculate importance (ImportanceCalculator)
 *     ↓ (filter: importance >= 0.3)
 * 2. Skip if low importance (< 0.3 threshold)
 *     ↓ (return 0 chunks)
 * 3. Chunk text semantically (SemanticChunker)
 *     ↓ (100-300 token chunks with overlap)
 * 4. Generate embeddings (EmbeddingRepository)
 *     ↓ (384/512-dim vectors)
 * 5. Store in vector index (MemoryRepository)
 *     ↓ (HNSW index + SQLDelight persistence)
 * 6. Return chunk count
 * ```
 *
 * **Importance Threshold (0.3):**
 * - Filters out: greetings, short responses, filler text
 * - Keeps: questions, explanations, technical content, long discussions
 * - Prevents: noise pollution in memory index
 *
 * **Usage:**
 * ```kotlin
 * val createMemory = CreateMemoryUseCase(
 *     memoryRepository = memoryRepo,
 *     embeddingRepository = embeddingRepo,
 *     semanticChunker = chunker,
 *     importanceCalculator = importanceCalc
 * )
 *
 * // Create memory from message
 * createMemory.execute(
 *     messageId = "msg-123",
 *     content = "User asked about photosynthesis in detail...",
 *     projectId = "default",
 *     role = "user"
 * ).onSuccess { chunkCount ->
 *     println("Created $chunkCount memory chunks")
 * }.onFailure { error ->
 *     println("Memory creation failed: ${error.message}")
 * }
 * ```
 */
class CreateMemoryUseCase(
    private val memoryRepository: MemoryRepository,
    private val embeddingRepository: EmbeddingRepository,
    private val semanticChunker: SemanticChunker,
    private val importanceCalculator: ImportanceCalculator
) {
    /**
     * Execute memory creation from message content
     *
     * @param messageId Message ID for linking chunks
     * @param content Message text to create memories from
     * @param projectId Project ID for organization (optional)
     * @param role Message role ("user" or "assistant")
     * @return Result.success(chunkCount) or Result.failure
     */
    suspend fun execute(
        messageId: String,
        content: String,
        projectId: String?,
        role: String
    ): Result<Int> {
        return try {
            // 1. Calculate importance
            val context = ConversationContext(isCurrentConversation = true)
            val importance = importanceCalculator.calculateImportance(content, context)

            // 2. Filter out low-importance content (threshold: 0.3)
            if (importance < IMPORTANCE_THRESHOLD) {
                return Result.success(0) // 0 chunks created (filtered out)
            }

            // 3. Chunk text semantically
            val chunks = semanticChunker.chunkMessage(
                messageContent = content,
                messageId = messageId,
                projectId = projectId,
                timestamp = Clock.System.now().toEpochMilliseconds(),
                role = role
            )

            // Handle empty chunks (blank content or below minimum)
            if (chunks.isEmpty()) {
                return Result.success(0)
            }

            // 4. Generate embeddings for each chunk
            val chunkTexts = chunks.map { it.content }
            val embeddings = embeddingRepository.embedBatch(chunkTexts).getOrThrow()

            // 5. Store chunks with embeddings in repository
            var storedCount = 0
            val totalChunks = chunks.size
            chunks.forEachIndexed { index, chunk ->
                val embedding = embeddings[index]

                // Store chunk with pre-computed embedding directly
                memoryRepository.storeChunkWithEmbedding(
                    messageId = chunk.messageId,
                    content = chunk.content,
                    importance = importance,
                    chunkIndex = index,
                    chunkTotal = totalChunks,
                    chunkTokens = chunk.tokenCount,
                    embedding = embedding,
                    projectId = projectId
                ).onSuccess {
                    storedCount++
                }.onFailure { error ->
                    // Log error but continue processing remaining chunks
                    // In production, might want to aggregate errors
                    return Result.failure(error)
                }
            }

            Result.success(storedCount)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    companion object {
        /**
         * Importance threshold for memory creation
         *
         * Content below this threshold is filtered out to prevent
         * noise pollution in the memory index.
         *
         * - 0.3 = Sweet spot (keeps meaningful content, filters trivial)
         * - 0.2 = Too permissive (includes greetings)
         * - 0.5 = Too strict (misses some useful context)
         */
        private const val IMPORTANCE_THRESHOLD = 0.3f
    }
}
