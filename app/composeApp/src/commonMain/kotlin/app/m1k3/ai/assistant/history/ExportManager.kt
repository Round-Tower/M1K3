package app.m1k3.ai.assistant.history

import app.m1k3.ai.assistant.database.MaDatabase
import kotlin.time.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * ExportManager - Data Portability for Conversation History
 *
 * **Philosophy:**
 * Your data belongs to you. ExportManager provides complete data portability
 * with human-readable and machine-readable formats for backup, sharing, and migration.
 *
 * **Supported Formats:**
 * - JSON: Machine-readable, preserves all metadata, perfect for backups
 * - Markdown: Human-readable, shareable, great for documentation
 *
 * **Usage Example:**
 * ```kotlin
 * // Export single conversation to JSON
 * val json = exportManager.exportConversationToJson(conversationId)
 * saveToFile("conversation_backup.json", json)
 *
 * // Export to Markdown for sharing
 * val markdown = exportManager.exportConversationToMarkdown(conversationId)
 * shareText(markdown)
 *
 * // Export entire project
 * val projectJson = exportManager.exportProjectToJson(projectId)
 * ```
 */
class ExportManager(private val database: MaDatabase) {

    private val json = Json {
        prettyPrint = true
        encodeDefaults = true
    }

    // ==================== JSON Export ====================

    /**
     * Export a single conversation to JSON format.
     *
     * Includes:
     * - Conversation metadata (title, timestamps, counts)
     * - All messages with full metadata
     * - Preserves timestamps, tokens, roles
     *
     * @param conversationId Conversation to export
     * @return JSON string or null if conversation doesn't exist
     */
    fun exportConversationToJson(conversationId: Long): String? {
        // Get conversation metadata
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOneOrNull()
            ?: return null

        // Get all messages
        val messages = database.messageQueries
            .getMessagesByConversation(conversationId)
            .executeAsList()

        // Build export object
        val export = ConversationExport(
            title = conversation.title,
            projectId = conversation.project_id,
            startedAt = conversation.started_at,
            lastMessageAt = conversation.last_message_at,
            messageCount = conversation.message_count.toInt(),
            tokenCount = conversation.token_count.toInt(),
            messages = messages.map { message ->
                MessageExport(
                    id = message.id,
                    role = message.role,
                    content = message.content,
                    timestamp = message.timestamp,
                    tokens = message.tokens?.toInt()
                )
            }
        )

        return json.encodeToString(export)
    }

    /**
     * Export an entire project (all conversations) to JSON format.
     *
     * Useful for full project backups.
     *
     * @param projectId Project to export
     * @return JSON string with all conversations
     */
    fun exportProjectToJson(projectId: String): String {
        // Get all conversations in project
        val conversations = database.conversationMetadataQueries
            .getConversationsByProject(projectId)
            .executeAsList()

        // Export each conversation
        val conversationExports = conversations.mapNotNull { conversation ->
            val messages = database.messageQueries
                .getMessagesByConversation(conversation.id)
                .executeAsList()

            ConversationExport(
                title = conversation.title,
                projectId = conversation.project_id,
                startedAt = conversation.started_at,
                lastMessageAt = conversation.last_message_at,
                messageCount = conversation.message_count.toInt(),
                tokenCount = conversation.token_count.toInt(),
                messages = messages.map { message ->
                    MessageExport(
                        id = message.id,
                        role = message.role,
                        content = message.content,
                        timestamp = message.timestamp,
                        tokens = message.tokens?.toInt()
                    )
                }
            )
        }

        val projectExport = ProjectExport(
            projectId = projectId,
            exportedAt = kotlin.time.Clock.System.now().toEpochMilliseconds(),
            conversationCount = conversationExports.size,
            conversations = conversationExports
        )

        return json.encodeToString(projectExport)
    }

    // ==================== Markdown Export ====================

