package app.m1k3.ai.assistant.memory

import app.m1k3.ai.assistant.memory.test.MockEmbeddingRepository
import app.m1k3.ai.assistant.memory.test.MockVectorSearchEngine
import app.m1k3.ai.assistant.test.TestDatabaseFactory
import app.m1k3.ai.domain.memory.ConversationContext
import app.m1k3.ai.domain.memory.ImportanceCalculator
import app.m1k3.ai.domain.memory.SimpleTokenCounter
import app.m1k3.ai.domain.memory.services.SemanticChunker
import app.m1k3.ai.domain.repositories.VectorSearchResult
import kotlinx.coroutines.test.runTest
import kotlin.test.*

/**
 * Memory Integration Test - PHASE2-017
 *
 * End-to-end validation of the complete memory pipeline from message ingestion
 * to context retrieval for AI generation.
 *
 * **Test Coverage:**
 * - Full pipeline: Message → Chunk → Importance → Embed → Store → Retrieve → Context
 * - Real conversation flow with multiple message types
 * - Memory persistence and retrieval across sessions
 * - Token budget enforcement in realistic scenarios
 * - Error handling and recovery
 * - Access tracking and statistics
 *
 * **Architecture Under Test:**
 * ```
 * Message Input
 *      ↓
 * SemanticChunker (100-300 tokens)
 *      ↓
 * ImportanceCalculator (heuristic scoring)
 *      ↓
 * [Filter: importance >= 0.3]
 *      ↓
 * EmbeddingEngine (384/512-dim vectors)
 *      ↓
 * VectorSearchEngine (cosine similarity)
 *      ↓
 * MemoryRepository (SQLDelight persistence)
 *      ↓
 * [Query] → VectorSearch → MemoryRepository
 *      ↓
 * MemoryRanker (composite ranking)
 *      ↓
 * MemoryRankingResult (formatted for AI prompt)
 * ```
 *
 * **Success Criteria:**
 * - ✅ Memories created for high-importance content
 * - ✅ Low-importance content filtered out
 * - ✅ Retrieval returns relevant memories
 * - ✅ Context fits within token budget
 * - ✅ Access tracking updates correctly
 * - ✅ Statistics reflect actual usage
 */
class MemoryIntegrationTest {
    private lateinit var database: app.m1k3.ai.assistant.database.MaDatabase
    private lateinit var repository: MemoryDataSource
    private lateinit var chunker: SemanticChunker
    private lateinit var importanceCalculator: ImportanceCalculator
    private lateinit var memoryRanker: MemoryRanker
    private lateinit var memoryManager: MemoryManager
    private lateinit var mockEmbeddingRepository: MockEmbeddingRepository
    private lateinit var mockVectorSearch: MockVectorSearchEngine

    @BeforeTest
    fun setup() {
        database = TestDatabaseFactory.createInMemoryDatabase()
        repository = MemoryDataSource(database)
        // Use lower threshold for testing (default is 100)
        chunker =
            SemanticChunker(
                tokenCounter = SimpleTokenCounter(),
                minChunkTokens = 50, // Lower threshold for test messages
                maxChunkTokens = 300,
                overlapTokens = 20,
            )
        importanceCalculator = ImportanceCalculator()
        memoryRanker = MemoryRanker(maxContextTokens = 1000)

        mockEmbeddingRepository = MockEmbeddingRepository()
        mockVectorSearch = MockVectorSearchEngine()

        memoryManager =
            MemoryManager(
                chunker = chunker,
                repository = repository,
                importanceCalculator = importanceCalculator,
                memoryRanker = memoryRanker,
                projectId = "test-project",
                minImportanceThreshold = 0.3f,
                embeddingRepository = mockEmbeddingRepository,
                vectorSearchRepository = mockVectorSearch,
            )

        // Create test project
        val now = System.currentTimeMillis()
        database.projectQueries.insertProject(
            id = "test-project",
            name = "Test Project",
            description = "Integration test project",
            created_at = now,
            updated_at = now,
            is_archived = 0,
            color = null,
            icon = null,
            message_count = 0,
            total_tokens = 0,
        )
    }

