package app.m1k3.ai.assistant.ai.ondevice

import android.content.Context
import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.ai.GenerationResult
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.ai.ChatMlPromptSplit
import app.m1k3.ai.domain.ai.GenerationConfig
import app.m1k3.ai.domain.ai.PromptBudget
import app.m1k3.ai.domain.ai.SystemBrainAvailability
import app.m1k3.ai.domain.ai.SystemBrainProbe
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.last
import kotlinx.coroutines.withContext
import kotlinx.datetime.Clock

private val logger = Logger.withTag("GeminiNanoEngine")

/**
 * GeminiNanoEngine — [BaseLlmEngine] backed by ML Kit GenAI's Prompt API
 * (Gemini Nano / AICore). Android's analogue of the Mac's
 * `AppleFoundationModelsProvider`: M1K3's Mini tier answered by the
 * platform's own on-device model when one exists, instead of our
 * [app.m1k3.ai.domain.ai.LlmModel.Qwen35_0B8] GGUF weights.
 *
 * **Not [app.m1k3.ai.assistant.ai.NativeChatCapable].** Gemini Nano has no
 * per-model tool dialect for `common_chat_parse` to target, and no GBNF
 * grammar seam — [app.m1k3.ai.assistant.chat.usecase.ChatWithToolsUseCase]
 * simply falls through to its prompt-engineered path for an engine that
 * doesn't implement the interface, same as any other non-native engine.
 * (Tool SCHEMAS may still appear in the incoming prompt as prose — Gemini
 * Nano just can't act on them; see [ChatMlPromptSplit]'s header.)
 *
 * **The persona-duplication seam (do not reopen).** The Mac's
 * `AppleFoundationModelsProvider` shipped with the persona sent BOTH in the
 * prompt body and in the session's system instructions — ~890 of Mini's 4096
 * tokens, silently doubled, for a week (`facade-capability-forwarding`
 * memory). This engine cannot make that mistake by construction: it never
 * carries its own persona text. The ONE incoming [generate]/[generateStreaming]
 * `prompt` string — already fully rendered by `UnifiedPromptBuilder` for
 * [app.m1k3.ai.domain.ai.LlmModel.Qwen35_0B8]'s ChatML format — is SPLIT by
 * [ChatMlPromptSplit] into (systemInstruction, userContent) and each half
 * goes to exactly one slot of the ML Kit request. Nothing is added on top.
 *
 * SDK ground truth (verified against the `genai-prompt` 1.0.0-beta4 AAR
 * directly via `javap`, 2026-08-22): `generateContentRequest(SystemInstruction,
 * TextPart) { }` is a real overload; `GenerateContentResponse.candidates`
 * carries `.text`; input budget is soft (no exposed constant), so
 * [PromptBudget] applies our own conservative ~3500-token cap to the USER
 * half only — the system instruction (persona) is never truncated.
 *
 * Streaming behaviour is UNVERIFIED on hardware: whether
 * `generateContentStream` yields cumulative snapshots (Gemini-API style) or
 * incremental chunks isn't visible from bytecode alone. [diffAgainstPrevious]
 * handles either shape defensively — see its header.
 */
