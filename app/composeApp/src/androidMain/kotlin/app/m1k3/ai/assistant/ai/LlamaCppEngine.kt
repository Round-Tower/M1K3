package app.m1k3.ai.assistant.ai

import android.content.Context
import app.m1k3.ai.assistant.ai.ma.MaBridge
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.ai.CpuVariantOverride
import app.m1k3.ai.domain.ai.GenerationConfig
import app.m1k3.ai.domain.ai.InferenceTuning
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.MaInferenceBackend
import app.m1k3.ai.domain.ai.NativeDiagnostics
import app.m1k3.ai.domain.ai.ThinkingPolicy
import app.m1k3.ai.domain.chat.format.MessageRole
import app.m1k3.ai.domain.chat.services.ChatFormatter
import app.m1k3.ai.domain.chat.services.DefaultChatFormatter
import app.m1k3.ai.domain.platform.DeviceTier
import app.m1k3.ai.domain.tools.services.ExtractedToolCall
import app.m1k3.ai.domain.tools.services.Gemma4ToolCallExtractor
import app.m1k3.ai.domain.tools.services.QwenXmlToolCallExtractor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File

private val logger = Logger.withTag("LlamaCppEngine")

/** JSON parser for the result returned by MaBridge.generateChat. */
private val nativeChatJson =
    Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

/**
 * LlamaCppEngine - llama.cpp inference engine via Ma JNI bridge
 *
 * Replaces Llamatik with the Ma library, which:
 * - Wraps llama.cpp b8637+ directly (required for Gemma 4)
 * - Provides true token-level streaming (no UTF-8 JNI crash)
 * - Exposes a handle-based API (multiple contexts can coexist)
 *
 * @param context Android context for model path resolution
 * @param model The LLM model to use (default: Gemma 3 1B)
 * @param chatFormatter Prompt formatter derived from model's chat format
 * @param overrideModelPath Absolute path to a model file (skips asset/download resolution)
 * @param backend Inference backend (injectable for testing)
 * @param deviceRamGbOverride Override device RAM detection (-1 = auto-detect)
 */