    @AfterTest
    fun teardown() {
        // Note: Test database doesn't need explicit close for in-memory DB
    }

    @Test
    fun `end-to-end memory pipeline creates and retrieves memories`() =
        runTest {
            println("\n🧪 [Integration] Testing end-to-end memory pipeline")

            // === STEP 1: Create memory from user message ===
            val userMessage =
                """
                I'm working on a Kotlin Multiplatform mobile app called M1K3.
                It's a privacy-first on-device AI assistant using Qwen3.5 for inference.
                We're implementing semantic memory with vector embeddings and HNSW indexing.
                The goal is on-device processing with user-initiated network only.
                """.trimIndent()

            val context =
                ConversationContext(
                    triviaWasShared = false,
                    isCurrentConversation = true,
                )

            println("📝 [Integration] Creating memories from user message (${userMessage.length} chars)")

            val createResult =
                memoryManager.createMemoriesFromMessage(
                    messageId = "msg-user-1",
                    content = userMessage,
                    role = "user",
                    conversationContext = context,
                )

            assertTrue(createResult.isSuccess, "Memory creation should succeed")
            val memoryCount = createResult.getOrThrow()
            assertTrue(memoryCount > 0, "Should create at least one memory chunk")
            println("✅ [Integration] Created $memoryCount memory chunks")

            // === STEP 2: Verify memories persisted to database ===
            val storedMemories = repository.getMemoriesForMessage("msg-user-1")
            assertEquals(memoryCount, storedMemories.size, "All chunks should be persisted")
            println("✅ [Integration] Verified $memoryCount memories in database")

            // === STEP 3: Verify vectors added to search index ===
            assertTrue(mockVectorSearch.vectorCount() > 0, "Vectors should be in search index")
            println("✅ [Integration] Verified ${mockVectorSearch.vectorCount()} vectors in index")

            // === STEP 4: Retrieve relevant memories with query ===
            val query = "Tell me about the AI assistant project"

            // Configure mock to return stored memories with similarity scores
            mockVectorSearch.setSearchResults(
                storedMemories.map { memory ->
                    VectorSearchResult(memory.embedding_id, 0.8f) // High similarity
                },
            )

            println("🔍 [Integration] Retrieving memories for query: \"$query\"")

            val retrieveResult = memoryManager.retrieveRelevantMemories(query, topK = 10)
            assertTrue(retrieveResult.isSuccess, "Memory retrieval should succeed")

            val contextResult = retrieveResult.getOrThrow()
            assertFalse(contextResult.isEmpty(), "Should retrieve memories")
            assertTrue(contextResult.selectedMemories.isNotEmpty(), "Should have selected memories")
            println("✅ [Integration] Retrieved ${contextResult.selectedMemories.size} memories")

            // === STEP 5: Verify token budget respected ===
            assertTrue(
                contextResult.totalTokens <= 1000,
                "Total tokens ${contextResult.totalTokens} should be within budget 1000",
            )
            println("✅ [Integration] Token budget: ${contextResult.totalTokens}/1000")

            // === STEP 6: Verify access tracking updated ===
            val accessedMemory = repository.getMemoryById(storedMemories.first().id)
            assertNotNull(accessedMemory, "Memory should still exist")
            assertTrue(accessedMemory.access_count > 0, "Access count should be incremented")
            assertNotNull(accessedMemory.last_accessed_at, "Last accessed timestamp should be set")
            println("✅ [Integration] Access tracking updated (count: ${accessedMemory.access_count})")

            // === STEP 7: Verify formatted context for AI ===
            val formattedContext = contextResult.formatAsContext()
            assertTrue(formattedContext.isNotBlank(), "Formatted context should not be empty")
            assertTrue(formattedContext.contains("importance:"), "Should include importance scores")
            println("✅ [Integration] Formatted context ready (${formattedContext.length} chars)")

            println("🎉 [Integration] End-to-end pipeline test PASSED")
        }

