package app.m1k3.ai.domain.ai

import app.m1k3.ai.domain.chat.format.ChatFormat

/**
 * LlmModel - Available on-device LLM models
 *
 * Domain entity - Pure Kotlin, no platform dependencies.
 *
 * Represents GGUF models that can be loaded via llama.cpp (Ma).
 * Each model specifies its filename, chat format, and parameters.
 *
 * **Usage:**
 * ```kotlin
 * val model = LlmModel.FalconH1_90M
 * val engine = LlamaCppEngine(context, model)
 * ```
 *
 * @param id Unique identifier
 * @param displayName Human-readable name for UI
 * @param filename GGUF model filename (in assets/models/)
 * @param parameterCount Approximate parameter count
 * @param chatFormat The chat template format for this model
 */
sealed class LlmModel(
    val id: String,
    val displayName: String,
    val filename: String,
    val parameterCount: Long,
    val chatFormat: ChatFormat,
    val minRamGB: Int = 0,
    /** Minimum valid file size in MB — guards against truncated/corrupt downloads */
    val minFileSizeMb: Int = 50,
    /**
     * Upper bound on context window this model can meaningfully exploit on-device,
     * capped by KV-cache memory cost. InferenceTuning applies the device-tier ceiling
     * on top of this, so a Flagship still honours the per-model limit.
     */
    val maxContextTokens: Int = 4096,
) {
    /**
     * Qwen3.5 2B — Lil M1K3 (public, no HF gating)
     *
     * March 2026. Natively multimodal. Qwen3.5-2B ≈ Qwen2.5-7B quality.
     * ChatML format. Q4_K_M ~1.33GB. 4–8GB RAM.
     * HuggingFace: unsloth/Qwen3.5-2B-GGUF
     */
    data object Qwen35_2B : LlmModel(
        id = "qwen3.5-2b",
        displayName = "Qwen3.5 (2B)",
        filename = "Qwen3.5-2B-Q4_K_M.gguf",
        parameterCount = 2_000_000_000L,
        chatFormat = ChatFormat.ChatML,
        minRamGB = 2,
        minFileSizeMb = 1100,
    )

    /**
     * Qwen3 1.7B — kept for reference (superseded by Qwen3.5-2B)
     * @see Qwen35_2B for the active Lil M1K3 model
     */
    data object Qwen3_1B7 : LlmModel(
        id = "qwen3-1.7b",
        displayName = "Qwen3 (1.7B)",
        filename = "Qwen_Qwen3-1.7B-Q4_K_M.gguf",
        parameterCount = 1_700_000_000L,
        chatFormat = ChatFormat.ChatML,
        minRamGB = 2,
    )

    /**
     * Qwen3.5 0.8B — Mini M1K3 (public, no HF gating)
     *
     * March 2026. Natively multimodal (text + image + video weights).
     * Best sub-1B model available. ChatML format. Q4_K_M ~557MB.
     * HuggingFace: unsloth/Qwen3.5-0.8B-GGUF
     */
    data object Qwen35_0B8 : LlmModel(
        id = "qwen3.5-0.8b",
        displayName = "Qwen3.5 (0.8B)",
        filename = "Qwen3.5-0.8B-Q4_K_M.gguf",
        parameterCount = 800_000_000L,
        chatFormat = ChatFormat.ChatML,
        minFileSizeMb = 450,
        // Tiny KV per-token cost lets Mini exploit a longer window when RAM allows.
        maxContextTokens = 8192,
    )

    /**
     * Qwen3 0.6B — kept for reference (superseded by Qwen3.5-0.8B)
     * @see Qwen35_0B8 for the active Mini M1K3 model
     */
    data object Qwen3_0B6 : LlmModel(
        id = "qwen3-0.6b",
        displayName = "Qwen3 (0.6B)",
        filename = "Qwen_Qwen3-0.6B-Q4_K_M.gguf",
        parameterCount = 600_000_000L,
        chatFormat = ChatFormat.ChatML,
    )

    /**
     * Qwen2.5 1.5B — kept for reference (superseded by Qwen3-1.7B)
     * @see Qwen3_1B7 for the active Lil M1K3 model
     */
    data object Qwen25_1B5 : LlmModel(
        id = "qwen2.5-1.5b",
        displayName = "Qwen 2.5 (1.5B)",
        filename = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
        parameterCount = 1_500_000_000L,
        chatFormat = ChatFormat.ChatML,
        minRamGB = 2,
    )

    /**
     * SmolLM2 360M — kept for reference (superseded by Qwen3-0.6B)
     * @see Qwen3_0B6 for the active Mini M1K3 model
     */
    data object SmolLM2_360M : LlmModel(
        id = "smollm2-360m",
        displayName = "SmolLM2 (360M)",
        filename = "SmolLM2-360M-Instruct-Q4_K_M.gguf",
        parameterCount = 360_000_000L,
        chatFormat = ChatFormat.ChatML,
    )

    /**
     * Gemma 3 1B — kept for reference (requires HF auth, not used in tiers)
     * @see Qwen25_1B5 for the active Lil M1K3 model
     */
    data object Gemma3_1B : LlmModel(
        id = "gemma-3-1b",
        displayName = "Gemma 3 (1B)",
        filename = "gemma-3-1b-it-Q4_K_M.gguf",
        parameterCount = 1_000_000_000L,
        chatFormat = ChatFormat.Gemma3,
        minRamGB = 2,
    )

    /**
     * Gemma 3 270M — kept for reference (requires HF auth, not used in tiers)
     * @see SmolLM2_360M for the active Mini M1K3 model
     */
    data object Gemma3_270M : LlmModel(
        id = "gemma-3-270m",
        displayName = "Gemma 3 (270M)",
        filename = "gemma-3-270m-it-UD-IQ3_XXS.gguf",
        parameterCount = 270_000_000L,
        chatFormat = ChatFormat.Gemma3,
    )

    /**
     * Falcon-H1 Tiny 90M - TII's Mamba2/Attention hybrid
     *
     * Ultra-lightweight model with novel hybrid architecture.
     * Uses Q8_0 quantization (~98MB) for best quality testing.
     */
    data object FalconH1_90M : LlmModel(
        id = "falcon-h1-90m",
        displayName = "Falcon-H1 (90M)",
        filename = "Falcon-H1-Tiny-90M-Instruct-Q8_0.gguf",
        parameterCount = 90_000_000L,
        chatFormat = ChatFormat.FalconH1,
    )

    /**
     * Gemma 4 E2B - Google's efficient on-device model
     *
     * 2.3B effective params (5.1B total with Per-Layer Embeddings).
     * Multimodal (text+image+audio), 128K context, function calling.
     * Requires 8GB+ RAM at 4-bit quantization.
     */
    data object Gemma4_E2B : LlmModel(
        id = "gemma-4-e2b",
        displayName = "Gemma 4 (2.3B)",
        filename = "gemma-4-E2B-it-Q4_K_M.gguf",
        parameterCount = 2_300_000_000L,
        chatFormat = ChatFormat.Gemma4,
        minRamGB = 6,
        minFileSizeMb = 2800,
    )

    companion object {
        /**
         * Default model - Gemma 3 1B (downloaded on first launch)
         */
        /** Default — Lil M1K3, Qwen3.5-2B (public, no HF gating) */
        val default: LlmModel get() = Qwen35_2B

        /**
         * Get all active models (excludes gated Gemma variants and superseded models)
         */
        fun all(): List<LlmModel> =
            listOf(
                Qwen35_2B,
                Qwen35_0B8,
                FalconH1_90M,
                Gemma4_E2B,
            )

        /**
         * Find model by ID
         *
         * @return Model if found, null otherwise
         */
        fun findById(id: String): LlmModel? = all().find { it.id == id }

        /**
         * Find model by filename
         *
         * @return Model if found, null otherwise
         */
        fun findByFilename(filename: String): LlmModel? = all().find { it.filename == filename }

        /**
         * Get models available for a given device RAM
         *
         * Filters out models that require more RAM than available.
         *
         * @param deviceRamGB Device RAM in gigabytes
         * @return List of models that can run on this device
         */
        fun availableFor(deviceRamGB: Int): List<LlmModel> = all().filter { it.minRamGB <= deviceRamGB }
    }
}
