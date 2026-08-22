package app.m1k3.ai.assistant.history

import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.test.TestDatabaseFactory
import kotlin.time.Clock
import kotlin.test.*

/**
 * TDD RED Phase: ExportManager Tests
 *
 * Defines the clean API for exporting conversation history.
 * ExportManager provides data portability with:
 * - JSON export (machine-readable, backup-friendly)
 * - Markdown export (human-readable, shareable)
 * - Project-level export (all conversations in a project)
 * - Conversation-level export (single conversation)
 * - Metadata preservation (timestamps, tokens, eco-metrics)
 *
 * Test Coverage:
 * - Export single conversation to JSON
 * - Export single conversation to Markdown
 * - Export project (all conversations) to JSON
 * - Export project to Markdown
 * - Export with eco-metrics included
 * - Export empty conversation
 * - Import from JSON (restore backup)
 * - JSON round-trip (export → import → verify)
 */
class ExportManagerTest {

    // ==================== JSON Export Tests ====================

    @Test
    fun `exportConversationToJson returns valid JSON`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test Conversation")

        // Add messages
        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Hello, world!",
            tokens = 5,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        database.messageQueries.insertMessage(
            id = "msg_002",
            project_id = projectId,
            conversation_id = convId,
            role = "assistant",
            content = "Hello! How can I help you?",
            tokens = 10,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Act
        val json = exportManager.exportConversationToJson(convId)

        // Assert
        assertNotNull(json, "Should return JSON string")
        assertTrue(json.contains("\"title\""), "Should include conversation title")
        assertTrue(json.contains("\"messages\""), "Should include messages array")
        assertTrue(json.contains("Hello, world!"), "Should include message content")
        assertTrue(json.contains("Hello! How can I help you?"), "Should include assistant response")
    }

    @Test
    fun `exportConversationToJson includes metadata`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Metadata Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Test message",
            tokens = 5,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Act
        val json = exportManager.exportConversationToJson(convId)