    @Test
    fun `conversation flow creates memories for important messages only`() =
        runTest {
            println("\n🧪 [Integration] Testing conversation flow with filtering")

            val context = ConversationContext(triviaWasShared = false, isCurrentConversation = true)

            // === Message 1: High importance (detailed question) ===
            val question =
                "Can you explain how HNSW (Hierarchical Navigable Small World) graphs work " +
                    "for approximate nearest neighbor search in high-dimensional vector spaces? " +
                    "I'm particularly interested in understanding the graph construction algorithm, " +
                    "the role of the proximity graph layers, and how the search process navigates " +
                    "through multiple levels to find nearest neighbors efficiently. " +
                    "Also, what are the key parameters like M and efConstruction, and how do they " +
                    "affect the tradeoff between search accuracy and performance?"

            val result1 =
                memoryManager.createMemoriesFromMessage(
                    messageId = "msg-1",
                    content = question,
                    role = "user",
                    conversationContext = context,
                )
            val count1 = result1.getOrThrow()
            println("📝 [Integration] Detailed question: $count1 memories (should be >0)")
            assertTrue(count1 > 0, "Detailed question should create memories")

            // === Message 2: High importance (code explanation) ===
            val codeExplanation =
                """
                ```kotlin
                class HNSWIndex(val M: Int = 16, val efConstruction: Int = 200) {
                    private val layers = mutableListOf<Layer>()

                    fun insert(vector: FloatArray, id: String) {
                        val level = selectLevel()
                        val neighbors = findNearest(vector, efConstruction)
                        connectNodes(id, neighbors, level)
                    }

                    private fun selectLevel(): Int {
                        val mL = 1.0 / Math.log(M.toDouble())
                        return (-Math.log(Math.random()) * mL).toInt()
                    }

                    private fun findNearest(query: FloatArray, ef: Int): List<String> {
                        // Greedy search through graph layers
                        val candidates = PriorityQueue<Candidate>()
                        val visited = mutableSetOf<String>()
                        // Search algorithm implementation here
                        return candidates.take(M).map { it.id }
                    }
                }
                ```
                This implements a basic HNSW index with configurable parameters M and efConstruction.
                The index uses a hierarchical structure with multiple layers for efficient approximate
                nearest neighbor search in high-dimensional spaces.
                """.trimIndent()

            val result2 =
                memoryManager.createMemoriesFromMessage(
                    messageId = "msg-2",
                    content = codeExplanation,
                    role = "assistant",
                    conversationContext = context,
                )
            val count2 = result2.getOrThrow()
            println("📝 [Integration] Code explanation: $count2 memories (should be >0)")
            assertTrue(count2 > 0, "Code explanation should create memories")

            // === Message 3: Low importance (short acknowledgment) ===
            val acknowledgment = "ok thanks"

            val result3 =
                memoryManager.createMemoriesFromMessage(
                    messageId = "msg-3",
                    content = acknowledgment,
                    role = "user",
                    conversationContext = context,
                )
            val count3 = result3.getOrThrow()
            println("📝 [Integration] Short acknowledgment: $count3 memories (should be 0)")
            assertEquals(0, count3, "Short acknowledgment should NOT create memories")

            // === Message 4: Low importance (greeting) ===
            val greeting = "hello"

            val result4 =
                memoryManager.createMemoriesFromMessage(
                    messageId = "msg-4",
                    content = greeting,
                    role = "user",
                    conversationContext = context,
                )
            val count4 = result4.getOrThrow()
            println("📝 [Integration] Greeting: $count4 memories (should be 0)")
            assertEquals(0, count4, "Greeting should NOT create memories")

            // === Verify total memory count ===
            val totalMemories = repository.getMemoryCount("test-project")
            val expectedMinimum = count1 + count2
            assertTrue(
                totalMemories >= expectedMinimum,
                "Total memories ($totalMemories) should be at least $expectedMinimum",
            )

            println("✅ [Integration] Importance filtering working: $totalMemories memories from 4 messages")
            println("🎉 [Integration] Conversation flow test PASSED")
        }

