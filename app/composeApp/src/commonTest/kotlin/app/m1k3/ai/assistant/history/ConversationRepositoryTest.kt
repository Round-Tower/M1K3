package app.m1k3.ai.assistant.history

import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.test.TestDatabaseFactory
import kotlin.time.Clock
import kotlin.test.*

/**
 * TDD RED Phase: ConversationRepository Tests
 *
 * Defines the clean API for chat history management.
 * Conversations group related messages together for easy browsing and searching.
 *
 * Test Coverage:
 * - Creating conversations (auto-generate title, link to project)
 * - Updating conversation metadata (title, timestamps, counts)
 * - Retrieving conversations (all, by project, by ID)
 * - Searching conversations by title
 * - Archiving/restoring conversations
 * - Getting conversation statistics
 * - Automatic conversation creation from first message
 * - Edge cases (no conversations, archived conversations)
 */
class ConversationRepositoryTest {

    // ==================== Creating Conversations ====================

    @Test
    fun `createConversation creates new conversation with metadata`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val projectId = "project_001"
        val title = "My first conversation"

        // Act
        val conversationId = repository.createConversation(
            projectId = projectId,
            title = title
        )

        // Assert
        assertNotNull(conversationId, "Should return conversation ID")

        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertEquals(projectId, conversation.project_id)
        assertEquals(title, conversation.title)
        assertEquals(0, conversation.message_count)
        assertEquals(0, conversation.token_count)
        assertEquals(0, conversation.is_archived)
    }

    @Test
    fun `createConversation with null title generates auto title`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        // Act
        val conversationId = repository.createConversation(
            projectId = "project_001",
            title = null // Auto-generate
        )

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertNotNull(conversation.title, "Should auto-generate title")
        assertTrue(conversation.title!!.contains("Conversation"), "Auto title should contain 'Conversation'")
    }

    // ==================== Updating Conversations ====================

    @Test
    fun `updateConversationTitle renames conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "Old Title")

        // Act
        repository.updateConversationTitle(conversationId, "New Title")

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertEquals("New Title", conversation.title)
    }

    @Test
    fun `incrementMessageCount updates counters`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "Test")

        // Act
        repository.incrementMessageCount(conversationId, tokensAdded = 100)

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertEquals(1, conversation.message_count)
        assertEquals(100, conversation.token_count)
    }

    @Test
    fun `incrementMessageCount multiple times accumulates`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "Test")

        // Act
        repository.incrementMessageCount(conversationId, tokensAdded = 50)
        repository.incrementMessageCount(conversationId, tokensAdded = 75)
        repository.incrementMessageCount(conversationId, tokensAdded = 25)

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertEquals(3, conversation.message_count)
        assertEquals(150, conversation.token_count)
    }

    // ==================== Retrieving Conversations ====================

    @Test
    fun `getAllConversations returns all active conversations`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        repository.createConversation("project_001", "Conv 1")
        repository.createConversation("project_001", "Conv 2")
        repository.createConversation("project_002", "Conv 3")

        // Act
        val conversations = repository.getAllConversations()

        // Assert
        assertEquals(3, conversations.size)
    }

    @Test
    fun `getAllConversations excludes archived conversations`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conv1 = repository.createConversation("project_001", "Active")
        val conv2 = repository.createConversation("project_001", "Archived")

        repository.archiveConversation(conv2)

        // Act
        val conversations = repository.getAllConversations()

        // Assert
        assertEquals(1, conversations.size)
        assertEquals(conv1, conversations.first().id)
    }

    @Test
    fun `getConversationsByProject filters by project`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        repository.createConversation("project_a", "Conv 1")
        repository.createConversation("project_a", "Conv 2")
        repository.createConversation("project_b", "Conv 3")

        // Act
        val projectAConversations = repository.getConversationsByProject("project_a")

        // Assert
        assertEquals(2, projectAConversations.size)
        assertTrue(projectAConversations.all { it.projectId == "project_a" })
    }

    @Test
    fun `getConversationById returns conversation details`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "Test Conversation")

        // Act
        val conversation = repository.getConversationById(conversationId)

        // Assert
        assertNotNull(conversation)
        assertEquals(conversationId, conversation.id)
        assertEquals("Test Conversation", conversation.title)
    }

    @Test
    fun `getConversationById returns null for non-existent ID`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        // Act
        val conversation = repository.getConversationById(999L)

        // Assert
        assertNull(conversation, "Should return null for non-existent conversation")
    }

    // ==================== Searching Conversations ====================

    @Test
    fun `searchConversations finds matching titles`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        repository.createConversation("project_001", "Kotlin Coroutines Discussion")
        repository.createConversation("project_001", "Compose UI Layout")
        repository.createConversation("project_001", "Kotlin Flow Operators")

        // Act
        val results = repository.searchConversations("Kotlin")

        // Assert
        assertEquals(2, results.size, "Should find 2 conversations with 'Kotlin' in title")
        assertTrue(results.all { it.title?.contains("Kotlin") == true })
    }

    @Test
    fun `searchConversations is case-insensitive`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        repository.createConversation("project_001", "Android Development")

        // Act
        val results = repository.searchConversations("android")

        // Assert
        assertEquals(1, results.size)
    }

    // ==================== Archiving Conversations ====================

    @Test
    fun `archiveConversation marks conversation as archived`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "To Archive")

        // Act
        repository.archiveConversation(conversationId)

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertEquals(1, conversation.is_archived)
    }

    @Test
    fun `restoreConversation unarchives conversation`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "Archived")
        repository.archiveConversation(conversationId)

        // Act
        repository.restoreConversation(conversationId)

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOne()

        assertEquals(0, conversation.is_archived)
    }

    @Test
    fun `getArchivedConversations returns only archived`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val active = repository.createConversation("project_001", "Active")
        val archived = repository.createConversation("project_001", "Archived")

        repository.archiveConversation(archived)

        // Act
        val archivedConversations = repository.getArchivedConversations()

        // Assert
        assertEquals(1, archivedConversations.size)
        assertEquals(archived, archivedConversations.first().id)
    }

    // ==================== Statistics ====================

    @Test
    fun `getConversationStats returns aggregate statistics`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conv1 = repository.createConversation("project_001", "Conv 1")
        val conv2 = repository.createConversation("project_001", "Conv 2")
        val conv3 = repository.createConversation("project_001", "Archived")

        repository.incrementMessageCount(conv1, tokensAdded = 100)
        repository.incrementMessageCount(conv2, tokensAdded = 200)
        repository.archiveConversation(conv3)

        // Act
        val stats = repository.getConversationStats()

        // Assert
        assertNotNull(stats)
        assertEquals(3, stats.totalConversations)
        assertEquals(2, stats.activeConversations)
        assertEquals(1, stats.archivedConversations)
        assertEquals(2, stats.totalMessages)
        assertEquals(300, stats.totalTokens)
    }

    @Test
    fun `getConversationStats returns null when no conversations exist`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        // Act
        val stats = repository.getConversationStats()

        // Assert
        assertNull(stats, "Should return null when no conversations exist")
    }

    // ==================== Deletion ====================

    @Test
    fun `deleteConversation removes conversation from database`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        val conversationId = repository.createConversation("project_001", "To Delete")

        // Act
        repository.deleteConversation(conversationId)

        // Assert
        val conversation = database.conversationMetadataQueries
            .getConversationById(conversationId)
            .executeAsOneOrNull()

        assertNull(conversation, "Conversation should be deleted")
    }

    // ==================== Edge Cases ====================

    @Test
    fun `operations on empty database return gracefully`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val repository = ConversationRepository(database)

        // Act & Assert - should not crash
        assertEquals(0, repository.getAllConversations().size)
        assertEquals(0, repository.getArchivedConversations().size)
        assertEquals(0, repository.searchConversations("test").size)
        assertNull(repository.getConversationById(1L))
        assertNull(repository.getConversationStats())
    }
}
