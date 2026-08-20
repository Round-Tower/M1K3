package app.m1k3.ai.assistant.memory

import app.m1k3.ai.assistant.test.TestDatabaseFactory
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Integration tests for MemoriesViewModel against an in-memory JDBC SQLite
 * database via TestDatabaseFactory — same pattern as
 * SqlDelightPassageRepositoryTest, since MemoryDataSource wraps a real
 * MaDatabase rather than exposing an interface a fake could implement.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MemoriesViewModelTest {
    private lateinit var dataSource: MemoryDataSource
    private val projectId = "default"

    @BeforeTest
    fun setUp() {
        dataSource = MemoryDataSource(TestDatabaseFactory.createInMemoryDatabase())
    }

    private fun build(): Pair<MemoriesViewModel, TestScope> {
        val scope = TestScope(StandardTestDispatcher())
        return MemoriesViewModel(dataSource, projectId, scope) to scope
    }

    private fun seedMemory(
        id: String,
        content: String,
        createdAt: Long = 1_700_000_000_000L,
    ) {
        dataSource.createMemory(
            id = id,
            messageId = "msg-$id",
            projectId = projectId,
            content = content,
            importance = 0.5f,
            createdAt = createdAt,
            chunkIndex = 0,
            chunkTotal = 1,
            chunkTokens = 5,
            embeddingId = "emb-$id",
        )
    }

    @Test
    fun `initial state has no query, zero count, no results`() {
        val (vm, _) = build()
        val s = vm.state.value
        assertEquals("", s.query)
        assertEquals(0L, s.liveCount)
        assertTrue(s.results.isEmpty())
        assertFalse(s.isSearching)
        assertFalse(s.hasQuery)
    }

    @Test
    fun `load populates the live memory count`() =
        runTest {
            seedMemory("a", "The user lives in Ardmore")
            seedMemory("b", "The user likes coffee")
            val (vm, scope) = build()

            vm.load()
            scope.advanceUntilIdle()

            assertEquals(2L, vm.state.value.liveCount)
        }

    @Test
    fun `updateQuery does not search — search only runs on submit`() =
        runTest {
            seedMemory("a", "The user lives in Ardmore")
            val (vm, scope) = build()

            vm.updateQuery("Ardmore")
            scope.advanceUntilIdle()

            assertEquals("Ardmore", vm.state.value.query)
            assertTrue(
                vm.state.value.results
                    .isEmpty(),
            )
        }

    @Test
    fun `submitSearch finds a matching memory by content`() =
        runTest {
            seedMemory("a", "The user lives in Ardmore, Co. Waterford")
            seedMemory("b", "The user likes coffee in the morning")
            val (vm, scope) = build()

            vm.updateQuery("Ardmore")
            vm.submitSearch()
            scope.advanceUntilIdle()

            assertEquals(1, vm.state.value.results.size)
            assertEquals(
                "a",
                vm.state.value.results
                    .first()
                    .id,
            )
            assertFalse(vm.state.value.isSearching)
        }

    @Test
    fun `submitSearch with no matches returns empty results, not an error`() =
        runTest {
            seedMemory("a", "The user lives in Ardmore")
            val (vm, scope) = build()

            vm.updateQuery("nonexistent phrase")
            vm.submitSearch()
            scope.advanceUntilIdle()

            assertTrue(
                vm.state.value.results
                    .isEmpty(),
            )
            assertTrue(vm.state.value.hasQuery)
        }

    @Test
    fun `clearing the query back to blank clears stale results immediately`() =
        runTest {
            seedMemory("a", "The user lives in Ardmore")
            val (vm, scope) = build()

            vm.updateQuery("Ardmore")
            vm.submitSearch()
            scope.advanceUntilIdle()
            assertEquals(1, vm.state.value.results.size)

            vm.updateQuery("")

            assertTrue(
                vm.state.value.results
                    .isEmpty(),
            )
            assertFalse(vm.state.value.hasQuery)
        }

    @Test
    fun `submitSearch with blank query is a no-op that clears results`() =
        runTest {
            val (vm, scope) = build()

            vm.submitSearch()
            scope.advanceUntilIdle()

            assertTrue(
                vm.state.value.results
                    .isEmpty(),
            )
            assertFalse(vm.state.value.isSearching)
        }
}
