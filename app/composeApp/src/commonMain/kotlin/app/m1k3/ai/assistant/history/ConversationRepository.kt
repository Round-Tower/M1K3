package app.m1k3.ai.assistant.history

import app.m1k3.ai.assistant.database.MaDatabase
import kotlin.time.Clock
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

/**
 * ConversationRepository - Chat History Management
 *
 * **Philosophy:**
 * Conversations group related messages for easy browsing and searching.
 * This repository provides a clean API for managing chat history with:
 * - Automatic conversation creation
 * - Title generation and updating
 * - Message/token counting
 * - Archiving for cleanup
 * - Search and filtering
 *
 * **Usage Example:**
 * ```kotlin
 * // Create conversation
 * val convId = repository.createConversation(projectId, "Debugging Help")
 *
 * // Update as messages are added
 * repository.incrementMessageCount(convId, tokensAdded = 150)
 *
 * // Search history
 * val results = repository.searchConversations("debugging")
 *
 * // Archive old conversations
 * repository.archiveConversation(convId)
 * ```
 */
class ConversationRepository(private val database: MaDatabase) {

    // ==================== Creating Conversations ====================

    /**
     * Create a new conversation.
     *
     * @param projectId Project this conversation belongs to
     * @param title Conversation title (null = auto-generate)
     * @return New conversation ID
     */
    fun createConversation(projectId: String, title: String? = null): Long {
        val now = Clock.System.now().toEpochMilliseconds()

        val conversationTitle = title ?: generateAutoTitle()

        database.conversationMetadataQueries.insertConversation(
            project_id = projectId,
            title = conversationTitle,
            started_at = now,
            last_message_at = now,
            message_count = 0,
            token_count = 0,
            is_archived = 0
        )

        // Get the auto-generated ID
        return database.conversationMetadataQueries
            .getLastInsertId()
            .executeAsOne()
    }

    /**
     * Generate auto title based on timestamp.
     */
    private fun generateAutoTitle(): String {
        val now = Clock.System.now()
        val localDateTime = now.toLocalDateTime(TimeZone.currentSystemDefault())

        return "Conversation - ${localDateTime.date} ${localDateTime.hour}:${localDateTime.minute.toString().padStart(2, '0')}"
    }

    // ==================== Updating Conversations ====================

    /**
     * Update conversation title.
     *
     * @param conversationId Conversation to update
     * @param newTitle New title
     */
    fun updateConversationTitle(conversationId: Long, newTitle: String) {
        database.conversationMetadataQueries.updateTitle(
            title = newTitle,
            id = conversationId
        )
    }

    /**
     * Increment message count when a message is added to the conversation.
     *
     * Also updates last_message_at timestamp and token_count.
     *
     * @param conversationId Conversation to update
     * @param tokensAdded Tokens in the new message
     */
    fun incrementMessageCount(conversationId: Long, tokensAdded: Long) {
        val now = Clock.System.now().toEpochMilliseconds()

        database.conversationMetadataQueries.incrementMessageCount(
            last_message_at = now,
            token_count = tokensAdded,
            id = conversationId
        )
    }

    // ==================== Retrieving Conversations ====================

    /**
     * Get all active (non-archived) conversations.
     *
     * Ordered by most recent message first.
     *
     * @return List of active conversations
     */
    fun getAllConversations(): List<ConversationInfo> {
        return database.conversationMetadataQueries
            .getAllActiveConversations()
            .executeAsList()
            .map { it.toConversationInfo() }
    }

    /**
     * Get conversations for a specific project.
     *
     * @param projectId Project ID to filter by
     * @return List of conversations in this project
     */
    fun getConversationsByProject(projectId: String): List<ConversationInfo> {
        return database.conversationMetadataQueries
            .getConversationsByProject(projectId)
            .executeAsList()
            .map { it.toConversationInfo() }
    }

