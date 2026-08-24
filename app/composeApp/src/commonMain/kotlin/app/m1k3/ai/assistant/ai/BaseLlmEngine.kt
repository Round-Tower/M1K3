package app.m1k3.ai.assistant.ai

import app.m1k3.ai.domain.ai.GenerationConfig
import app.m1k3.ai.domain.ai.LlmEngine

/**
 * BaseLlmEngine - App-layer interface extending domain LlmEngine
 *
 * This interface abstracts common LLM functionality across different backends:
 * - LlamaCppEngine (llama.cpp via Llamatik)
 * - MockLlmEngine (testing)
 * - Future engines (cloud fallbacks, etc.)
 *
 * Design principles:
 * 1. **Platform agnostic** - Works across Android, iOS, Desktop
 * 2. **Backend flexibility** - Supports engines with varying capabilities
 * 3. **Test-friendly** - Easy to mock for UI testing
 * 4. **Result-based error handling** - No surprise exceptions, explicit error handling
 * 5. **Configuration graceful degradation** - Handles engines with limited configuration APIs
 *
 * Error Handling:
 * - All methods return Result<T> for explicit error handling
 * - No unchecked exceptions thrown
 * - Errors can be inspected, logged, or recovered from
 *
 * Usage example:
 * ```kotlin
 * val engine: BaseLlmEngine = LlamaCppEngine(context)
 * engine.initialize().onFailure { error ->
 *     logger.e(error) { "Initialization failed" }
 *     return
 * }
 *
 * val config = GenerationConfig(
 *     maxTokens = 256,
 *     temperature = 0.7f,
 *     systemPrompt = "You are a helpful assistant"
 * )
 *
 * // Blocking generation with error handling
 * engine.generate("Hello!", config).onSuccess { result ->
 *     println(result.text)
 * }.onFailure { error ->
 *     logger.e(error) { "Generation failed" }
 * }
 *
 * // Streaming generation
 * engine.generateStreaming("Tell me a story", config) { token ->
 *     print(token)  // Real-time token display
 * }.onFailure { error ->
 *     logger.e(error) { "Streaming failed" }
 * }
 *
 * engine.release()
 * ```
 */
interface BaseLlmEngine : LlmEngine {
    /**
     * Initialize the AI engine.
     *
     * This may include:
     * - Loading model files from assets to internal storage
     * - Creating inference sessions
     * - Initializing tokenizers
     * - Setting up device-adaptive configurations
     *
     * Must be called before any generation methods.
     *
     * @return Result.success(Unit) if initialization succeeds, Result.failure(exception) otherwise
     */
    override suspend fun initialize(): Result<Unit>

    /**
     * Generate AI response for a given prompt (blocking).
     *
     * Blocks until the full response is generated, then returns the complete result.
     *
     * @param prompt User input text
     * @param config Generation configuration (temperature, max tokens, system prompt, etc.)
     * @return Result.success(GenerationResult) if generation succeeds, Result.failure(exception) otherwise
     *         Common failures: engine not initialized, inference error, model crash
     */
    override suspend fun generate(
        prompt: String,
        config: GenerationConfig,
    ): Result<GenerationResult>

    /**
     * Generate AI response with streaming token-by-token callback.
     *
     * Provides real-time generation feedback by calling onToken for each generated token.
     * Ideal for chat UIs where you want to show progressive responses.
     *
     * @param prompt User input text
     * @param config Generation configuration
     * @param onToken Callback invoked for each generated token (called on inference thread)
     * @return Result.success(Unit) if streaming completes, Result.failure(exception) if error occurs
     *         Common failures: engine not initialized, inference error, callback exception
     */
    override suspend fun generateStreaming(
        prompt: String,
        config: GenerationConfig,
        onToken: (String) -> Unit,
    ): Result<Unit>

    /**
     * Cooperatively stop an in-flight generation. The current [generateStreaming]
     * / native chat call breaks at its next token and returns the text produced
     * so far as a normal success — the caller finalizes the partial answer
     * (like tapping "stop" mid-response in ChatGPT).
     *
     * Default no-op — engines without a native stop hook (mocks) simply run to
     * completion.
     */
    fun stopGeneration() {}

    /**
     * Get device-appropriate maximum tokens for generation.
     *
     * Returns optimal max tokens based on:
     * - Device RAM
     * - CPU capabilities
     * - Model size and architecture
     *
     * Public API for UI to determine response length limits.
     *
     * @return Recommended max tokens (64-512 depending on device)
     */
    override fun getOptimalMaxTokens(): Int

    /**
     * Release engine resources.
     *
     * Cleans up:
     * - Native inference sessions
     * - Memory-mapped model files
     * - Tokenizer resources
     *
     * Call this when engine is no longer needed to free memory.
     * After calling release(), the engine must be re-initialized before use.
     */
    override fun release()

    /**
     * Close engine (alias for release() for AutoCloseable compatibility).
     *
     * Allows use with `use {}` blocks for automatic resource management.
     */
    override fun close() = release()
}

/**
 * GenerationResult.
 *
 * @deprecated Use app.m1k3.ai.domain.ai.GenerationResult instead.
 * This typealias exists for backward compatibility.
 */
typealias GenerationResult = app.m1k3.ai.domain.ai.GenerationResult
