package app.m1k3.ai.assistant.app

import kotlin.test.Test
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * TDD Tests for AppInitializationManager
 *
 * Verifies Koin DI setup with error handling via type-safe sealed results
 *
 * **Test Strategy (Red → Green → Refactor):**
 * - Uses MockLogger to capture logs without Kermit dependency
 * - Sealed class results avoid exceptions for expected failures
 * - AAA pattern: Arrange, Act, Assert
 * - Can inject failures via MockLogger for error path testing
 */
class AppInitializationManagerTest {
    private lateinit var mockLogger: MockLogger
    private lateinit var manager: AppInitializationManager

    private fun setup() {
        mockLogger = MockLogger()
        manager = AppInitializationManager(mockLogger)
    }

    // ============ Koin Initialization Tests ============

    @Test
    fun `initializeKoin succeeds on valid state`() {
        // GREEN: Verify Koin initialization returns Success
        setup()

        val result = manager.initializeKoin()

        assertIs<InitializationResult.Success>(result)
        assertTrue(mockLogger.debugMessages.any { it.contains("Koin") })
    }

    @Test
    fun `initializeKoin handles failure with error result`() {
        // GREEN: Verify Koin failure returns sealed result with exception
        setup()
        mockLogger.simulateKoinFailure = true

        val result = manager.initializeKoin()

        assertIs<InitializationResult.KoinSetupFailed>(result)
        val failResult = result as InitializationResult.KoinSetupFailed
        assertTrue(failResult.error.message?.contains("Koin") == true)
        assertTrue(mockLogger.errorMessages.isNotEmpty())
    }

    @Test
    fun `initializeKoin logs error on failure`() {
        // GREEN: Verify error is logged for debugging
        setup()
        mockLogger.simulateKoinFailure = true

        manager.initializeKoin()

        assertTrue(mockLogger.errorMessages.any { it.contains("Koin") })
    }
}

/**
 * Mock Logger for testing
 *
 * Implements ILogger and captures calls for test assertions
 * Allows injecting failures for error path testing by detecting component names in messages
 */
class MockLogger : ILogger {
    val debugMessages = mutableListOf<String>()
    val errorMessages = mutableListOf<String>()

    var simulateKoinFailure = false

    override fun i(message: String) {
        debugMessages.add(message)
        if (simulateKoinFailure && message.contains("Koin")) {
            throw Exception("Koin initialization failed (simulated)")
        }
    }

    override fun e(
        error: Throwable?,
        message: String,
    ) {
        errorMessages.add(message)
    }
}