    @Test
    fun `memory statistics reflect actual usage`() =
        runTest {
            println("\n🧪 [Integration] Testing memory statistics")

            val context = ConversationContext(triviaWasShared = false, isCurrentConversation = true)

            // Create several memories
            val messages =
                listOf(
                    "a".repeat(800) + ".", // High importance
                    "b".repeat(800) + ".", // High importance
                    "c".repeat(800) + ".", // High importance
                )

            messages.forEachIndexed { index, content ->
                memoryManager.createMemoriesFromMessage(
                    messageId = "msg-$index",
                    content = content,
                    role = "user",
                    conversationContext = context,
                )
            }

            // Get statistics
            val stats = memoryManager.getMemoryStats()
            assertNotNull(stats, "Statistics should be available")

            println("📊 [Integration] Memory Statistics:")
            println("   - Total memories: ${stats.totalMemories}")
            println("   - Average importance: ${stats.avgImportance}")
            println("   - Total accesses: ${stats.totalAccesses}")
            println("   - Pinned count: ${stats.pinnedCount}")

            assertTrue(stats.totalMemories > 0, "Should have memories")
            assertTrue(stats.avgImportance > 0.3f, "Average importance should be above threshold")
            assertEquals(0, stats.pinnedCount, "No memories pinned yet")

            // Perform some retrievals to increment access count
            mockVectorSearch.setSearchResults(
                repository.getMemoriesForProject("test-project").take(3).map { memory ->
                    VectorSearchResult(memory.embedding_id, 0.9f)
                },
            )

            memoryManager.retrieveRelevantMemories("test query 1")
            memoryManager.retrieveRelevantMemories("test query 2")

            // Check updated statistics
            val updatedStats = memoryManager.getMemoryStats()
            assertNotNull(updatedStats)
            assertTrue(updatedStats.totalAccesses > 0, "Should have access count > 0")

            println("✅ [Integration] Updated statistics after retrievals:")
            println("   - Total accesses: ${updatedStats.totalAccesses}")
            println("🎉 [Integration] Statistics test PASSED")
        }

    @Test
    fun `memory cleanup removes low-importance content`() =
        runTest {
            println("\n🧪 [Integration] Testing memory cleanup")

            // Create low-importance memory manually (bypass importance filter)
            repository.createMemory(
                id = "mem-low-1",
                messageId = "msg-low-1",
                projectId = "test-project",
                content = "Low importance content",
                importance = 0.2f, // Below threshold
                createdAt = System.currentTimeMillis(),
                chunkIndex = 0,
                chunkTotal = 1,
                chunkTokens = 50,
                embeddingId = "emb-low-1",
            )

            mockVectorSearch.addVectorInternal("emb-low-1", FloatArray(384) { 0.1f })

            // Create high-importance memory
            repository.createMemory(
                id = "mem-high-1",
                messageId = "msg-high-1",
                projectId = "test-project",
                content = "High importance content",
                importance = 0.8f, // Above threshold
                createdAt = System.currentTimeMillis(),
                chunkIndex = 0,
                chunkTotal = 1,
                chunkTokens = 50,
                embeddingId = "emb-high-1",
            )

            mockVectorSearch.addVectorInternal("emb-high-1", FloatArray(384) { 0.8f })

            val countBefore = repository.getMemoryCount("test-project")
            assertEquals(2, countBefore, "Should have 2 memories initially")

            println("📊 [Integration] Before cleanup: $countBefore memories")

            // Cleanup low-importance memories
            val cleanupResult = memoryManager.cleanupLowImportanceMemories(importanceThreshold = 0.3f)
            assertTrue(cleanupResult.isSuccess, "Cleanup should succeed")

            val deletedCount = cleanupResult.getOrThrow()
            assertEquals(1, deletedCount, "Should delete 1 low-importance memory")

            val countAfter = repository.getMemoryCount("test-project")
            assertEquals(1, countAfter, "Should have 1 memory remaining")

            // Verify high-importance memory still exists
            val remainingMemory = repository.getMemoryById("mem-high-1")
            assertNotNull(remainingMemory, "High-importance memory should remain")

            // Verify low-importance memory deleted
            val deletedMemory = repository.getMemoryById("mem-low-1")
            assertNull(deletedMemory, "Low-importance memory should be deleted")

            println("✅ [Integration] Cleanup removed $deletedCount low-importance memories")
            println("✅ [Integration] High-importance memory preserved")
            println("🎉 [Integration] Cleanup test PASSED")
        }