        // Assert
        assertNotNull(json, "Should return JSON string")
        assertTrue(json.contains("\"timestamp\""), "Should include timestamp")
        assertTrue(json.contains("\"tokens\""), "Should include token count")
        assertTrue(json.contains("\"role\""), "Should include message role")
    }

    // ==================== Markdown Export Tests ====================

    @Test
    fun `exportConversationToMarkdown returns readable format`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Markdown Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "What is Kotlin Multiplatform?",
            tokens = 8,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        database.messageQueries.insertMessage(
            id = "msg_002",
            project_id = projectId,
            conversation_id = convId,
            role = "assistant",
            content = "Kotlin Multiplatform lets you share code across platforms.",
            tokens = 15,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Act
        val markdown = exportManager.exportConversationToMarkdown(convId)

        // Assert
        assertNotNull(markdown, "Should return Markdown string")
        assertTrue(markdown.contains("# Markdown Test"), "Should include title as heading")
        assertTrue(markdown.contains("**User:**"), "Should label user messages")
        assertTrue(markdown.contains("**Assistant:**"), "Should label assistant messages")
        assertTrue(markdown.contains("What is Kotlin Multiplatform?"), "Should include question")
        assertTrue(markdown.contains("Kotlin Multiplatform lets you share code"), "Should include answer")
    }

    @Test
    fun `exportConversationToMarkdown includes timestamps`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Timestamp Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Test",
            tokens = 1,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Act
        val markdown = exportManager.exportConversationToMarkdown(convId)

        // Assert
        assertNotNull(markdown, "Should return Markdown string")
        assertTrue(markdown.contains("---"), "Should include metadata separator")
        // Timestamps in ISO format or human-readable format
        assertTrue(markdown.contains("202"), "Should include year in timestamp")
    }

    // ==================== Project Export Tests ====================

    @Test
    fun `exportProjectToJson exports all conversations`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"

        // Create 2 conversations
        val conv1 = conversationRepo.createConversation(projectId, "Conversation 1")
        val conv2 = conversationRepo.createConversation(projectId, "Conversation 2")

        // Add messages to conv1
        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = conv1,
            role = "user",
            content = "Message in conversation 1",
            tokens = 5,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Add messages to conv2
        database.messageQueries.insertMessage(
            id = "msg_002",
            project_id = projectId,
            conversation_id = conv2,
            role = "user",
            content = "Message in conversation 2",
            tokens = 5,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Act
        val json = exportManager.exportProjectToJson(projectId)

        // Assert
        assertNotNull(json, "Should return JSON string")
        assertTrue(json.contains("\"conversations\""), "Should include conversations array")
        assertTrue(json.contains("Conversation 1"), "Should include first conversation")
        assertTrue(json.contains("Conversation 2"), "Should include second conversation")
        assertTrue(json.contains("Message in conversation 1"), "Should include conv1 messages")
        assertTrue(json.contains("Message in conversation 2"), "Should include conv2 messages")
    }

    // ==================== Empty Conversation Tests ====================

    @Test
    fun `exportConversationToJson handles empty conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Empty Conversation")

        // Act
        val json = exportManager.exportConversationToJson(convId)

        // Assert
        assertNotNull(json, "Should return JSON even for empty conversation")
        assertTrue(json.contains("\"messages\""), "Should have messages array")
        assertTrue(json.contains("[]"), "Messages array should be empty")
    }

    @Test
    fun `exportConversationToMarkdown handles empty conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Empty Conversation")

        // Act
        val markdown = exportManager.exportConversationToMarkdown(convId)

        // Assert
        assertNotNull(markdown, "Should return Markdown even for empty conversation")
        assertTrue(markdown.contains("# Empty Conversation"), "Should include title")
        assertTrue(
            markdown.contains("No messages") || markdown.trim().endsWith("---"),
            "Should indicate no messages or just have metadata"
        )
    }

    // ==================== Non-existent Conversation Tests ====================

    @Test
    fun `exportConversationToJson returns null for non-existent conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val exportManager = ExportManager(database)

        // Act
        val json = exportManager.exportConversationToJson(999L)

        // Assert
        assertNull(json, "Should return null for non-existent conversation")
    }

    @Test
    fun `exportConversationToMarkdown returns null for non-existent conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val exportManager = ExportManager(database)

        // Act
        val markdown = exportManager.exportConversationToMarkdown(999L)

        // Assert
        assertNull(markdown, "Should return null for non-existent conversation")
    }

    // ==================== JSON Import Tests ====================

    @Test
    fun `importConversationFromJson restores conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        database.seedProject(projectId)
        val convId = conversationRepo.createConversation(projectId, "Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Original message",
            tokens = 5,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Export
        val json = exportManager.exportConversationToJson(convId)

        // Delete conversation
        conversationRepo.deleteConversation(convId)

        // Act - Import
        val newConvId = exportManager.importConversationFromJson(projectId, json!!)

        // Assert
        assertNotNull(newConvId, "Should return new conversation ID")
        val imported = conversationRepo.getConversationById(newConvId)
        assertNotNull(imported, "Conversation should be restored")
        assertEquals("Test", imported.title, "Title should match")

        val messages = database.messageQueries.getMessagesByConversation(newConvId).executeAsList()
        assertEquals(1, messages.size, "Should restore messages")
        assertEquals("Original message", messages.first().content, "Message content should match")
    }

    @Test
    fun `importConversationFromJson round-trips all messages and metadata`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        val projectId = "project_001"
        database.seedProject("project_002") // the import target must exist
        val convId = conversationRepo.createConversation(projectId, "Round Trip")

        val now = Clock.System.now().toEpochMilliseconds()
        database.messageQueries.insertMessage(
            id = "msg_001", project_id = projectId, conversation_id = convId,
            role = "user", content = "First message", tokens = 3, timestamp = now,
            image_uri = null, sentiment_valence = null, sentiment_arousal = null,
            sentiment_dominance = null, sentiment_emotion = null, sentiment_intensity = null,
            rag_sources = null, rag_confidence = null
        )
        database.messageQueries.insertMessage(
            id = "msg_002", project_id = projectId, conversation_id = convId,
            role = "assistant", content = "Second message", tokens = 7, timestamp = now + 1,
            image_uri = null, sentiment_valence = null, sentiment_arousal = null,
            sentiment_dominance = null, sentiment_emotion = null, sentiment_intensity = null,
            rag_sources = null, rag_confidence = null
        )

        val json = exportManager.exportConversationToJson(convId)!!

        // Act - import into a different project without deleting the original
        val newConvId = exportManager.importConversationFromJson("project_002", json)

        // Assert - both conversations now coexist
        assertNotNull(newConvId, "Should return new conversation ID")
        assertNotEquals(convId, newConvId, "Import should create a distinct conversation")

        val imported = conversationRepo.getConversationById(newConvId)
        assertNotNull(imported, "Imported conversation should exist")
        assertEquals("Round Trip", imported.title, "Title should be preserved")
        assertEquals("project_002", imported.projectId, "Should import into the target project")

        val messages = database.messageQueries.getMessagesByConversation(newConvId).executeAsList()
        assertEquals(2, messages.size, "Should restore all messages")
        assertEquals("First message", messages[0].content)
        assertEquals("Second message", messages[1].content)
        assertEquals(7L, messages[1].tokens, "Token counts should be preserved")

        // Original conversation is untouched
        assertNotNull(conversationRepo.getConversationById(convId), "Original should remain")
    }

    @Test
    fun `importConversationFromJson returns null for malformed JSON`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val exportManager = ExportManager(database)

        // Act
        val result = exportManager.importConversationFromJson("project_001", "not valid json {")

        // Assert
        assertNull(result, "Should return null for unparseable JSON")
    }

    @Test
    fun `importConversationFromJson recomputes counts from messages, not the JSON`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val exportManager = ExportManager(database)

        database.seedProject("project_001")

        // A backup whose declared counts LIE about its contents (hand-edited or
        // corrupted): messageCount/tokenCount claim 999, but there are two messages
        // totalling 10 tokens.
        val tampered = """
            {
              "title": "Tampered",
              "projectId": "old_project",
              "startedAt": 1000,
              "lastMessageAt": 2000,
              "messageCount": 999,
              "tokenCount": 999,
              "messages": [
                { "id": "a", "role": "user", "content": "one", "timestamp": 1000, "tokens": 3 },
                { "id": "b", "role": "assistant", "content": "two", "timestamp": 1500, "tokens": 7 }
              ]
            }
        """.trimIndent()

        // Act
        val newConvId = exportManager.importConversationFromJson("project_001", tampered)

        // Assert — the stored counts reflect the actual messages, not the JSON's claims.
        assertNotNull(newConvId, "Should import a valid (if mislabelled) backup")
        val imported = conversationRepo.getConversationById(newConvId)
        assertNotNull(imported, "Imported conversation should exist")
        assertEquals(2, imported.messageCount, "message_count derived from messages, not JSON")
        assertEquals(10, imported.tokenCount, "token_count summed from messages, not JSON")

        val messages = database.messageQueries.getMessagesByConversation(newConvId).executeAsList()
        assertEquals(2, messages.size)
    }

    @Test
    fun `importConversationFromJson returns null for an unknown target project`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val exportManager = ExportManager(database)

        // Syntactically valid export, but the target project was never created.
        val json = """
            {
              "title": "Orphan",
              "projectId": "old_project",
              "startedAt": 1,
              "lastMessageAt": 2,
              "messageCount": 0,
              "tokenCount": 0,
              "messages": []
            }
        """.trimIndent()

        // Act
        val result = exportManager.importConversationFromJson("does_not_exist", json)

        // Assert — a bad restore target is rejected up front, like malformed JSON.
        assertNull(result, "Unknown target project should be rejected, not silently orphaned")
        assertEquals(
            0,
            database.conversationMetadataQueries.getConversationsByProject("does_not_exist").executeAsList().size,
            "Nothing should have been written for the unknown project"
        )
    }
}

/** Insert a minimal Project row so imports (which now require an existing target) can land. */
private fun MaDatabase.seedProject(id: String) {
    projectQueries.insertProject(
        id = id,
        name = id,
        description = null,
        created_at = 0,
        updated_at = 0,
        is_archived = 0,
        color = null,
        icon = null,
        message_count = 0,
        total_tokens = 0
    )
}
