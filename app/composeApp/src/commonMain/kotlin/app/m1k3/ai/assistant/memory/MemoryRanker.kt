package app.m1k3.ai.assistant.memory

import app.m1k3.ai.assistant.database.MemoryMetadata
import app.m1k3.ai.domain.repositories.VectorSearchResult
import kotlin.time.Clock
import kotlin.math.exp

/**
 * M1K3 - Memory Ranker
 *
 * Composite ranking system for selecting optimal memories for AI context.
 * Balances semantic relevance, recency, importance, and access patterns.
 *
 * **Philosophy:**
 * - Not all memories are equal - context quality > quantity
 * - Recent + important + frequently accessed = valuable context
 * - Semantic similarity alone is insufficient (may miss important context)
 *
 * **Ranking Formula:**
 * ```
 * score = 0.40 × similarity    // Semantic relevance (vector search)
 *       + 0.20 × recency       // Temporal context (recent = relevant)
 *       + 0.30 × importance    // Content importance (quality filter)
 *       + 0.10 × access_freq   // Popularity (what gets used)
 * ```
 *
 * **Example Scoring:**
 * ```
 * Memory A: similarity=0.95, recency=0.80, importance=0.70, access=0.50
 * → score = (0.40×0.95) + (0.20×0.80) + (0.30×0.70) + (0.10×0.50) = 0.79
 *
 * Memory B: similarity=0.60, recency=0.95, importance=0.90, access=0.75
 * → score = (0.40×0.60) + (0.20×0.95) + (0.30×0.90) + (0.10×0.75) = 0.73
 *
 * Memory A wins despite lower importance (higher semantic relevance)
 * ```
 *
 * **Token Budget Management:**
 * - Max context window: 24,576 tokens (SmolLM2 safe limit)
 * - Reserve: System prompt (500) + current turn (1000) + response (2000) = 3,500
 * - Available for memories: ~21,000 tokens (default: 1000 for testing)
 * - Dynamic allocation based on chunk sizes
 * - Greedy selection: highest-scoring memories first until budget exhausted
 *
 * **Architecture:**
 * Input: Vector search results (id + similarity) + Memory metadata
 * Output: Ranked memories within token budget
 *
 * **Usage:**
 * ```kotlin
 * val ranker = MemoryRanker(maxContextTokens = 1000)
 * val result = ranker.rankAndSelect(searchResults, memories)
 * println(result.getStats())  // Debug statistics
 * val contextText = result.formatAsContext()  // For AI prompt
 * ```
 */
