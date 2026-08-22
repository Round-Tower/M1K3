package app.m1k3.ai.assistant.ai.ma

import app.m1k3.ai.domain.ai.MaInferenceBackend

/**
 * FakeMaInferenceBackend - Test double for [MaInferenceBackend].
 *
 * Provides controllable behavior for unit testing [LlamaCppEngine]
 * without requiring native llama.cpp code or a real model file.
 */
class FakeMaInferenceBackend : MaInferenceBackend {
    // === init() controls ===
    var initHandle: Long = 1L
    var initCalled = false
    var initCallCount = 0
    var lastInitPath: String? = null
    var lastInitNCtx: Int = 0
    var lastInitNBatch: Int = 0
    var lastInitNUbatch: Int = 0
    var lastInitThreadsGen: Int = 0
    var lastInitThreadsBatch: Int = 0
    var lastInitUseFlashAttn: Boolean = false
    var lastInitKvQuantOrdinal: Int = 0
    var lastInitUseMlock: Boolean = false
    var lastInitNativeLibDir: String? = null
    var lastInitPreferredCpuVariant: String? = null

    /** Value [lastLoadedCpuVariant] returns — tests set this to simulate what the native side reported. */
    var fakeLastLoadedCpuVariant: String = ""

    // === generate() controls ===
    var generateResponse: String = "Test response from fake backend"
    var generateCalled = false
    var generateCallCount = 0
    var lastGenerateHandle: Long = 0L
    var lastGeneratePrompt: String? = null
    var lastGenerateMaxTokens: Int = 0
    var lastGenerateTemperature: Float = 0f
    var lastGenerateMinP: Float = 0f
    var lastGenerateGrammar: String? = null

    /** Tokens emitted one-by-one when onToken callback is provided (streaming). */
    var streamingTokens: List<String> = emptyList()

    // === release() controls ===
    var releaseCalled = false
    var releaseCallCount = 0
    var lastReleaseHandle: Long = 0L

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
        preferredCpuVariant: String,
    ): Long {
        initCalled = true
        initCallCount++
        lastInitPath = modelPath
        lastInitNCtx = nCtx
        lastInitNBatch = nBatch
        lastInitNUbatch = nUbatch
        lastInitThreadsGen = threadsGen
        lastInitThreadsBatch = threadsBatch
        lastInitUseFlashAttn = useFlashAttn
        lastInitKvQuantOrdinal = kvQuantOrdinal
        lastInitUseMlock = useMlock
        lastInitNativeLibDir = nativeLibraryDir
        lastInitPreferredCpuVariant = preferredCpuVariant
        return initHandle
    }

    override fun lastLoadedCpuVariant(): String = fakeLastLoadedCpuVariant

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
        generateCalled = true
        generateCallCount++
        lastGenerateHandle = handle
        lastGeneratePrompt = prompt
        lastGenerateMaxTokens = maxTokens
        lastGenerateTemperature = temperature
        lastGenerateMinP = minP
        lastGenerateGrammar = grammar

        if (onToken != null) {
            streamingTokens.forEach { onToken(it) }
        }

        return generateResponse
    }

    // === generateChat() controls ===

    /** JSON string returned from generateChat. Tests can override. */
    var generateChatResponse: String = """{"content":"test","tool_calls":[],"reasoning_content":""}"""
    var generateChatCalled = false
    var generateChatCallCount = 0
    var lastGenerateChatMessagesJson: String? = null
    var lastGenerateChatToolsJson: String? = null

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
        generateChatCalled = true
        generateChatCallCount++
        lastGenerateChatMessagesJson = messagesJson
        lastGenerateChatToolsJson = toolsJson
        if (onToken != null) streamingTokens.forEach { onToken(it) }
        return generateChatResponse
    }

    override fun release(handle: Long) {
        releaseCalled = true
        releaseCallCount++
        lastReleaseHandle = handle
    }

    /** Reset all recorded state between tests. */
    fun reset() {
        initCalled = false
        initCallCount = 0
        lastInitPath = null
        lastInitNCtx = 0
        lastInitNBatch = 0
        lastInitNUbatch = 0
        lastInitThreadsGen = 0
        lastInitThreadsBatch = 0
        lastInitUseFlashAttn = false
        lastInitKvQuantOrdinal = 0
        lastInitUseMlock = false
        lastInitNativeLibDir = null
        lastInitPreferredCpuVariant = null
        fakeLastLoadedCpuVariant = ""
        generateCalled = false
        generateCallCount = 0
        lastGenerateHandle = 0L
        lastGeneratePrompt = null
        lastGenerateMaxTokens = 0
        lastGenerateTemperature = 0f
        lastGenerateMinP = 0f
        lastGenerateGrammar = null
        generateChatCalled = false
        generateChatCallCount = 0
        lastGenerateChatMessagesJson = null
        lastGenerateChatToolsJson = null
        releaseCalled = false
        releaseCallCount = 0
        lastReleaseHandle = 0L
    }
}
