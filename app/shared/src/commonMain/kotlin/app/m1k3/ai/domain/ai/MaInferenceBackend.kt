package app.m1k3.ai.domain.ai

/**
 * MaInferenceBackend - Platform-neutral abstraction over the Ma inference library.
 *
 * `Ma` wraps llama.cpp's stable C API behind a portable core (`ma_core`) that both
 * Android (via JNI) and iOS (via Kotlin/Native cinterop) bind to. This interface is
 * the shared domain contract — pure Kotlin, no platform types.
 *
 * Implementations:
 * - `MaBridge` (androidMain): JNI to `libma.so`
 * - `MaNativeBridge` (iosMain, future): cinterop to static `libma_core.a`
 * - `FakeMaInferenceBackend` (test): controllable test double
 *
 * The handle-based API mirrors llama.cpp's context lifecycle:
 * - init() loads model + creates context → returns opaque handle
 * - generate() / generateChat() run inference on that context
 * - release() frees native memory
 *
 * Multiple contexts can coexist (unlike Llamatik's global state).
 *
 * Thread safety: a handle is NOT thread-safe. `LlamaCppEngine` uses a Mutex to
 * guarantee single-threaded access per context.
 */
interface MaInferenceBackend {
    /**
     * Load GGUF model and create inference context.
     *
     * Tuning parameters come from [InferenceTuning.resolve]; callers should not
     * hand-pick these values — let the tier matrix decide per device × model.
     *
     * @param modelPath Absolute path to the .gguf file
     * @param nCtx Context window size — controls KV cache memory usage.
     * @param nBatch Logical batch size for prompt prefill (llama_context_params.n_batch).
     * @param nUbatch Physical micro-batch size; must be <= [nBatch] (n_ubatch).
     * @param threadsGen Thread count for generation (decode). 0 = native hw-derived default.
     * @param threadsBatch Thread count for prefill (prompt encode). 0 = native default.
     * @param useFlashAttn When true the bridge asks for LLAMA_FLASH_ATTN_TYPE_AUTO.
     *   Phase 1 keeps this false everywhere; Phase 2 flips it on for HIGH_END+ paired
     *   with [kvQuantOrdinal] ≠ F16 (upstream couples them: V-cache quant requires FA).
     * @param kvQuantOrdinal Ordinal of [KvCacheType]: 0=F16, 1=Q8_0.
     *   Any non-F16 value requires [useFlashAttn] = true.
     * @param useMlock When true asks llama.cpp to mlock model weights into RAM.
     * @param nativeLibraryDir Absolute path to this app's extracted native library
     *   directory (Android: `context.applicationInfo.nativeLibraryDir`). The native
     *   bridge scans it once per process for `libggml-cpu-*.so` runtime-dispatch
     *   variants and loads the best match for the CPU it's actually running on —
     *   see `ma_core_init`'s header for why a single hard-coded `-march` flag isn't
     *   safe here. Empty string = fall back to the process's default search paths
     *   (executable dir + cwd), which won't find anything useful on Android; pass
     *   the real directory in production. Ignored by implementations that don't
     *   need it (e.g. a future static-linked iOS bridge).
     * @param preferredCpuVariant Bare `.so` filename (e.g.
     *   "libggml-cpu-android_armv9.0_1.so") to try loading FIRST, before the
     *   native side's own most-capable-first order. "" (default) = no
     *   override; production never sets this. See [CpuVariantOverride] — the
     *   Android eval harness (`tools/eval/android`) is the only caller that
     *   passes a non-empty value, to make a specific CPU-variant bug (the
     *   Pixel 9a SVE2 broken-logits case) a reproducible fixture cell rather
     *   than a one-off log read.
     * @return Opaque handle (non-zero) on success, 0 on failure
     */
    fun init(
        modelPath: String,
        nCtx: Int = 2048,
        nBatch: Int = 512,
        nUbatch: Int = 128,
        threadsGen: Int = 0,
        threadsBatch: Int = 0,
        useFlashAttn: Boolean = false,
        kvQuantOrdinal: Int = 0,
        useMlock: Boolean = false,
        nativeLibraryDir: String = "",
        preferredCpuVariant: String = "",
    ): Long

