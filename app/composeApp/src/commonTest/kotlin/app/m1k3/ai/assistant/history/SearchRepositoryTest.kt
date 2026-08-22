package app.m1k3.ai.assistant.history

import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.test.TestDatabaseFactory
import kotlin.time.Clock
import kotlin.test.*

/**
 * TDD RED Phase: SearchRepository Tests
 *
 * Defines the clean API for semantic search across conversation history.
 * Search Repository provides intelligent retrieval using:
 * - Semantic search with embeddings (high relevance)
 * - Keyword fallback for exact matches
 * - Filtering by project, date range, conversation
 * - Ranked results by relevance
 *
 * Test Coverage:
 * - Semantic search with embeddings
 * - Keyword search fallback
 * - Filtering by project
 * - Filtering by date range
 * - Filtering by conversation ID
 * - Combined filters (project + date + semantic)
 * - Empty results handling
 * - Search ranking by relevance score
 */
class SearchRepositoryTest {

    // ==================== Semantic Search Tests ====================

    @Ignore("Phase 2.1: Requires embeddings for semantic search. Currently only keyword-based search is implemented.")
    @Test
    fun `searchMessages with semantic query returns relevant messages`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "AI Discussion")

        // Insert messages with embeddings (simulated)
        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "How does machine learning work?",
            tokens = 10,
            timestamp = Clock.System.now().toEpochMilliseconds(),
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null // In real implementation, would have embedding
        )

        database.messageQueries.insertMessage(
            id = "msg_002",
            project_id = projectId,
            conversation_id = convId,
            role = "assistant",
            content = "Machine learning is a subset of AI that enables systems to learn from data.",
            tokens = 20,
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
            id = "msg_003",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "What's the weather like today?",
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

        // Act
        val results = searchRepo.searchMessages(
            query = "artificial intelligence learning",
            projectId = null,
            limit = 10
        )

        // Assert
        assertTrue(results.isNotEmpty(), "Should find relevant messages")
        // In real implementation with embeddings, msg_001 and msg_002 would rank higher
        // For now, keyword matching should find at least the ML-related messages
        assertTrue(
            results.any { it.content.contains("machine learning", ignoreCase = true) },
            "Should find messages about machine learning"
        )
    }

    @Test
    fun `searchMessages with keyword query uses fallback search`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "SQLDelight is great for Kotlin Multiplatform",
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

        database.messageQueries.insertMessage(
            id = "msg_002",
            project_id = projectId,
            conversation_id = convId,
            role = "assistant",
            content = "Yes, it provides type-safe SQL queries",
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
        val results = searchRepo.searchMessages(
            query = "SQLDelight",
            projectId = null,
            limit = 10
        )

        // Assert
        assertEquals(1, results.size, "Should find exact keyword match")
        assertEquals("msg_001", results.first().id)
        assertTrue(results.first().content.contains("SQLDelight"))
    }

    // ==================== Filtering Tests ====================

    @Test
    fun `searchMessages filters by project ID`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        // Project A
        val convA = conversationRepo.createConversation("project_a", "Conv A")
        database.messageQueries.insertMessage(
            id = "msg_a1",
            project_id = "project_a",
            conversation_id = convA,
            role = "user",
            content = "Message in project A about AI",
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

        // Project B
        val convB = conversationRepo.createConversation("project_b", "Conv B")
        database.messageQueries.insertMessage(
            id = "msg_b1",
            project_id = "project_b",
            conversation_id = convB,
            role = "user",
            content = "Message in project B about AI",
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
        val resultsA = searchRepo.searchMessages(
            query = "AI",
            projectId = "project_a",
            limit = 10
        )

        // Assert
        assertEquals(1, resultsA.size, "Should only find messages in project A")
        assertEquals("msg_a1", resultsA.first().id)
    }

    @Test
    fun `searchMessages filters by date range`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test")

        val now = Clock.System.now().toEpochMilliseconds()
        val oneHourAgo = now - (60 * 60 * 1000)
        val twoDaysAgo = now - (2 * 24 * 60 * 60 * 1000)

        // Old message
        database.messageQueries.insertMessage(
            id = "msg_old",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Old message about search",
            tokens = 10,
            timestamp = twoDaysAgo,
            image_uri = null,
            sentiment_valence = null,
            sentiment_arousal = null,
            sentiment_dominance = null,
            sentiment_emotion = null,
            sentiment_intensity = null,
            rag_sources = null,
            rag_confidence = null
        )

        // Recent message
        database.messageQueries.insertMessage(
            id = "msg_recent",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Recent message about search",
            tokens = 10,
            timestamp = now,
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
        val results = searchRepo.searchMessages(
            query = "search",
            projectId = null,
            startTimestamp = oneHourAgo,
            endTimestamp = null,
            limit = 10
        )

        // Assert
        assertEquals(1, results.size, "Should only find recent messages")
        assertEquals("msg_recent", results.first().id)
    }

    @Test
    fun `searchMessages filters by conversation ID`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val conv1 = conversationRepo.createConversation(projectId, "Conv 1")
        val conv2 = conversationRepo.createConversation(projectId, "Conv 2")

        database.messageQueries.insertMessage(
            id = "msg_conv1",
            project_id = projectId,
            conversation_id = conv1,
            role = "user",
            content = "Message in conversation 1",
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

        database.messageQueries.insertMessage(
            id = "msg_conv2",
            project_id = projectId,
            conversation_id = conv2,
            role = "user",
            content = "Message in conversation 2",
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
        val results = searchRepo.searchMessages(
            query = "Message",
            conversationId = conv1,
            limit = 10
        )

        // Assert
        assertEquals(1, results.size, "Should only find messages in conversation 1")
        assertEquals("msg_conv1", results.first().id)
    }

    // ==================== Ranking & Relevance Tests ====================

    @Test
    fun `searchMessages returns results ranked by relevance`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test")

        // Exact match
        database.messageQueries.insertMessage(
            id = "msg_exact",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "SQLDelight database queries",
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

        // Partial match
        database.messageQueries.insertMessage(
            id = "msg_partial",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "I love using databases for storage",
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

        // No match
        database.messageQueries.insertMessage(
            id = "msg_none",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Completely unrelated topic",
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
        val results = searchRepo.searchMessages(
            query = "SQLDelight database",
            projectId = null,
            limit = 10
        )

        // Assert
        assertTrue(results.isNotEmpty(), "Should find matches")
        // First result should be the most relevant (exact match)
        assertEquals("msg_exact", results.first().id, "Most relevant result should be first")
    }

    @Test
    fun `searchMessages respects limit parameter`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test")

        // Insert 10 messages
        repeat(10) { i ->
            database.messageQueries.insertMessage(
                id = "msg_$i",
                project_id = projectId,
                conversation_id = convId,
                role = "user",
                content = "Message $i about testing",
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
        }

        // Act
        val results = searchRepo.searchMessages(
            query = "testing",
            projectId = null,
            limit = 5
        )

        // Assert
        assertEquals(5, results.size, "Should respect limit of 5")
    }

    // ==================== Empty Results Tests ====================

    @Test
    fun `searchMessages with no matches returns empty list`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "This is about cats",
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
        val results = searchRepo.searchMessages(
            query = "quantum physics",
            projectId = null,
            limit = 10
        )

        // Assert
        assertEquals(0, results.size, "Should return empty list for no matches")
    }

    @Test
    fun `searchMessages on empty database returns empty list`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val searchRepo = SearchRepository(database)

        // Act
        val results = searchRepo.searchMessages(
            query = "anything",
            projectId = null,
            limit = 10
        )

        // Assert
        assertEquals(0, results.size, "Should return empty list for empty database")
    }

    // ==================== Edge Cases ====================

    @Test
    fun `searchMessages with empty query returns empty list`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val searchRepo = SearchRepository(database)

        // Act
        val results = searchRepo.searchMessages(
            query = "",
            projectId = null,
            limit = 10
        )

        // Assert
        assertEquals(0, results.size, "Empty query should return empty list")
    }

    @Test
    fun `searchMessages is case-insensitive`() {
        // Arrange
        val database = TestDatabaseFactory.createInMemoryDatabase()
        val conversationRepo = ConversationRepository(database)
        val searchRepo = SearchRepository(database)

        val projectId = "project_001"
        val convId = conversationRepo.createConversation(projectId, "Test")

        database.messageQueries.insertMessage(
            id = "msg_001",
            project_id = projectId,
            conversation_id = convId,
            role = "user",
            content = "Kotlin Multiplatform is AMAZING",
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
        val resultsLower = searchRepo.searchMessages(query = "kotlin", projectId = null, limit = 10)
        val resultsUpper = searchRepo.searchMessages(query = "KOTLIN", projectId = null, limit = 10)
        val resultsMixed = searchRepo.searchMessages(query = "KoTlIn", projectId = null, limit = 10)

        // Assert
        assertEquals(1, resultsLower.size, "Should find with lowercase")
        assertEquals(1, resultsUpper.size, "Should find with uppercase")
        assertEquals(1, resultsMixed.size, "Should find with mixed case")
    }
}
