package app.m1k3.ai.domain.ai

/**
 * SystemBrainAvailability — the platform's own on-device model, as M1K3 sees it.
 *
 * Domain entity — pure Kotlin, no platform dependencies.
 *
 * On Android this maps 1:1 onto ML Kit GenAI's `@FeatureStatus` (Gemini Nano /
 * AICore). Mirrors the Mac's `AFMAvailability` shape (see
 * `macos/Sources/M1K3Inference/AppleFoundationModelsProvider.swift`) but keeps
 * the platform-neutral vocabulary — "system model", not "Foundation Models" or
 * "Gemini Nano" — since a future iOS/desktop target may resolve this
 * differently again.
 */
sealed interface SystemBrainAvailability {
    /** Ready to generate right now. */
    data object Available : SystemBrainAvailability

    /** Not yet on-device, but the platform can fetch it. [sizeHintMb] is best-effort. */
    data class Downloadable(
        val sizeHintMb: Int? = null,
    ) : SystemBrainAvailability

    /** A download is already in flight. [percent] is 0–100, best-effort. */
    data class Downloading(
        val percent: Int? = null,
    ) : SystemBrainAvailability

    /** Cannot be used on this device/OS/build. [reason] is a short, loggable label — never user copy. */
    data class Unavailable(
        val reason: String,
    ) : SystemBrainAvailability
}

/**
 * MiniBrain — what actually answers when the user has selected [M1K3Tier.Mini].
 *
 * Mini is "the phone's own model when it has one, otherwise a small model of
 * ours" — this is the resolved decision between those two.
 */
sealed interface MiniBrain {
    /** The platform's system model (Gemini Nano via ML Kit GenAI on Android). */
    data object SystemModel : MiniBrain

    /** Our own GGUF weights, served via Ma/llama.cpp. */
    data class Weights(
        val model: LlmModel,
    ) : MiniBrain
}

/**
 * MiniBrainPolicy — resolves [MiniBrain] from a [SystemBrainAvailability] reading.
 *
 * Pure decision, no I/O. The probe (platform-specific) is responsible for
 * producing the [SystemBrainAvailability]; this is the one place that decides
 * what M1K3 does with it.
 *
 * Rule: prefer the system model whenever the platform has one or can get one
 * — a device that already ships Gemini Nano shouldn't also pull 557MB of our
 * own Qwen weights for the same tier. Only a genuinely [SystemBrainAvailability.Unavailable]
 * device (or one where the caller has no weights fallback available at all —
 * see [resolve] `qwenDownloaded` semantics below) falls back to our weights.
 */
object MiniBrainPolicy {
    /**
     * @param availability the platform's current system-model status.
     * @param qwenDownloaded unused by the current rule (kept for callers that
     *   want to assert a fallback is actually installed before committing to
     *   it) — reserved for a future "neither is ready yet" tri-state.
     */
    fun resolve(
        availability: SystemBrainAvailability,
        @Suppress("UNUSED_PARAMETER") qwenDownloaded: Boolean = true,
    ): MiniBrain =
        when (availability) {
            is SystemBrainAvailability.Available,
            is SystemBrainAvailability.Downloadable,
            is SystemBrainAvailability.Downloading,
            -> MiniBrain.SystemModel

            is SystemBrainAvailability.Unavailable -> MiniBrain.Weights(LlmModel.Qwen35_0B8)
        }
}