    /**
     * Generate text from a formatted prompt.
     *
     * Handles both streaming and non-streaming generation:
     * - When [onToken] is null: blocks until complete, returns full text
     * - When [onToken] is provided: calls back for each token piece (true streaming),
     *   then returns the accumulated text
     *
     * Stop tokens (e.g. `<end_of_turn>`) are stripped by the engine layer in Kotlin.
     * The C bridge handles EOG detection via llama_token_is_eog().
     *
     * @param handle Context handle from [init]
     * @param prompt Pre-formatted prompt (with chat template tokens applied)
     * @param maxTokens Maximum tokens to generate
     * @param temperature Sampling temperature (0.0–2.0)
     * @param topP Nucleus sampling threshold
     * @param topK Top-K sampling cutoff
     * @param repeatPenalty Repetition penalty (1.0 = none)
     * @param minP Minimum probability floor relative to the most likely token (0.0 = disabled).
     *   min_p is inserted between top_p and temperature in the sampler chain when > 0.
     * @param onToken Called for each generated token piece (nullable = non-streaming)
     * @param grammar Optional GBNF grammar string. When non-null, installs a lazy grammar
     *                sampler triggered by `<tool_call>` so the model physically cannot emit
     *                malformed tool-call JSON. Null = unconstrained sampling (legacy path).
     * @return Complete generated text
     */
    fun generate(
        handle: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        repeatPenalty: Float,
        minP: Float = 0.0f,
        onToken: ((String) -> Unit)? = null,
        grammar: String? = null,
    ): String

    /**
     * Generate via the model's own chat template (common_chat_templates_apply path).
     *
     * The native bridge renders [messagesJson] + [toolsJson] through the Jinja template
     * embedded in the GGUF, builds a per-model grammar (when tools are present), runs
     * the generation, and then parses the output back into structured fields via
     * common_chat_parse. This lets any model with native tool-calling training
     * (Qwen 2/3/3.5, Llama 3.x, Mistral, Phi-4, DeepSeek-R1, etc.) use the format
     * it was trained on, without us prompt-engineering per model.
     *
     * Returns a JSON string of shape:
     * ```
     * {"content": "...", "reasoning_content": "...",
     *  "tool_calls": [{"name": "...", "arguments": "..."}],
     *  "raw": "..."}
     * ```
     * or `{"error": "..."}` on failure — callers should fall back to [generate] in that case.
     *
     * @param messagesJson OpenAI-style messages array JSON
     * @param toolsJson OpenAI-style tools array JSON ("" or "[]" when no tools)
     * @param enableThinking Hint to the template to encourage `<think>` tags when supported
     *
     * MurphySig: kev+claude / confidence 0.85 / 2026-04-18
     */
    fun generateChat(
        handle: Long,
        messagesJson: String,
        toolsJson: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        repeatPenalty: Float,
        minP: Float = 0.0f,
        enableThinking: Boolean = true,
        onToken: ((String) -> Unit)? = null,
    ): String

    /**
     * Release native model and context resources.
     *
     * After calling release(), the handle is invalid and must not be used.
     */
    fun release(handle: Long)

    /**
     * Cooperatively stop an in-flight [generate] / [generateChat] on [handle].
     * Safe to call from another thread; the native generation loop breaks at
     * its next token and returns the text produced so far (not an error). The
     * stop flag auto-resets at the next generation, so a stale request can
     * never cancel a future turn.
     *
     * Default no-op — safe for fakes/doubles that never touch native code.
     */
    fun requestStop(handle: Long) {}

    /**
     * The bare `.so` filename of the CPU backend variant that actually
     * registered on the FIRST [init] call this process (`ma_core.cpp`'s
     * `load_cpu_backends_once` runs once per process — see [preferredCpuVariant]
     * above). "" when unknown (no model has loaded yet, non-Android build, or
     * the backend fell through to the default-search-path scan rather than
     * matching a known variant name).
     *
     * Default implementation returns "" — safe for fakes/doubles that never
     * touch native code.
     */
    fun lastLoadedCpuVariant(): String = ""
}
