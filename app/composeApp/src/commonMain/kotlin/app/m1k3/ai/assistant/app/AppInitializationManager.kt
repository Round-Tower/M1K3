package app.m1k3.ai.assistant.app

/**
 * Simple logging interface for testing
 * Allows implementations to use either KermitLogger or test mocks
 */
interface ILogger {
    fun i(message: String)

    fun e(
        error: Throwable?,
        message: String,
    )
}

/**
 * Sealed class representing initialization result
 *
 * Type-safe result handling without exceptions for expected failures
 * Follows project pattern (e.g., DatabaseInitResult).
 *
 * Variants:
 * - Success: Koin DI initialized
 * - KoinSetupFailed: Koin DI initialization failed with exception
 */
sealed class InitializationResult {
    data object Success : InitializationResult()

    data class KoinSetupFailed(
        val error: Exception,
    ) : InitializationResult()
}

/**
 * AppInitializationManager
 *
 * Handles Koin DI initialization
 *
 * **Responsibilities:**
 * - Initialize Koin dependency injection framework
 * - Return type-safe results instead of throwing exceptions
 * - Log all initialization steps for debugging
 *
 * **Error Handling:**
 * - Catches initialization exceptions
 * - Returns sealed failure types (KoinSetupFailed)
 * - Logs errors for debugging
 *
 * **Dependencies (Injected for testability):**
 * - logger: KermitLogger for debug/info/error messages
 * - koinInitializer: Callable to initialize Koin (mockable for tests)
 *
 * **Pattern:**
 * - Pure logic, no static methods
 * - Fully mockable dependencies
 * - Testable without Android context
 *
 * **Usage:**
 * ```kotlin
 * class MainActivity : ComponentActivity() {
 *     private val logger = Logger.withTag("MainActivity")
 *     private val appInitManager = AppInitializationManager(
 *         logger = logger,
 *         koinInitializer = {
 *             startKoin {
 *                 androidContext(this@MainActivity)
 *                 modules(allModules)
 *             }
 *         },
 *     )
 *
 *     override fun onCreate(savedInstanceState: Bundle?) {
 *         super.onCreate(savedInstanceState)
 *
 *         val koinResult = appInitManager.initializeKoin()
 *         when (koinResult) {
 *             is InitializationResult.Success -> logger.i("Koin ready")
 *             is InitializationResult.KoinSetupFailed -> logger.e(koinResult.error, "Koin failed")
 *         }
 *     }
 * }
 * ```
 */
class AppInitializationManager(
    private val logger: ILogger,
    private val koinInitializer: () -> Unit = { /* Implemented in Android */ },
) {
    /**
     * Initialize Koin dependency injection framework
     *
     * Wraps Koin initialization with error handling and logging
     *
     * @return InitializationResult.Success or InitializationResult.KoinSetupFailed
     */
    fun initializeKoin(): InitializationResult =
        try {
            koinInitializer()
            logger.i("Koin DI initialized successfully")
            InitializationResult.Success
        } catch (e: Exception) {
            logger.e(e, "Failed to initialize Koin DI")
            InitializationResult.KoinSetupFailed(e)
        }
}