    /**
     * Export a single conversation to Markdown format.
     *
     * Creates a human-readable document with:
     * - Conversation title as heading
     * - Metadata section (dates, counts)
     * - Messages in readable format
     * - Timestamps for each message
     *
     * @param conversationId Conversation to export
     * @return Markdown string or null if conversation doesn't exist
     */
    fun exportConversationToMarkdown(conversationId: Long): String? {
        // Get conversation metadata
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOneOrNull()
            ?: return null

        // Get all messages
        val messages = database.messageQueries
            .getMessagesByConversation(conversationId)
            .executeAsList()

        // Build Markdown document
        val markdown = buildString {
            // Title
            appendLine("# ${conversation.title ?: "Untitled Conversation"}")
            appendLine()

            // Metadata section
            appendLine("---")
            appendLine("**Started:** ${formatTimestamp(conversation.started_at)}")
            appendLine("**Last Message:** ${formatTimestamp(conversation.last_message_at)}")
            appendLine("**Messages:** ${conversation.message_count}")
            appendLine("**Tokens:** ${conversation.token_count}")
            appendLine("---")
            appendLine()

            // Messages
            if (messages.isEmpty()) {
                appendLine("*No messages in this conversation.*")
            } else {
                messages.forEach { message ->
                    val roleLabel = when (message.role) {
                        "user" -> "**User:**"
                        "assistant" -> "**Assistant:**"
                        else -> "**${message.role.replaceFirstChar { it.uppercase() }}:**"
                    }

                    appendLine("$roleLabel")
                    appendLine(message.content)
                    appendLine()
                    appendLine("*${formatTimestamp(message.timestamp)}*")
                    if (message.tokens != null) {
                        appendLine("*(${message.tokens} tokens)*")
                    }
                    appendLine()
                }
            }
        }

        return markdown
    }

    /**
     * Export an entire project to Markdown format.
     *
     * Creates a document with all conversations concatenated.
     *
     * @param projectId Project to export
     * @return Markdown string with all conversations
     */
    fun exportProjectToMarkdown(projectId: String): String {
        val conversations = database.conversationMetadataQueries
            .getConversationsByProject(projectId)
            .executeAsList()

        return buildString {
            appendLine("# Project Export: $projectId")
            appendLine()
            appendLine("---")
            appendLine("**Exported:** ${formatTimestamp(kotlin.time.Clock.System.now().toEpochMilliseconds())}")
            appendLine("**Conversations:** ${conversations.size}")
            appendLine("---")
            appendLine()

            conversations.forEach { conversation ->
                val conversationMarkdown = exportConversationToMarkdown(conversation.id)
                if (conversationMarkdown != null) {
                    appendLine(conversationMarkdown)
                    appendLine()
                    appendLine("---")
                    appendLine()
                }
            }
        }
    }

    // ==================== Helper Methods ====================

    /**
     * Format Unix timestamp to human-readable date/time.
     *
     * @param timestamp Unix timestamp in milliseconds
     * @return Formatted date string (e.g., "2025-01-15 14:30")
     */
    private fun formatTimestamp(timestamp: Long): String {
        val instant = Instant.fromEpochMilliseconds(timestamp)
        val dateTime = instant.toLocalDateTime(TimeZone.currentSystemDefault())

        return "${dateTime.date} ${dateTime.hour}:${dateTime.minute.toString().padStart(2, '0')}"
    }

    // ==================== Import (backup restore) ====================

