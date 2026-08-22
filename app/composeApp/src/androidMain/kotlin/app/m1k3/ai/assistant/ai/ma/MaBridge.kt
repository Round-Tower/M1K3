package app.m1k3.ai.assistant.ai.ma

import app.m1k3.ai.domain.ai.MaInferenceBackend

/**
 * MaBridge - JNI bridge to the Ma native inference library.
 *
 * Ma wraps llama.cpp's stable C API, pinned to b8637+ (required for Gemma 4).
 * Built via NDK/CMake as `libma.so`, shipped with the APK for arm64-v8a and x86_64.
 *
 * ## Key improvements over Llamatik:
 * - llama.cpp b8637+ (Gemma 4 support — Llamatik was stuck at b7815, Jan 2025)
 * - True token-level streaming (NewStringUTF on complete token pieces only)
 * - Handle-based API (multiple model contexts can coexist)
 * - Explicit resource release (no orphaned contexts)
 *
 * ## Thread safety:
 * Each context handle is NOT thread-safe. [LlamaCppEngine] uses coroutines
 * with Mutex to guarantee single-threaded access per context.
 *
 * ## Setup (one-time):
 * ```
 * git submodule add https://github.com/ggerganov/llama.cpp.git \
 *     app/composeApp/src/androidMain/cpp/llama.cpp
 * cd app/composeApp/src/androidMain/cpp/llama.cpp
 * git checkout <commit-hash-for-b8637+>
 * ```
 */
object MaBridge : MaInferenceBackend {
    init {
        System.loadLibrary("ma")
    }

    /**
     * Load a GGUF model from the given path.
     *
     * Tuning parameters map directly onto `llama_context_params` fields:
     * `n_ctx`, `n_batch`, `n_ubatch`, `n_threads`, `n_threads_batch`,
     * `flash_attn_type`, `type_k`/`type_v`. See InferenceTuning.resolve().
     *
     * @return Opaque context handle (pointer cast to Long), or 0 on failure
     */
    override fun init(
        modelPath: String,
        nCtx: Int,
        nBatch: Int,
        nUbatch: Int,
        threadsGen: Int,
        threadsBatch: Int,
        useFlashAttn: Boolean,
        kvQuantOrdinal: Int,
        useMlock: Boolean,
        nativeLibraryDir: String,
    ): Long =
        nativeInit(
            modelPath,
            nCtx,
            nBatch,
            nUbatch,
            threadsGen,
            threadsBatch,
            useFlashAttn,
            kvQuantOrdinal,
            useMlock,
            nativeLibraryDir,
        )

    /**
     * Generate text from a pre-formatted prompt.
     *
     * When [onToken] is provided, each token piece is emitted as it is
     * sampled (true streaming). The complete generated text is also returned.
     *
     * The C bridge handles EOG detection via llama_token_is_eog().
     * Custom stop tokens (e.g. <end_of_turn>) are stripped in Kotlin by
     * [LlamaCppEngine.stripStopTokens].
     */
    override fun generate(
        handle: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        repeatPenalty: Float,
        minP: Float,
        onToken: ((String) -> Unit)?,
        grammar: String?,
    ): String {
        val callback = onToken?.let { MaTokenCallback(it) }
        return nativeGenerate(
            handle,
            prompt,
            maxTokens,
            temperature,
            topP,
            topK,
            minP,
            repeatPenalty,
            callback,
            grammar,
        )
    }

    /**
     * Generate via the GGUF's own chat template (common_chat_templates_apply).
     * See [MaInferenceBackend.generateChat] — returns parsed JSON string.
     */
    override fun generateChat(
        handle: Long,
        messagesJson: String,
        toolsJson: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        repeatPenalty: Float,
        minP: Float,
        enableThinking: Boolean,
        onToken: ((String) -> Unit)?,
    ): String {
        val callback = onToken?.let { MaTokenCallback(it) }
        return nativeGenerateChat(
            handle,
            messagesJson,
            toolsJson,
            maxTokens,
            temperature,
            topP,
            topK,
            minP,
            repeatPenalty,
            enableThinking,
            callback,
        )
    }

    /**
     * Release native resources for this context handle.
     * After calling release(), [handle] must not be used.
     */
    external override fun release(handle: Long)

    // --- Private JNI ---

    /**
     * JNI entry point for model initialization.
     * All tuning fields map to llama_context_params / llama_model_params.
     *
     * [nativeLibraryDir] is scanned once per process for `libggml-cpu-*.so`
     * runtime-dispatch variants (see [MaInferenceBackend.init]'s KDoc). Pass ""
     * to fall back to the process's default search paths.
     */
    private external fun nativeInit(
        modelPath: String,
        nCtx: Int,
        nBatch: Int,
        nUbatch: Int,
        threadsGen: Int,
        threadsBatch: Int,
        useFlashAttn: Boolean,
        kvQuantOrdinal: Int,
        useMlock: Boolean,
        nativeLibraryDir: String,
    ): Long

    /**
     * JNI entry point for generation.
     *
     * [callback] is a [MaTokenCallback] instance called once per token piece,
     * or null for non-streaming generation.
     *
     * [grammar] is a GBNF grammar string. When non-null, the native bridge installs
     * a lazy grammar sampler using `<tool_call>` as the trigger pattern.
     */
    private external fun nativeGenerate(
        handle: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        minP: Float,
        repeatPenalty: Float,
        callback: MaTokenCallback?,
        grammar: String?,
    ): String

    /**
     * JNI entry point for native chat-template generation.
     *
     * [messagesJson]: OAI-style messages JSON array.
     * [toolsJson]: OAI-style tools JSON array; "" or "[]" when no tools.
     * Returns parsed output as JSON — see [MaInferenceBackend.generateChat].
     */
    private external fun nativeGenerateChat(
        handle: Long,
        messagesJson: String,
        toolsJson: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        minP: Float,
        repeatPenalty: Float,
        enableThinking: Boolean,
        callback: MaTokenCallback?,
    ): String
}