class LlamaCppEngine(
    private val context: Context,
    private val model: LlmModel = LlmModel.default,
    private val chatFormatter: ChatFormatter = DefaultChatFormatter(model.chatFormat, thinking = ThinkingPolicy.enabled(model)),
    private val overrideModelPath: String? = null,
    private val backend: MaInferenceBackend = MaBridge,
    private val deviceRamGbOverride: Int = -1,
) : BaseLlmEngine,
    NativeChatCapable {
    @Volatile
    private var isInitialized = false
    private val initMutex = Mutex()

    /** Opaque handle to the native llama_context (0 = not initialized). */
    @Volatile
    private var contextHandle: Long = 0L

    private val deviceRamGB: Int by lazy {
        if (deviceRamGbOverride >= 0) return@lazy deviceRamGbOverride
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val memInfo = android.app.ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memInfo)
        (memInfo.totalMem / (1024 * 1024 * 1024)).toInt()
    }

    /**
     * Device-and-model-aware llama.cpp runtime configuration. Resolved once per
     * engine instance from the tier matrix — see InferenceTuning.resolve().
     */
    private val tuning: InferenceTuning by lazy {
        InferenceTuning.resolve(DeviceTier.fromRamGB(deviceRamGB), model)
    }

    private val modelFilename = model.filename
    private val defaultConfig = GenerationConfig()

    /**
     * Resolve the model file path:
     * 1. overrideModelPath (externally-provided)
     * 2. Downloaded model in filesDir/models/
     * 3. Copied from assets/models/ (bundled small models)
     *
     * @throws NoModelAvailableException when no model file can be found or copied
     */
    private fun resolveModelPath(): String {
        overrideModelPath?.let { path ->
            val file = File(path)
            if (file.exists()) return path
            logger.w { "Override path does not exist: $path" }
        }

        val downloadedFile = File(File(context.filesDir, "models"), modelFilename)
        if (downloadedFile.exists() && downloadedFile.length() > 0) {
            logger.d { "Found downloaded model (${downloadedFile.length() / 1024 / 1024} MB)" }
            return downloadedFile.absolutePath
        }

        // Attempt to copy from bundled assets (legacy; removed in no-bundle builds)
        val assetFile = File(context.filesDir, modelFilename)
        return try {
            if (!assetFile.exists()) {
                logger.i { "Copying $modelFilename from assets to internal storage" }
                context.assets.open("models/$modelFilename").use { input ->
                    assetFile.outputStream().use { output -> input.copyTo(output, bufferSize = 8192) }
                }
                logger.i { "Model copied (${assetFile.length() / 1024 / 1024} MB)" }
            }
            assetFile.absolutePath
        } catch (e: Exception) {
            // No assets fallback — model must be downloaded first
            throw NoModelAvailableException(
                model = model,
                cause = e,
            )
        }
    }

    /**
     * Initialize the engine by loading the GGUF model via [MaBridge].
     */
    override suspend fun initialize(): Result<Unit> =
        withContext(Dispatchers.IO) {
            if (isInitialized) return@withContext Result.success(Unit)

            initMutex.withLock {
                if (isInitialized) return@withLock Result.success(Unit)

                try {
                    val tier = DeviceTier.fromRamGB(deviceRamGB)
                    logger.i {
                        "Initializing -> model=${model.displayName}, RAM=${deviceRamGB}GB, " +
                            "tier=$tier, n_ctx=${tuning.nCtx}, n_batch=${tuning.nBatch}, " +
                            "threads=${tuning.threadsGen}/${tuning.threadsBatch}, " +
                            "fa=${tuning.useFlashAttn}, kv=${tuning.kvQuant}"
                    }

                    val modelPath = resolveModelPath()
                    logger.i { "Loading model: $modelPath" }

                    val handle =
                        backend.init(
                            modelPath = modelPath,
                            nCtx = tuning.nCtx,
                            nBatch = tuning.nBatch,
                            nUbatch = tuning.nUbatch,
                            threadsGen = tuning.threadsGen,
                            threadsBatch = tuning.threadsBatch,
                            useFlashAttn = tuning.useFlashAttn,
                            kvQuantOrdinal = tuning.kvQuant.ordinal,
                            useMlock = tuning.useMlock,
                            // Runtime CPU-dispatch backends (libggml-cpu-*.so) live beside
                            // libma.so in the app's extracted native library directory — see
                            // MaInferenceBackend.init's KDoc and ma_core.cpp's header comment.
                            nativeLibraryDir = context.applicationInfo.nativeLibraryDir ?: "",
                            // Empty everywhere except the eval harness — see CpuVariantOverride's KDoc.
                            preferredCpuVariant = CpuVariantOverride.preferred ?: "",
                        )
                    if (handle == 0L) {
                        return@withLock Result.failure(
                            RuntimeException("Failed to load model '${model.displayName}'. File may be corrupt or incompatible."),
                        )
                    }

                    contextHandle = handle
                    isInitialized = true
                    // Records which libggml-cpu-*.so actually registered for this
                    // process — the eval harness's cpu-variant column reads this.
                    NativeDiagnostics.lastLoadedCpuVariant = backend.lastLoadedCpuVariant().ifBlank { null }
                    logger.i { "Initialization complete (handle=$handle)" }

                    Result.success(Unit)
                } catch (e: NoModelAvailableException) {
                    logger.w { "No model available: ${e.message}" }
                    Result.failure(e)
                } catch (e: Exception) {
                    logger.e(e) { "Initialization failed" }
                    isInitialized = false
                    contextHandle = 0L
                    Result.failure(RuntimeException("Failed to initialize LlamaCppEngine", e))
                }
            }
        }

    /**
     * Generate a single response (non-streaming).
     */
    override suspend fun generate(
        prompt: String,
        config: GenerationConfig,
    ): Result<GenerationResult> =
        withContext(Dispatchers.IO) {
            if (!isInitialized) {
                return@withContext Result.failure(
                    IllegalStateException("Engine not initialized. Call initialize() first."),
                )
            }

            val startTime = System.currentTimeMillis()
            val maxTokens = config.maxTokens?.takeIf { it > 0 } ?: getOptimalMaxTokens()

            try {
                val resolvedPrompt = resolvePrompt(prompt, config)

                logger.d { "generate -> ${resolvedPrompt.length}c maxTokens=$maxTokens" }

                val rawResponse =
                    backend.generate(
                        handle = contextHandle,
                        prompt = resolvedPrompt,
                        maxTokens = maxTokens,
                        temperature = config.temperature ?: 0.7f,
                        topP = config.topP ?: 0.95f,
                        topK = config.topK ?: 64,
                        repeatPenalty = config.repetitionPenalty ?: 1.1f,
                        minP = config.minP ?: 0.0f,
                        grammar = config.grammar,
                    )

                val response = stripStopTokens(rawResponse)

                if (response.isEmpty()) {
                    logger.w { "Backend returned empty response" }
                    return@withContext Result.failure(
                        RuntimeException("Model returned empty response. The native context may have been lost."),
                    )
                }

                val inferenceTimeMs = System.currentTimeMillis() - startTime
                val estimatedTokens = (response.length / 4).coerceAtLeast(1)
                val tokensPerSecond =
                    if (inferenceTimeMs > 0) {
                        (estimatedTokens * 1000f) / inferenceTimeMs
                    } else {
                        0f
                    }

                logger.i {
                    "Generation complete (${response.length} chars, ~$estimatedTokens tokens, " +
                        "${inferenceTimeMs}ms, ${"%.1f".format(tokensPerSecond)} tok/s)"
                }

                Result.success(
                    GenerationResult(
                        text = response,
                        tokensGenerated = estimatedTokens,
                        inferenceTimeMs = inferenceTimeMs,
                        tokensPerSecond = tokensPerSecond,
                    ),
                )
            } catch (e: Exception) {
                logger.e(e) { "Generation failed" }
                Result.failure(RuntimeException("Generation failed", e))
            }
        }

    /**
     * Generate response with true token streaming via Ma JNI callbacks.
     *
     * Each token piece is emitted via [onToken] as it is generated — no
     * word-split simulation. The UTF-8 issue from Llamatik is resolved
     * because [MaBridge] calls NewStringUTF only on complete token pieces.
     */
    override suspend fun generateStreaming(
        prompt: String,
        config: GenerationConfig,
        onToken: (String) -> Unit,
    ): Result<Unit> =
        withContext(Dispatchers.IO) {
            if (!isInitialized) {
                return@withContext Result.failure(
                    IllegalStateException("Engine not initialized. Call initialize() first."),
                )
            }

            val maxTokens = config.maxTokens?.takeIf { it > 0 } ?: getOptimalMaxTokens()

            try {
                val resolvedPrompt = resolvePrompt(prompt, config)

                logger.d { "generateStreaming -> ${resolvedPrompt.length}c maxTokens=$maxTokens" }

                var isFirstToken = true
                val rawResponse =
                    backend.generate(
                        handle = contextHandle,
                        prompt = resolvedPrompt,
                        maxTokens = maxTokens,
                        temperature = config.temperature ?: 0.7f,
                        topP = config.topP ?: 0.95f,
                        topK = config.topK ?: 64,
                        repeatPenalty = config.repetitionPenalty ?: 1.1f,
                        minP = config.minP ?: 0.0f,
                        onToken = { token ->
                            val cleaned =
                                app.m1k3.ai.assistant.utils
                                    .cleanStreamingToken(token, isFirstToken)
                            isFirstToken = false
                            if (cleaned.isNotEmpty()) onToken(cleaned)
                        },
                        grammar = config.grammar,
                    )

                val response = stripStopTokens(rawResponse)

                if (response.isEmpty()) {
                    logger.w { "Backend returned empty response during streaming" }
                    return@withContext Result.failure(
                        RuntimeException("Model returned empty response. The native context may have been lost."),
                    )
                }

                logger.i { "Streaming complete (${response.length} chars)" }
                Result.success(Unit)
            } catch (e: Exception) {
                logger.e(e) { "Streaming failed" }
                Result.failure(RuntimeException("Streaming failed", e))
            }
        }

    override fun getOptimalMaxTokens(): Int = tuning.maxTokens

    // ============================================================
    // NativeChatCapable — llama.cpp common_chat_templates_apply path
    // ============================================================

    override suspend fun generateChatNative(
        messagesJson: String,
        toolsJson: String,
        config: GenerationConfig,
        onToken: (String) -> Unit,
        enableThinking: Boolean,
    ): Result<NativeChatOutput> =
        withContext(Dispatchers.IO) {
            if (!isInitialized) {
                return@withContext Result.failure(
                    IllegalStateException("Engine not initialized"),
                )
            }
            val maxTokens = config.maxTokens?.takeIf { it > 0 } ?: getOptimalMaxTokens()

            try {
                var isFirstToken = true
                val resultJson =
                    backend.generateChat(
                        handle = contextHandle,
                        messagesJson = messagesJson,
                        toolsJson = toolsJson,
                        maxTokens = maxTokens,
                        temperature = config.temperature ?: 0.7f,
                        topP = config.topP ?: 0.95f,
                        topK = config.topK ?: 64,
                        repeatPenalty = config.repetitionPenalty ?: 1.1f,
                        minP = config.minP ?: 0.0f,
                        enableThinking = enableThinking,
                        onToken = { token ->
                            val cleaned =
                                app.m1k3.ai.assistant.utils
                                    .cleanStreamingToken(token, isFirstToken)
                            isFirstToken = false
                            if (cleaned.isNotEmpty()) onToken(cleaned)
                        },
                    )

                val parsed = nativeChatJson.parseToJsonElement(resultJson).jsonObject
                parsed["error"]?.let { err ->
                    return@withContext Result.failure(
                        RuntimeException("Native chat path error: $err"),
                    )
                }

                val content = parsed["content"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val reasoning = parsed["reasoning_content"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val raw = parsed["raw"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val parserToolCalls =
                    parsed["tool_calls"]?.jsonArray.orEmpty().map { el ->
                        val obj = el.jsonObject
                        NativeToolCall(
                            name = obj["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                            arguments = obj["arguments"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                            id = obj["id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        )
                    }

                // Fallback: llama.cpp's PEG parser under LENIENT mode sometimes
                // eats the tool_call block as content. Extract directly from raw
                // using the family-specific regex.
                val fallbackCalls: List<ExtractedToolCall> =
                    if (parserToolCalls.isEmpty()) {
                        when {
                            raw.contains("<|tool_call") -> Gemma4ToolCallExtractor.extract(raw)
                            raw.contains("<tool_call>") -> QwenXmlToolCallExtractor.extract(raw)
                            else -> emptyList()
                        }
                    } else {
                        emptyList()
                    }

                val toolCalls =
                    if (fallbackCalls.isNotEmpty()) {
                        logger.i { "Native chat: fallback extractor found ${fallbackCalls.size} tool call(s)" }
                        fallbackCalls.map { ex ->
                            NativeToolCall(
                                name = ex.name,
                                arguments =
                                    nativeChatJson.encodeToString(
                                        kotlinx.serialization.json.JsonObject
                                            .serializer(),
                                        kotlinx.serialization.json.JsonObject(
                                            ex.arguments.mapValues {
                                                kotlinx.serialization.json.JsonPrimitive(it.value)
                                            },
                                        ),
                                    ),
                            )
                        }
                    } else {
                        parserToolCalls
                    }

                // Strip generation-prompt leakage and the raw tool_call block from content.
                // common_chat_parse prepends `params.generation_prompt` (e.g. "<|im_start|>assistant\n<think>\n")
                // to the parsed content; when the fallback fires we also still carry the tool_call block.
                var displayContent = content
                if (parserToolCalls.isEmpty() && toolCalls.isNotEmpty()) {
                    displayContent =
                        displayContent
                            .replace(Regex("<tool_call>.*?</tool_call>", RegexOption.DOT_MATCHES_ALL), "")
                            .replace(Regex("<\\|tool_call\\|?>.*?<\\|?tool_call\\|?>", RegexOption.DOT_MATCHES_ALL), "")
                            .replace(Regex("<\\|channel\\|?>.*?<channel\\|>", RegexOption.DOT_MATCHES_ALL), "")
                }
                displayContent = stripNativeTemplatePrefix(displayContent)

                logger.i { "Native chat: ${displayContent.length}c content, ${toolCalls.size} tool calls" }
                Result.success(
                    NativeChatOutput(
                        content = stripStopTokens(displayContent),
                        reasoningContent = reasoning,
                        toolCalls = toolCalls,
                        raw = raw,
                    ),
                )
            } catch (e: Exception) {
                logger.e(e) { "Native chat generation failed" }
                Result.failure(RuntimeException("Native chat failed", e))
            }
        }

    override fun release() {
        val handle = contextHandle
        if (handle != 0L) {
            try {
                backend.release(handle)
            } catch (e: Exception) {
                logger.e(e) { "Release failed" }
            }
        }
        contextHandle = 0L
        isInitialized = false
        logger.i { "Released" }
    }

    // ==================== Prompt Construction ====================

    /**
     * Resolve the final prompt to send to the backend.
     *
     * If the prompt is already formatted with chat template tokens
     * (e.g., from UnifiedPromptBuilder), pass it through. Otherwise,
     * build a formatted prompt using the model's [ChatFormat].
     */
    private fun resolvePrompt(
        prompt: String,
        config: GenerationConfig,
    ): String =
        if (isAlreadyFormatted(prompt)) {
            prompt
        } else {
            buildFormattedPrompt(config, prompt)
        }

    /**
     * Build a fully-formatted prompt for an unformatted user input.
     *
     * Assembles: BOS prefix + system (if supported) + user turn + model prefix.
     */
    private fun buildFormattedPrompt(
        config: GenerationConfig,
        userMessage: String,
    ): String {
        val format = model.chatFormat
        val systemPrompt = buildCleanSystemPrompt(config)
        val contextBlock = buildContextString(config)

        return buildString {
            append(format.getPromptPrefix())

            if (format.supportsSystemRole && systemPrompt.isNotEmpty()) {
                append(format.formatMessage(MessageRole.SYSTEM, systemPrompt))
                val userContent =
                    if (contextBlock.isNotEmpty()) {
                        "$contextBlock\n\n$userMessage"
                    } else {
                        userMessage
                    }
                append(format.formatMessage(MessageRole.USER, userContent))
            } else {
                // No system role (Gemma3): prepend system + context into user turn
                val userContent =
                    buildString {
                        if (systemPrompt.isNotEmpty()) append("$systemPrompt\n\n")
                        if (contextBlock.isNotEmpty()) append("$contextBlock\n\n")
                        append(userMessage)
                    }
                append(format.formatMessage(MessageRole.USER, userContent))
            }

            // Open the model/assistant turn for generation
            append(assistantPrefix(format))
        }
    }

    private fun buildCleanSystemPrompt(config: GenerationConfig): String {
        val deviceInfo = "${android.os.Build.MODEL} (${deviceRamGB}GB RAM)"
        val userName = config.userContext?.get("name") ?: "Human"
        val identity = "You are M1K3 (Mike), $userName's local AI assistant running on $deviceInfo."
        val temperature = config.temperature
        val behavior =
            when {
                temperature != null && temperature < 0.4f -> {
                    " Be concise, factual, and direct. Avoid speculation. No repetition."
                }

                temperature != null && temperature > 0.8f -> {
                    " Be creative and imaginative. Vary your phrasing."
                }

                else -> {
                    " Be helpful and accurate. Use only provided facts. If unsure, say so." +
                        " Avoid repetition. Each sentence must provide new information."
                }
            }
        return config.systemPrompt ?: (identity + behavior)
    }

    private fun buildContextString(config: GenerationConfig): String {
        val parts = mutableListOf<String>()
        config.knowledgeContext?.let { parts.add(it) }
        return parts.joinToString("\n\n")
    }

    private fun isAlreadyFormatted(prompt: String): Boolean =
        prompt.contains("<start_of_turn>") ||
            prompt.contains("<end_of_turn>") ||
            prompt.contains("<|im_start|>") ||
            prompt.contains("[INST]") ||
            prompt.contains("<|start_header_id|>") ||
            prompt.startsWith("<bos>") ||
            prompt.startsWith("<|begin_of_text|>")

    private fun stripStopTokens(response: String?): String {
        val nonNull = response ?: return ""
        val stopTokens = chatFormatter.getStopTokens()
        var cleaned: String = nonNull
        for (stopToken in stopTokens) {
            val idx = cleaned.indexOf(stopToken)
            if (idx >= 0) cleaned = cleaned.substring(0, idx)
        }
        return cleaned.trim()
    }

    /**
     * Strip chat-template scaffolding that `common_chat_parse` prepends when
     * its PEG anchor slips. Only removes template role markers — never
     * content-shape tags like `<think>`. Stripping the opening `<think>`
     * alone would orphan the `</think>` closer and leak all reasoning into
     * the visible content; `LlmOutputSanitizer` handles `<think>…</think>`
     * as a matched pair once this function returns.
     */
    private fun stripNativeTemplatePrefix(content: String): String =
        content
            .replace(Regex("^\\s*<\\|im_start\\|>assistant\\s*"), "")
            .replace(Regex("^\\s*<start_of_turn>model\\s*"), "")
            .replace(Regex("^\\s*<\\|start_header_id\\|>assistant<\\|end_header_id\\|>\\s*"), "")
            .replace(Regex("^\\s*<\\|turn\\|?>model\\s*"), "") // Gemma 4 turn marker

    companion object {
        /** Format-specific prefix that opens the model's generation turn. */
        fun assistantPrefix(format: app.m1k3.ai.domain.chat.format.ChatFormat): String =
            when (format) {
                is app.m1k3.ai.domain.chat.format.ChatFormat.Gemma3 -> "<start_of_turn>model\n"
                is app.m1k3.ai.domain.chat.format.ChatFormat.Gemma4 -> "<start_of_turn>model\n"
                is app.m1k3.ai.domain.chat.format.ChatFormat.FalconH1 -> "<|start_header_id|>assistant<|end_header_id|>\n"
                is app.m1k3.ai.domain.chat.format.ChatFormat.ChatML -> "<|im_start|>assistant\n"
                is app.m1k3.ai.domain.chat.format.ChatFormat.Llama -> ""
                is app.m1k3.ai.domain.chat.format.ChatFormat.Simple -> ""
                else -> ""
            }
    }
}
