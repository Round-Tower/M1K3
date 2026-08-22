package app.m1k3.ai.domain.memory

import kotlin.time.Clock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for MemoryManagerInterface.
 *
 * Uses a mock implementation to verify the interface contract.
 */
class MemoryManagerInterfaceTest {

    private class MockMemoryManager : MemoryManagerInterface {
        private val memories = mutableListOf<MemorySearchResult>()
        private var pinnedIds = mutableSetOf<String>()

        override suspend fun createMemoriesFromMessage(
            messageId: String,
            content: String,
            role: String,
            conversationContext: ConversationContext
        ): Result<Int> {
            val memory = MemorySearchResult(
                id = "mem_$messageId",
                content = content,
                importance = 0.5f,
                similarity = 0.0f,
                chunkIndex = 0,
                chunkTotal = 1,
                messageId = messageId,
                createdAt = Clock.System.now().toEpochMilliseconds()
            )
            memories.add(memory)
            return Result.success(1)
        }

        override suspend fun retrieveRelevantMemories(
            queryText: String,
            topK: Int
        ): Result<MemoryRetrievalResult> {
            val results = memories
                .map { it.copy(similarity = 0.9f) }
                .take(topK)
            return Result.success(
                MemoryRetrievalResult(
                    memories = results,
                    totalTokens = results.sumOf { it.content.split(" ").size },
                    droppedCount = 0
                )
            )
        }

        override fun getRecentMemories(limit: Int): List<MemorySearchResult> {
            return memories.takeLast(limit)
        }

        override fun getHighImportanceMemories(importanceThreshold: Float): List<MemorySearchResult> {
            return memories.filter { it.importance >= importanceThreshold }
        }

        override suspend fun deleteMemoriesForMessage(messageId: String): Result<Unit> {
            memories.removeAll { it.messageId == messageId }
            return Result.success(Unit)
        }

        override suspend fun cleanupLowImportanceMemories(importanceThreshold: Float): Result<Int> {
            val toRemove = memories.filter { it.importance < importanceThreshold && it.id !in pinnedIds }
            memories.removeAll(toRemove)
            return Result.success(toRemove.size)
        }

        override fun getMemoryStats(): MemoryStats? {
            if (memories.isEmpty()) return null
            return MemoryStats(
                totalMemories = memories.size.toLong(),
                averageImportance = memories.map { it.importance }.average().toFloat(),
                hasVectorIndex = true
            )
        }

        override fun getMemoryCount(): Long = memories.size.toLong()

        override fun pinMemory(memoryId: String) {
            pinnedIds.add(memoryId)
        }

        override fun unpinMemory(memoryId: String) {
            pinnedIds.remove(memoryId)
        }
    }

    @Test
    fun `createMemoriesFromMessage returns success with count`() = runSuspendTest {
        val manager = MockMemoryManager()
        val context = ConversationContext()

        val result = manager.createMemoriesFromMessage(
            messageId = "msg_1",
            content = "Test message content",
            role = "user",
            conversationContext = context
        )

        assertTrue(result.isSuccess)
        assertEquals(1, result.getOrNull())
    }

    @Test
    fun `retrieveRelevantMemories returns results`() = runSuspendTest {
        val manager = MockMemoryManager()
        val context = ConversationContext()

        manager.createMemoriesFromMessage("msg_1", "First memory", "user", context)
        manager.createMemoriesFromMessage("msg_2", "Second memory", "assistant", context)

        val result = manager.retrieveRelevantMemories("query", topK = 10)

        assertTrue(result.isSuccess)
        assertEquals(2, result.getOrNull()?.memories?.size)
    }

    @Test
    fun `getRecentMemories returns limited results`() = runSuspendTest {
        val manager = MockMemoryManager()
        val context = ConversationContext()

        manager.createMemoriesFromMessage("msg_1", "First", "user", context)
        manager.createMemoriesFromMessage("msg_2", "Second", "user", context)
        manager.createMemoriesFromMessage("msg_3", "Third", "user", context)

        val recent = manager.getRecentMemories(limit = 2)

        assertEquals(2, recent.size)
    }

    @Test
    fun `deleteMemoriesForMessage removes memories`() = runSuspendTest {
        val manager = MockMemoryManager()
        val context = ConversationContext()

        manager.createMemoriesFromMessage("msg_1", "To delete", "user", context)
        assertEquals(1, manager.getMemoryCount())

        manager.deleteMemoriesForMessage("msg_1")
        assertEquals(0, manager.getMemoryCount())
    }

    @Test
    fun `getMemoryStats returns null for empty manager`() {
        val manager = MockMemoryManager()

        assertNull(manager.getMemoryStats())
    }

    @Test
    fun `getMemoryStats returns stats when memories exist`() = runSuspendTest {
        val manager = MockMemoryManager()
        val context = ConversationContext()

        manager.createMemoriesFromMessage("msg_1", "Memory", "user", context)

        val stats = manager.getMemoryStats()
        assertNotNull(stats)
        assertEquals(1, stats.totalMemories)
    }

    @Test
    fun `pinMemory prevents cleanup`() = runSuspendTest {
        val manager = MockMemoryManager()
        val context = ConversationContext()

        manager.createMemoriesFromMessage("msg_1", "Low importance", "user", context)
        manager.pinMemory("mem_msg_1")

        val removed = manager.cleanupLowImportanceMemories(0.9f)

        assertEquals(0, removed.getOrNull())
        assertEquals(1, manager.getMemoryCount())
    }

    // Helper for suspend tests
    private fun runSuspendTest(block: suspend () -> Unit) {
        kotlinx.coroutines.test.runTest { block() }
    }
}
