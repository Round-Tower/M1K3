package app.m1k3.ai.assistant.memory

import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.database.MemoryMetadata

/**
 * M1K3 - Memory Data Source
 *
 * Data layer abstraction for semantic memory persistence.
 * Coordinates SQLDelight metadata storage with vector search indices.
 *
 * **Architecture:**
 * - SQLDelight: Memory metadata (importance, chunks, access tracking)
 * - Vector Index: Embeddings for similarity search (external to SQL)
 * - Clean separation: DataSource handles SQL, VectorSearch handles vectors
 *
 * **Responsibilities:**
 * - CRUD operations for memory metadata
 * - Importance filtering and ranking queries
 * - Access tracking updates
 * - Memory cleanup (decay, low-importance removal)
 *
 * **Philosophy:**
 * - Simple interface, complex queries hidden
 * - Type-safe operations via SQLDelight
 * - No business logic (that's for MemoryManager)
 */
class MemoryDataSource(
    private val database: MaDatabase
) {

    /**
     * Create new memory metadata entry
     */
    fun createMemory(
        id: String,
        messageId: String,
        projectId: String,
        content: String,
        importance: Float,
        createdAt: Long,
        chunkIndex: Int,
        chunkTotal: Int,
        chunkTokens: Int?,
        embeddingId: String,
        embeddingModel: String = "all-MiniLM-L6-v2"
    ) {
        database.memoryMetadataQueries.insertMemory(
            id = id,
            message_id = messageId,
            project_id = projectId,
            content = content,
            importance = importance.toDouble(),
            created_at = createdAt,
            chunk_index = chunkIndex.toLong(),
            chunk_total = chunkTotal.toLong(),
            chunk_tokens = chunkTokens?.toLong(),
            embedding_id = embeddingId,
            embedding_model = embeddingModel,
            access_count = 0,
            last_accessed_at = null,
            decay_factor = 1.0,
            is_pinned = 0
        )
    }

    /**
     * Get memory by ID
     */
    fun getMemoryById(id: String): MemoryMetadata? {
        return database.memoryMetadataQueries.getMemoryById(id).executeAsOneOrNull()
    }

    /**
     * Get memory by embedding ID (for vector search result lookup)
     */
    fun getMemoryByEmbeddingId(embeddingId: String): MemoryMetadata? {
        return database.memoryMetadataQueries.getMemoryByEmbeddingId(embeddingId)
            .executeAsOneOrNull()
    }

    /**
     * Get all memories for a project (sorted by importance, then recency)
     */
    fun getMemoriesForProject(projectId: String): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getMemoriesForProject(projectId)
            .executeAsList()
    }

    /**
     * Get high-importance memories above threshold
     */
    fun getHighImportanceMemories(
        projectId: String,
        importanceThreshold: Float = 0.7f
    ): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getHighImportanceMemories(
            projectId,
            importanceThreshold.toDouble()
        ).executeAsList()
    }

    /**
     * Get recent memories (temporal context)
     */
    fun getRecentMemories(projectId: String, limit: Int = 10): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getRecentMemories(projectId, limit.toLong())
            .executeAsList()
    }

    /**
     * Get all chunks for a specific message
     */
    fun getMemoriesForMessage(messageId: String): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getMemoriesForMessage(messageId)
            .executeAsList()
    }

    /**
     * Get pinned memories (user-protected from decay)
     */
    fun getPinnedMemories(projectId: String): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getPinnedMemories(projectId)
            .executeAsList()
    }

    /**
     * Get most frequently accessed memories
     */
    fun getMostAccessedMemories(projectId: String, limit: Int = 10): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getMostAccessedMemories(projectId, limit.toLong())
            .executeAsList()
    }

    /**
     * Update access tracking when memory is retrieved via RAG
     */
    fun updateMemoryAccess(id: String, accessedAt: Long) {
        database.memoryMetadataQueries.updateMemoryAccess(
            last_accessed_at = accessedAt,
            id = id
        )
    }

    /**
     * Update decay factor for memory forgetting (Phase 5)
     */
    fun updateDecayFactor(id: String, decayFactor: Float) {
        database.memoryMetadataQueries.updateDecayFactor(
            decay_factor = decayFactor.toDouble(),
            id = id
        )
    }

    /**
     * Pin memory to prevent decay
     */
    fun pinMemory(id: String) {
        database.memoryMetadataQueries.pinMemory(id)
    }

    /**
     * Unpin memory (allow decay)
     */
    fun unpinMemory(id: String) {
        database.memoryMetadataQueries.unpinMemory(id)
    }

    /**
     * Delete memory by ID
     */
    fun deleteMemory(id: String) {
        database.memoryMetadataQueries.deleteMemory(id)
    }

    /**
     * Delete all memories for a project
     */
    fun deleteMemoriesForProject(projectId: String) {
        database.memoryMetadataQueries.deleteMemoriesForProject(projectId)
    }

    /**
     * Delete all memories for a message
     */
    fun deleteMemoriesForMessage(messageId: String) {
        database.memoryMetadataQueries.deleteMemoriesForMessage(messageId)
    }

    /**
     * Delete low-importance memories (cleanup)
     *
     * @param projectId Project to clean
     * @param importanceThreshold Delete below this importance (default 0.3)
     */
    fun deleteLowImportanceMemories(
        projectId: String,
        importanceThreshold: Float = 0.3f
    ) {
        database.memoryMetadataQueries.deleteLowImportanceMemories(
            projectId,
            importanceThreshold.toDouble()
        )
    }

    /**
     * Delete decayed memories (forgetting - Phase 5)
     *
     * @param projectId Project to clean
     * @param decayThreshold Delete below this decay factor (default 0.1)
     */
    fun deleteDecayedMemories(
        projectId: String,
        decayThreshold: Float = 0.1f
    ) {
        database.memoryMetadataQueries.deleteDecayedMemories(
            projectId,
            decayThreshold.toDouble()
        )
    }

    /**
     * Get memory count for a project
     */
    fun getMemoryCount(projectId: String): Long {
        return database.memoryMetadataQueries.getMemoryCount(projectId)
            .executeAsOne()
    }

    /**
     * Get average importance for a project
     */
    fun getAverageImportance(projectId: String): Double? {
        val result = database.memoryMetadataQueries.getAverageImportance(projectId)
            .executeAsOneOrNull()
        return result?.AVG
    }

    /**
     * Get total chunks stored for a project
     */
    fun getTotalChunks(projectId: String): Long? {
        val result = database.memoryMetadataQueries.getTotalChunks(projectId)
            .executeAsOneOrNull()
        return result?.SUM
    }

    /**
     * Get comprehensive memory statistics
     */
    fun getMemoryStats(projectId: String): MemoryDataSourceStats? {
        val stats = database.memoryMetadataQueries.getMemoryStats(projectId)
            .executeAsOneOrNull() ?: return null

        return MemoryDataSourceStats(
            totalMemories = stats.total_memories ?: 0,
            avgImportance = stats.avg_importance?.toFloat() ?: 0f,
            avgDecay = stats.avg_decay?.toFloat() ?: 1f,
            totalAccesses = stats.total_accesses ?: 0,
            pinnedCount = stats.pinned_count ?: 0
        )
    }

    /**
     * Search memories by content (text search, not semantic)
     */
    fun searchMemoriesByContent(projectId: String, query: String): List<MemoryMetadata> {
        return database.memoryMetadataQueries.searchMemoriesByContent(projectId, query)
            .executeAsList()
    }

    /**
     * Get memories that need decay updates (Phase 5)
     */
    fun getMemoriesForDecayUpdate(projectId: String, limit: Int = 100): List<MemoryMetadata> {
        return database.memoryMetadataQueries.getMemoriesForDecayUpdate(
            projectId,
            limit.toLong()
        ).executeAsList()
    }
}

/**
 * Memory data source statistics
 */
data class MemoryDataSourceStats(
    val totalMemories: Long,
    val avgImportance: Float,
    val avgDecay: Float,
    val totalAccesses: Long,
    val pinnedCount: Long
)