    /**
     * Import a conversation from JSON (backup restoration).
     *
     * Parses a JSON produced by [exportConversationToJson], creates a fresh
     * conversation in [projectId] (preserving the exported title and timestamps;
     * the message/token counts are recomputed from the restored messages rather
     * than trusted from the JSON), and re-inserts every message under new,
     * collision-free ids so the same backup can be restored more than once. The
     * conversation is created under the target [projectId], not the project
     * recorded in the export, so a backup can be restored into any EXISTING
     * project. The conversation row and all messages are written in a single
     * transaction, so a partial/failed restore rolls back rather than leaving an
     * orphaned row.
     *
     * Restore is LOSSY, matching the export format: only role/content/timestamp/
     * tokens round-trip. Message `image_uri`, sentiment (`sentiment_*`), and RAG
     * metadata (`rag_sources`/`rag_confidence`) are never serialized by
     * [exportConversationToJson], so they come back null — a restored conversation
     * loses image attachments, RAG citations, and sentiment history. The
     * conversation's archived state isn't exported either, so a restore always
     * lands active.
     *
     * Blocking DB work, like the sibling `export*` methods: this opens a SQLCipher
     * write transaction and loops inserts synchronously, so a UI caller must run it
     * off the main thread (e.g. `withContext(Dispatchers.IO)`).
     *
     * @param projectId Project to import into; must name an existing project.
     * @param json JSON export string (as produced by [exportConversationToJson])
     * @return New conversation ID, or null if the JSON could not be parsed OR
     *   [projectId] does not name an existing project — both yield null without
     *   writing anything (the project check runs inside the restore transaction,
     *   atomic with the insert). A genuine database error during the transaction
     *   still propagates — only bad input yields null.
     */
    fun importConversationFromJson(projectId: String, json: String): Long? {
        val export = try {
            this.json.decodeFromString<ConversationExport>(json)
        } catch (e: Exception) {
            return null
        }

        // Derive the counts from the actual messages rather than trusting the
        // exported metadata: a hand-edited or corrupted backup must not leave the
        // conversation permanently reporting a message/token total that disagrees
        // with the messages it actually restored.
        val messageCount = export.messages.size.toLong()
        val tokenCount = export.messages.sumOf { (it.tokens ?: 0).toLong() }

        // Everything in ONE transaction — the target-project existence check INCLUDED,
        // so the check is atomic with the insert (no window for the project to be
        // deleted between checking and writing) and a mid-loop failure rolls back. FK
        // enforcement (PRAGMA foreign_keys = ON) isn't set on the driver, so this
        // explicit check is what stops a typo'd/stale projectId from silently inserting
        // an orphaned conversation that no project screen can ever reach
        // (getConversationsByProject filters by plain string equality). getLastInsertId()
        // reads this insert on the same connection. The transaction-wrapping follows
        // SqlDelightPassageRepository.saveSource; the rollback()-to-reject is this
        // path's own (saveSource doesn't reject mid-transaction).
        var newConversationId: Long? = null
        database.transaction {
            // Unknown target project → roll back and leave newConversationId null, so
            // importConversationFromJson returns null (like the malformed-JSON path),
            // having written nothing.
            if (database.projectQueries.getProjectById(projectId).executeAsOneOrNull() == null) {
                rollback()
            }

            database.conversationMetadataQueries.insertConversation(
                project_id = projectId,
                title = export.title,
                started_at = export.startedAt,
                last_message_at = export.lastMessageAt,
                message_count = messageCount,
                token_count = tokenCount,
                is_archived = 0
            )

            val conversationId = database.conversationMetadataQueries
                .getLastInsertId()
                .executeAsOne()
            newConversationId = conversationId

            // Fresh ids keyed on the new conversation id, so restoring the same
            // backup twice never collides on the message primary key.
            export.messages.forEachIndexed { index, message ->
                database.messageQueries.insertMessage(
                    id = "msg_${conversationId}_$index",
                    project_id = projectId,
                    conversation_id = conversationId,
                    role = message.role,
                    content = message.content,
                    tokens = message.tokens?.toLong(),
                    timestamp = message.timestamp,
                    image_uri = null,
                    sentiment_valence = null,
                    sentiment_arousal = null,
                    sentiment_dominance = null,
                    sentiment_emotion = null,
                    sentiment_intensity = null,
                    rag_sources = null,
                    rag_confidence = null
                )
            }
        }

        return newConversationId
    }
}

// ==================== Data Classes ====================

/**
 * Serializable conversation export format.
 */
@Serializable
data class ConversationExport(
    val title: String?,
    val projectId: String,
    val startedAt: Long,
    val lastMessageAt: Long,
    val messageCount: Int,
    val tokenCount: Int,
    val messages: List<MessageExport>
)

/**
 * Serializable message export format.
 */
@Serializable
data class MessageExport(
    val id: String,
    val role: String,
    val content: String,
    val timestamp: Long,
    val tokens: Int?
)

/**
 * Serializable project export format.
 */
@Serializable
data class ProjectExport(
    val projectId: String,
    val exportedAt: Long,
    val conversationCount: Int,
    val conversations: List<ConversationExport>
)