class GeminiNanoEngine(
    @Suppress("unused") private val context: Context,
    private val probe: SystemBrainProbe = AndroidSystemBrainProbe(context),
    private val clientProvider: () -> GenerativeModel = { Generation.getClient() },
) : BaseLlmEngine {
    private val client: GenerativeModel by lazy { clientProvider() }

    @Volatile
    private var isInitialized = false

    /** Conservative — ML Kit docs describe a soft ~4000-token input ceiling; we stay under it. */
    private val userContentTokenBudget = 3500

    override suspend fun initialize(): Result<Unit> =
        withContext(Dispatchers.IO) {
            if (isInitialized) return@withContext Result.success(Unit)
            try {
                when (val availability = probe.availability()) {
                    is SystemBrainAvailability.Available -> {
                        isInitialized = true
                        Result.success(Unit)
                    }

                    is SystemBrainAvailability.Downloadable, is SystemBrainAvailability.Downloading -> {
                        logger.i { "Gemini Nano not yet on-device ($availability) — downloading" }
                        val terminal =
                            probe
                                .download()
                                .catch { e -> logger.w(e) { "download flow threw: ${e.message}" } }
                                .last()
                        if (terminal is SystemBrainAvailability.Available) {
                            isInitialized = true
                            Result.success(Unit)
                        } else {
                            Result.failure(RuntimeException("Gemini Nano download did not complete: $terminal"))
                        }
                    }

                    is SystemBrainAvailability.Unavailable -> {
                        Result.failure(RuntimeException("Gemini Nano unavailable: ${availability.reason}"))
                    }
                }
            } catch (e: Exception) {
                logger.e(e) { "initialize() failed" }
                Result.failure(e)
            }
        }

    override suspend fun generate(
        prompt: String,
        config: GenerationConfig,
    ): Result<GenerationResult> =
        withContext(Dispatchers.IO) {
            val startMs = Clock.System.now().toEpochMilliseconds()
            try {
                val request = buildRequest(prompt, config)
                val response = client.generateContent(request)
                val text = response.candidates.firstOrNull()?.text ?: ""
                val durationMs = Clock.System.now().toEpochMilliseconds() - startMs
                val tokens = PromptBudget.estimateTokens(text)
                Result.success(
                    GenerationResult(
                        text = text,
                        tokensGenerated = tokens,
                        inferenceTimeMs = durationMs,
                        tokensPerSecond = if (durationMs > 0) tokens * 1000f / durationMs else 0f,
                    ),
                )
            } catch (e: GenAiException) {
                val failure = GeminiNanoFailure.classify(e.errorCode)
                logger.e(e) { "generate() failed: $failure (code=${e.errorCode})" }
                Result.failure(e)
            } catch (e: Exception) {
                logger.e(e) { "generate() failed: unclassified" }
                Result.failure(e)
            }
        }

    override suspend fun generateStreaming(
        prompt: String,
        config: GenerationConfig,
        onToken: (String) -> Unit,
    ): Result<Unit> =
        withContext(Dispatchers.IO) {
            try {
                val request = buildRequest(prompt, config)
                var previous = ""
                client.generateContentStream(request).collect { response ->
                    val text = response.candidates.firstOrNull()?.text ?: return@collect
                    val delta = diffAgainstPrevious(previous, text)
                    previous = if (text.startsWith(previous)) text else previous + text
                    if (delta.isNotEmpty()) onToken(delta)
                }
                Result.success(Unit)
            } catch (e: GenAiException) {
                val failure = GeminiNanoFailure.classify(e.errorCode)
                logger.e(e) { "generateStreaming() failed: $failure (code=${e.errorCode})" }
                Result.failure(e)
            } catch (e: Exception) {
                logger.e(e) { "generateStreaming() failed: unclassified" }
                Result.failure(e)
            }
        }

    /** ~512 tokens — comfortably inside Gemini Nano's own output ceiling and this app's usual reply length. */
    override fun getOptimalMaxTokens(): Int = DEFAULT_MAX_TOKENS

    override fun release() {
        try {
            client.close()
        } catch (e: Exception) {
            logger.w(e) { "close() threw" }
        }
        isInitialized = false
    }

    private fun buildRequest(
        prompt: String,
        config: GenerationConfig,
    ) = run {
        val split = ChatMlPromptSplit.split(prompt)
        val budgetedUser = PromptBudget.trimToBudget(split.userContent, userContentTokenBudget)
        // Positional, not named args: the Kotlin DSL's parameter names aren't
        // visible from the AAR's stripped bytecode (verified via javap), and
        // matching by position is safe regardless of what they're called.
        generateContentRequest(
            SystemInstruction(split.systemInstruction),
            TextPart(budgetedUser),
        ) {
            temperature = config.temperature ?: 1.0f
            maxOutputTokens = config.maxTokens ?: getOptimalMaxTokens()
            candidateCount = 1
        }
    }

    /**
     * Delta between this streamed chunk and the last one seen, tolerant of
     * either streaming shape ML Kit might use:
     *  - **Cumulative snapshots** (`text` grows each call, Gemini-API style):
     *    `text` extends `previous` — return the new suffix.
     *  - **Incremental chunks** (`text` IS the new piece): `text` does not
     *    extend `previous` — return it whole.
     */
    private fun diffAgainstPrevious(
        previous: String,
        text: String,
    ): String = if (text.startsWith(previous) && text.length >= previous.length) text.removePrefix(previous) else text

    private companion object {
        const val DEFAULT_MAX_TOKENS = 512
    }
}

// Signed: Kev + claude-sonnet-5, 2026-08-22, Confidence 0.7, Prior: Unknown
// (no prior signature on this file's ancestor, the retired MlKitGenAiEngine).
// The SDK surface this depends on (Generation/GenerativeModel/GenAiException/
// DownloadStatus shapes, the generateContentRequest(SystemInstruction, TextPart)
// overload) was verified against the genai-prompt/genai-common 1.0.0-beta4
// AARs directly via javap, not inferred from docs or the older beta-era
// prior art. The persona-split-not-duplicated design is deliberate and
// tested (ChatMlPromptSplitTest); what's UNVERIFIED is everything that only
// a real AICore-capable device can prove: whether checkStatus() actually
// resolves Available on such hardware, and whether generateContentStream's
// delta shape matches diffAgainstPrevious's assumption. No Pixel 9a was
// reachable over adb this session (only an emulator, out of scope) — see
// the session report for the device-verify steps still owed.