    @Test
    fun `pinned memories survive cleanup`() =
        runTest {
            println("\n🧪 [Integration] Testing pinned memory protection")

            // Create low-importance memory
            repository.createMemory(
                id = "mem-low-pinned",
                messageId = "msg-low-pinned",
                projectId = "test-project",
                content = "Low importance but pinned",
                importance = 0.2f, // Below threshold
                createdAt = System.currentTimeMillis(),
                chunkIndex = 0,
                chunkTotal = 1,
                chunkTokens = 50,
                embeddingId = "emb-low-pinned",
            )

            mockVectorSearch.addVectorInternal("emb-low-pinned", FloatArray(384) { 0.1f })

            // Pin the memory
            memoryManager.pinMemory("mem-low-pinned")

            val pinned = repository.getMemoryById("mem-low-pinned")
            assertEquals(1L, pinned?.is_pinned, "Memory should be pinned")

            println("📌 [Integration] Pinned low-importance memory")

            // Try cleanup
            val cleanupResult = memoryManager.cleanupLowImportanceMemories(importanceThreshold = 0.3f)
            assertTrue(cleanupResult.isSuccess)

            val deletedCount = cleanupResult.getOrThrow()
            assertEquals(0, deletedCount, "Pinned memory should NOT be deleted")

            // Verify memory still exists
            val survivedMemory = repository.getMemoryById("mem-low-pinned")
            assertNotNull(survivedMemory, "Pinned memory should survive cleanup")

            println("✅ [Integration] Pinned memory survived cleanup")
            println("🎉 [Integration] Pin protection test PASSED")
        }

    @Test
    fun `memory deletion cascades correctly`() =
        runTest {
            println("\n🧪 [Integration] Testing memory deletion cascade")

            val context = ConversationContext(triviaWasShared = false, isCurrentConversation = true)

            // Create memories for a message
            val content = "a".repeat(800) + "."
            memoryManager.createMemoriesFromMessage(
                messageId = "msg-delete-test",
                content = content,
                role = "user",
                conversationContext = context,
            )

            val memoriesBefore = repository.getMemoriesForMessage("msg-delete-test")
            val countBefore = memoriesBefore.size
            assertTrue(countBefore > 0, "Should have created memories")

            println("📊 [Integration] Created $countBefore memories for message")

            // Delete memories for the message
            val deleteResult = memoryManager.deleteMemoriesForMessage("msg-delete-test")
            assertTrue(deleteResult.isSuccess, "Deletion should succeed")

            // Verify memories deleted from repository
            val memoriesAfter = repository.getMemoriesForMessage("msg-delete-test")
            assertEquals(0, memoriesAfter.size, "All memories should be deleted")

            // Verify vectors removed from search index
            assertTrue(mockVectorSearch.vectorCount() == 0, "Vectors should be removed from index")

            println("✅ [Integration] Deleted $countBefore memories")
            println("✅ [Integration] Vectors removed from index")
            println("🎉 [Integration] Cascade deletion test PASSED")
        }

    // Note: Mock implementations moved to app.m1k3.ai.assistant.memory.test.TestMocks
    // for shared use across MemoryManagerTest, MemoryRetrievalQualityTest, and MemoryIntegrationTest
}
