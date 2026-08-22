package app.m1k3.ai.assistant.tools

import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.test.TestDatabaseFactory
import kotlin.time.Clock
import kotlin.test.*

/**
 * TDD RED Phase: ToolExecutionDataSource Tests
 *
 * Verifies persistent tool execution logging — every tool call
 * M1K3 makes gets recorded for analytics, debug, and "show me
 * my searches" queries.
 */
class ToolExecutionDataSourceTest {

    private lateinit var database: MaDatabase
    private lateinit var dataSource: ToolExecutionDataSource

    @BeforeTest
    fun setup() {
        database = TestDatabaseFactory.createInMemoryDatabase()
        // Seed a project so FK constraints pass
        database.projectQueries.insertProject(
            id = "test-project",
            name = "Test",
            description = null,
            created_at = Clock.System.now().toEpochMilliseconds(),
            updated_at = Clock.System.now().toEpochMilliseconds(),
            is_archived = 0,
            color = null,
            icon = null,
            message_count = 0,
            total_tokens = 0
        )
        dataSource = ToolExecutionDataSource(database)
    }

    // ===== Recording =====

    @Test
    fun `record successful tool execution`() {
        val now = Clock.System.now().toEpochMilliseconds()

        dataSource.record(
            id = "exec_1",
            toolId = "web_search",
            query = "weather in Cork",
            result = "Cloudy, 14C",
            success = true,
            errorMessage = null,
            executionTimeMs = 320,
            timestamp = now,
            messageId = null,
            projectId = "test-project"
        )

        val executions = database.toolExecutionQueries
            .getExecutionsForProject("test-project", 10)
            .executeAsList()

        assertEquals(1, executions.size)
        with(executions.first()) {
            assertEquals("web_search", tool_id)
            assertEquals("weather in Cork", query)
            assertEquals("Cloudy, 14C", result)
            assertEquals(1L, success)
            assertNull(error_message)
            assertEquals(320L, execution_time_ms)
        }
    }

    @Test
    fun `record failed tool execution with error`() {
        val now = Clock.System.now().toEpochMilliseconds()

        dataSource.record(
            id = "exec_2",
            toolId = "flashlight",
            query = "turn on",
            result = null,
            success = false,
            errorMessage = "Permission denied",
            executionTimeMs = 5,
            timestamp = now,
            messageId = null,
            projectId = "test-project"
        )

        val executions = database.toolExecutionQueries
            .getExecutionsForProject("test-project", 10)
            .executeAsList()

        assertEquals(1, executions.size)
        with(executions.first()) {
            assertEquals("flashlight", tool_id)
            assertEquals(0L, success)
            assertEquals("Permission denied", error_message)
        }
    }

    // ===== Querying =====

    @Test
    fun `get executions by tool ID - show all web searches`() {
        val now = Clock.System.now().toEpochMilliseconds()
        seedExecutions(now)

        val webSearches = dataSource.getByToolId("web_search", limit = 100)

        assertEquals(2, webSearches.size)
        assertTrue(webSearches.all { it.tool_id == "web_search" })
    }

    @Test
    fun `get executions for project ordered by timestamp desc`() {
        val now = Clock.System.now().toEpochMilliseconds()
        seedExecutions(now)

        val all = dataSource.getForProject("test-project", limit = 100)

        assertEquals(3, all.size)
        // Most recent first
        assertTrue(all[0].timestamp >= all[1].timestamp)
        assertTrue(all[1].timestamp >= all[2].timestamp)
    }

    @Test
    fun `get recent successful only`() {
        val now = Clock.System.now().toEpochMilliseconds()
        seedExecutions(now)

        val successful = dataSource.getRecentSuccessful("test-project", limit = 100)

        assertTrue(successful.all { it.success == 1L })
        assertEquals(2, successful.size)
    }

    // ===== Analytics =====

    @Test
    fun `tool usage stats aggregation`() {
        val now = Clock.System.now().toEpochMilliseconds()
        seedExecutions(now)

        val stats = dataSource.getToolUsageStats("test-project")

        assertEquals(2, stats.size, "Should have 2 distinct tools")

        val webSearchStats = stats.first { it.tool_id == "web_search" }
        assertEquals(2, webSearchStats.call_count)
        assertEquals(1, webSearchStats.success_count)

        val batteryStats = stats.first { it.tool_id == "battery" }
        assertEquals(1, batteryStats.call_count)
        assertEquals(1, batteryStats.success_count)
    }

    @Test
    fun `count executions for project`() {
        val now = Clock.System.now().toEpochMilliseconds()
        seedExecutions(now)

        val count = dataSource.countForProject("test-project")

        assertEquals(3, count)
    }

    // ===== Retention =====

    @Test
    fun `delete old executions`() {
        val now = Clock.System.now().toEpochMilliseconds()
        val oldTimestamp = now - (91L * 24 * 60 * 60 * 1000) // 91 days ago

        dataSource.record(
            id = "old_1", toolId = "battery", query = "level",
            result = "80%", success = true, errorMessage = null,
            executionTimeMs = 10, timestamp = oldTimestamp,
            messageId = null, projectId = "test-project"
        )
        dataSource.record(
            id = "new_1", toolId = "battery", query = "level",
            result = "60%", success = true, errorMessage = null,
            executionTimeMs = 10, timestamp = now,
            messageId = null, projectId = "test-project"
        )

        val cutoff = now - (90L * 24 * 60 * 60 * 1000) // 90 days ago
        dataSource.deleteOlderThan(cutoff)

        val remaining = dataSource.getForProject("test-project", limit = 100)
        assertEquals(1, remaining.size)
        assertEquals("new_1", remaining.first().id)
    }

    // ===== Helpers =====

    private fun seedExecutions(now: Long) {
        dataSource.record(
            id = "exec_a", toolId = "web_search", query = "weather Cork",
            result = "Cloudy, 14C", success = true, errorMessage = null,
            executionTimeMs = 300, timestamp = now - 3000,
            messageId = null, projectId = "test-project"
        )
        dataSource.record(
            id = "exec_b", toolId = "web_search", query = "best pint Cork",
            result = null, success = false, errorMessage = "No results",
            executionTimeMs = 500, timestamp = now - 2000,
            messageId = null, projectId = "test-project"
        )
        dataSource.record(
            id = "exec_c", toolId = "battery", query = "level",
            result = "85%", success = true, errorMessage = null,
            executionTimeMs = 10, timestamp = now - 1000,
            messageId = null, projectId = "test-project"
        )
    }
}
