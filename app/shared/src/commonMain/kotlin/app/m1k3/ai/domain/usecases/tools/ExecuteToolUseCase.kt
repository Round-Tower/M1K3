package app.m1k3.ai.domain.usecases.tools

import app.m1k3.ai.domain.tools.ToolCall
import app.m1k3.ai.domain.tools.ToolError
import app.m1k3.ai.domain.tools.ToolResult
import app.m1k3.ai.domain.tools.services.ToolRegistry
import kotlin.time.Clock

/**
 * Execute Tool Use Case - Orchestrates tool execution
 *
 * Domain use case - Pure Kotlin, no platform dependencies.
 *
 * **Orchestration Steps:**
 * ```
 * 1. Find tool in registry
 *     ↓ (NotFound if missing)
 * 2. Get executor for tool
 *     ↓ (Unavailable if no executor)
 * 3. Check tool availability
 *     ↓ (Unavailable if not available on device)
 * 4. Validate arguments
 *     ↓ (InvalidArguments if validation fails)
 * 5. Check confirmation requirement
 *     ↓ (RequiresConfirmation if needed and not confirmed)
 * 6. Execute via platform executor
 *     ↓ (Success or Failure)
 * 7. Return result with execution time
 * ```
 *
 * **Usage:**
 * ```kotlin
 * val useCase = ExecuteToolUseCase(toolRegistry)
 *
 * val call = ToolCall("toggle_flashlight", mapOf("enable" to "true"), "")
 * when (val result = useCase.execute(call)) {
 *     is ToolResult.Success -> println(result.output)
 *     is ToolResult.Failure -> println(result.error.displayMessage)
 *     is ToolResult.RequiresConfirmation -> showConfirmationDialog(result)
 * }
 * ```
 */
class ExecuteToolUseCase(
    private val toolRegistry: ToolRegistry
) {
    /**
     * Execute a tool call
     *
     * @param call The tool invocation with arguments
     * @param confirmed Whether user has confirmed (for sensitive tools)
     * @return Result of execution (Success, Failure, or RequiresConfirmation)
     */
    suspend fun execute(call: ToolCall, confirmed: Boolean = false): ToolResult {
        val startTime = Clock.System.now().toEpochMilliseconds()

        // 1. Find tool in registry
        val tool = toolRegistry.findTool(call.toolId)
            ?: return ToolResult.Failure(
                toolId = call.toolId,
                error = ToolError.NotFound(call.toolId),
                executionTimeMs = elapsed(startTime)
            )

        // 2. Get executor for tool
        val executor = toolRegistry.getExecutor(call.toolId)
            ?: return ToolResult.Failure(
                toolId = call.toolId,
                error = ToolError.Unavailable("No executor registered for ${call.toolId}"),
                executionTimeMs = elapsed(startTime)
            )

        // 3. Check tool availability on device
        if (!executor.isAvailable()) {
            return ToolResult.Failure(
                toolId = call.toolId,
                error = ToolError.Unavailable("Tool not available on this device"),
                executionTimeMs = elapsed(startTime)
            )
        }

        // 4. Validate arguments
        executor.validateArguments(call.arguments).onFailure { e ->
            return ToolResult.Failure(
                toolId = call.toolId,
                error = ToolError.InvalidArguments(e.message ?: "Invalid arguments"),
                executionTimeMs = elapsed(startTime)
            )
        }

        // 5. Check confirmation requirement (skip if already confirmed)
        if (tool.requiresConfirmation && !confirmed) {
            return ToolResult.RequiresConfirmation(
                toolId = call.toolId,
                confirmationPrompt = "Allow ${tool.name}?",
                pendingCall = call,
                executionTimeMs = 0
            )
        }

        // 6. Execute via platform executor
        return try {
            executor.execute(call)
        } catch (e: Exception) {
            ToolResult.Failure(
                toolId = call.toolId,
                error = ToolError.ExecutionFailed(e),
                executionTimeMs = elapsed(startTime)
            )
        }
    }

    private fun elapsed(startTime: Long): Long =
        Clock.System.now().toEpochMilliseconds() - startTime
}