class MemoryRanker(
    private val maxContextTokens: Int = 21000,
    private val similarityWeight: Float = 0.40f,
    private val recencyWeight: Float = 0.20f,
    private val importanceWeight: Float = 0.30f,
    private val accessWeight: Float = 0.10f,
) {
    /**
     * Rank and select memories from search results
     *
     * @param searchResults Vector search results (id + similarity score)
     * @param memories Full memory metadata from repository
     * @param currentTimestamp Current time for recency calculation
     * @return Ranked memories within token budget
     */
    fun rankAndSelect(
        searchResults: List<VectorSearchResult>,
        memories: List<MemoryMetadata>,
        currentTimestamp: Long = Clock.System.now().toEpochMilliseconds(),
    ): MemoryRankingResult {
        if (searchResults.isEmpty() || memories.isEmpty()) {
            return MemoryRankingResult(
                selectedMemories = emptyList(),
                totalTokens = 0,
                droppedCount = 0,
                rankingScores = emptyMap(),
            )
        }

        // Create lookup map for fast access
        val memoryMap = memories.associateBy { it.embedding_id }

        // Join search results with metadata and calculate composite scores
        val scoredMemories =
            searchResults.mapNotNull { result ->
                val memory = memoryMap[result.id] ?: return@mapNotNull null
                val score =
                    calculateCompositeScore(
                        similarity = result.similarity,
                        memory = memory,
                        currentTimestamp = currentTimestamp,
                    )
                ScoredMemory(memory, score)
            }

        // Sort by composite score (highest first)
        val rankedMemories = scoredMemories.sortedByDescending { it.score }

        // Select memories within token budget
        val selected = selectWithinBudget(rankedMemories)

        // Create score map for debugging
        val scoreMap = selected.associate { it.memory.id to it.score }

        return MemoryRankingResult(
            selectedMemories = selected.map { it.memory },
            totalTokens = selected.sumOf { it.memory.chunk_tokens ?: 0 }.toInt(),
            droppedCount = rankedMemories.size - selected.size,
            rankingScores = scoreMap,
        )
    }

    /**
     * Calculate composite ranking score
     *
     * Combines multiple signals for optimal context selection:
     * - Similarity: How relevant to current query
     * - Recency: How recent the memory is
     * - Importance: Intrinsic content quality
     * - Access: How often it's been useful before
     */
    private fun calculateCompositeScore(
        similarity: Float,
        memory: MemoryMetadata,
        currentTimestamp: Long,
    ): Float {
        val recencyScore = calculateRecencyScore(memory.created_at, currentTimestamp)
        val importanceScore = memory.importance.toFloat()
        val accessScore = calculateAccessScore(memory.access_count.toInt())

        return (similarityWeight * similarity) +
            (recencyWeight * recencyScore) +
            (importanceWeight * importanceScore) +
            (accessWeight * accessScore)
    }

    /**
     * Calculate recency score using exponential decay
     *
     * Recent memories score higher, with exponential falloff.
     * Half-life: 7 days (memories from 1 week ago score ~0.5)
     *
     * @param createdAt Memory creation timestamp (milliseconds)
     * @param currentTime Current timestamp (milliseconds)
     * @return Recency score 0.0 to 1.0
     */
    private fun calculateRecencyScore(
        createdAt: Long,
        currentTime: Long,
    ): Float {
        val ageMillis = currentTime - createdAt
        if (ageMillis < 0) return 1.0f // Future timestamp (shouldn't happen)

        // Convert to days
        val ageDays = ageMillis / (1000 * 60 * 60 * 24).toFloat()

        // Exponential decay with 7-day half-life
        val halfLifeDays = 7.0f
        val decayFactor = exp(-0.693f * (ageDays / halfLifeDays))

        return decayFactor.coerceIn(0.0f, 1.0f)
    }

    /**
     * Calculate access frequency score
     *
     * Logarithmic scaling to reward popular memories without over-weighting.
     *
     * Examples:
     * - 0 accesses: 0.0
     * - 1 access: 0.3
     * - 5 accesses: 0.6
     * - 10 accesses: 0.75
     * - 50 accesses: 1.0
     *
     * @param accessCount Number of times memory has been retrieved
     * @return Access score 0.0 to 1.0
     */
    private fun calculateAccessScore(accessCount: Int): Float {
        if (accessCount <= 0) return 0.0f

        // Logarithmic scaling: log(1 + count) / log(51)
        // Reaches 1.0 at 50 accesses
        val normalized = kotlin.math.ln(1.0f + accessCount) / kotlin.math.ln(51.0f)

        return normalized.coerceIn(0.0f, 1.0f)
    }

    /**
     * Select memories within token budget
     *
     * Greedily selects highest-scoring memories until budget exhausted.
     * Ensures we don't exceed maxContextTokens.
     *
     * @param rankedMemories Memories sorted by score (highest first)
     * @return Selected memories within budget
     */
    private fun selectWithinBudget(rankedMemories: List<ScoredMemory>): List<ScoredMemory> {
        val selected = mutableListOf<ScoredMemory>()
        var currentTokens = 0

        for (scoredMemory in rankedMemories) {
            val memoryTokens = scoredMemory.memory.chunk_tokens?.toInt() ?: 0

            if (currentTokens + memoryTokens <= maxContextTokens) {
                selected.add(scoredMemory)
                currentTokens += memoryTokens
            } else {
                // Budget exhausted
                break
            }
        }

        return selected
    }

    /**
     * Calculate diversity bonus (future enhancement)
     *
     * Penalize memories that are too similar to already-selected ones.
     * Encourages diverse context coverage.
     *
     * Not yet implemented - placeholder for Phase 3+
     */
    @Suppress("unused")
    private fun calculateDiversityBonus(
        memory: MemoryMetadata,
        selectedMemories: List<MemoryMetadata>,
    ): Float {
        // TODO: Implement diversity scoring
        // - Compare embedding similarity to already-selected memories
        // - Penalize high similarity (redundant information)
        // - Reward topical diversity
        return 0.0f
    }
}

/**
 * Scored memory (memory + composite score)
 */
private data class ScoredMemory(
    val memory: MemoryMetadata,
    val score: Float,
)

/**
 * Memory ranking result
 */
data class MemoryRankingResult(
    val selectedMemories: List<MemoryMetadata>,
    val totalTokens: Int,
    val droppedCount: Int,
    val rankingScores: Map<String, Float>,
) {
    /**
     * Get memories ordered by original chunk index for coherent reading
     */
    fun getOrderedByChunks(): List<MemoryMetadata> =
        selectedMemories.sortedWith(
            compareBy(
                { it.message_id },
                { it.chunk_index },
            ),
        )

    /**
     * Get context as formatted text for AI prompt
     */
    fun formatAsContext(): String =
        getOrderedByChunks().joinToString("\n\n") { memory ->
            "### Memory (importance: ${String.format("%.2f", memory.importance)})\n${memory.content}"
        }

    /**
     * Check if context is empty
     */
    fun isEmpty(): Boolean = selectedMemories.isEmpty()

    /**
     * Get context statistics for debugging
     */
    fun getStats(): String {
        val avgImportance = if (selectedMemories.isEmpty()) 0.0 else selectedMemories.map { it.importance }.average()
        val avgScore = if (rankingScores.isEmpty()) 0.0 else rankingScores.values.average().toDouble()
        return """
            |Memory Ranking Statistics:
            |  Selected: ${selectedMemories.size} memories
            |  Total Tokens: $totalTokens
            |  Dropped: $droppedCount memories (budget exceeded)
            |  Avg Importance: ${"%.2f".format(avgImportance)}
            |  Avg Score: ${"%.2f".format(avgScore)}
            """.trimMargin()
    }
}

// SearchResult removed - now using VectorSearchResult from domain layer
// See: app.m1k3.ai.domain.repositories.VectorSearchResult