    /**
     * Get a single conversation by ID.
     *
     * @param conversationId Conversation ID
     * @return ConversationInfo or null if not found
     */
    fun getConversationById(conversationId: Long): ConversationInfo? {
        return database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOneOrNull()
            ?.toConversationInfo()
    }

    // ==================== Searching Conversations ====================

    /**
     * Search conversations by title.
     *
     * Search is case-insensitive and matches partial titles.
     *
     * @param query Search query
     * @return List of matching conversations
     */
    fun searchConversations(query: String): List<ConversationInfo> {
        return database.conversationMetadataQueries
            .searchConversationsByTitle(query)
            .executeAsList()
            .map { it.toConversationInfo() }
    }

    // ==================== Archiving Conversations ====================

    /**
     * Archive a conversation.
     *
     * Archived conversations are hidden from normal views but can be restored.
     *
     * @param conversationId Conversation to archive
     */
    fun archiveConversation(conversationId: Long) {
        database.conversationMetadataQueries.archiveConversation(conversationId)
    }

    /**
     * Restore an archived conversation.
     *
     * @param conversationId Conversation to restore
     */
    fun restoreConversation(conversationId: Long) {
        database.conversationMetadataQueries.restoreConversation(conversationId)
    }

    /**
     * Get all archived conversations.
     *
     * @return List of archived conversations
     */
    fun getArchivedConversations(): List<ConversationInfo> {
        return database.conversationMetadataQueries
            .getArchivedConversations()
            .executeAsList()
            .map { it.toConversationInfo() }
    }

    // ==================== Statistics ====================

    /**
     * Get aggregate conversation statistics.
     *
     * @return ConversationStats or null if no conversations exist
     */
    fun getConversationStats(): ConversationStats? {
        val stats = database.conversationMetadataQueries
            .getConversationStats()
            .executeAsOneOrNull()
            ?: return null

        // Check if we have any data
        if (stats.total_conversations == 0L) {
            return null
        }

        return ConversationStats(
            totalConversations = stats.total_conversations?.toInt() ?: 0,
            activeConversations = stats.active_conversations?.toInt() ?: 0,
            archivedConversations = stats.archived_conversations?.toInt() ?: 0,
            totalMessages = stats.total_messages ?: 0,
            totalTokens = stats.total_tokens ?: 0,
            avgMessagesPerConversation = stats.avg_messages_per_conversation ?: 0.0
        )
    }

    // ==================== Deletion ====================

    /**
     * Delete a conversation permanently.
     *
     * **Warning:** This cannot be undone. Messages linked to this conversation
     * will also be deleted due to CASCADE foreign key.
     *
     * @param conversationId Conversation to delete
     */
    fun deleteConversation(conversationId: Long) {
        database.conversationMetadataQueries.deleteConversation(conversationId)
    }
}

// ==================== Extension Functions ====================

/**
 * Convert database ConversationMetadata to ConversationInfo.
 */
private fun app.m1k3.ai.assistant.database.ConversationMetadata.toConversationInfo(): ConversationInfo {
    return ConversationInfo(
        id = id,
        projectId = project_id,
        title = title,
        startedAt = started_at,
        lastMessageAt = last_message_at,
        messageCount = message_count.toInt(),
        tokenCount = token_count.toInt(),
        isArchived = is_archived == 1L
    )
}

// ==================== Data Classes ====================

/**
 * Conversation information for display.
 */
data class ConversationInfo(
    val id: Long,
    val projectId: String,
    val title: String?,
    val startedAt: Long,
    val lastMessageAt: Long,
    val messageCount: Int,
    val tokenCount: Int,
    val isArchived: Boolean
)

/**
 * Aggregate conversation statistics.
 */
data class ConversationStats(
    val totalConversations: Int,
    val activeConversations: Int,
    val archivedConversations: Int,
    val totalMessages: Long,
    val totalTokens: Long,
    val avgMessagesPerConversation: Double
)
