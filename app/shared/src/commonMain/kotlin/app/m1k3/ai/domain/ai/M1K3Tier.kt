package app.m1k3.ai.domain.ai

import app.m1k3.ai.domain.platform.DeviceTier

/**
 * M1K3Tier — The three intelligence tiers, matched to hardware.
 *
 * M1K3 is an intelligence machine. Like any precision instrument, its
 * capability scales with the hardware it runs on. These three tiers give
 * every device the best M1K3 it can carry.
 *
 * | Tier | Device | Model |
 * |------|--------|-------|
 * | Mini | <4GB   | Gemma 3 270M — fast and focused |
 * | Lil  | 4–8GB  | Gemma 3 1B — sharp and capable |
 * | Big  | 8GB+   | Gemma 4 E2B — full intelligence |
 */
sealed class M1K3Tier(
    /** "Mini M1K3" / "Lil M1K3" / "Big M1K3" */
    val displayName: String,
    /** One-line descriptor shown during onboarding */
    val tagline: String,
    /** The GGUF model for this tier */
    val model: LlmModel,
    /** Short capability description for onboarding screen */
    val description: String,

    /**
     * When true, this tier is answered by the PLATFORM'S OWN on-device model
     * when the device has (or can fetch) one — Gemini Nano/AICore on
     * Android, matching the Mac/iOS app's Apple-Foundation-Models-first
     * posture for its equivalent tier. [model] remains the weights fallback:
     * used when [app.m1k3.ai.domain.ai.MiniBrainPolicy] resolves to
     * [MiniBrain.Weights] (no system model on this device/OS), and always
     * used for the download-size/tier-identity surfaces above. Only [Mini]
     * sets this — Lil and Big are always our own weights.
     */
    val usesSystemModelWhenAvailable: Boolean = false,
) {
    /**
     * Approximate download size shown in UI — derived from the model's own
     * [LlmModel.minFileSizeMb] (the real integrity floor `HttpModelDownloadManager`
     * checks a finished download against) rather than a second, hand-maintained
     * number. The two used to drift: Big quietly hardcoded 1400MB against an
     * actual ~2800MB file.
     */
    val downloadSizeMb: Int get() = model.minFileSizeMb

    /** <4GB RAM — Qwen3.5 0.8B — March 2026, multimodal, best sub-1B */
    data object Mini : M1K3Tier(
        displayName = "Mini M1K3",
        tagline = "Fast and focused",
        model = LlmModel.Qwen35_0B8,
        description =
            "Optimised for your device — lightweight intelligence " +
                "that stays responsive and never misses a beat.",
        usesSystemModelWhenAvailable = true,
    )

    /** 4–8GB RAM — Qwen3.5 2B — March 2026, multimodal, ≈ Qwen2.5-7B quality */
    data object Lil : M1K3Tier(
        displayName = "Lil M1K3",
        tagline = "Sharp and capable",
        model = LlmModel.Qwen35_2B,
        description =
            "A capable, well-rounded brain. Multi-turn conversations, " +
                "memory, and reasoning that keeps up with you.",
    )

    /** 8GB+ RAM — Gemma 4 E2B — extended thinking, 128K context */
    data object Big : M1K3Tier(
        displayName = "Big M1K3",
        tagline = "Full intelligence",
        model = LlmModel.Gemma4_E2B,

        description =
            "Maximum capability. Extended thinking, 128K context, " +
                "and multimodal reasoning — all running on your hardware.",
    )

    companion object {
        /**
         * Select the best tier for a given device.
         *
         * Always recommends the highest tier the device can support.
         * Users can downgrade on the onboarding screen if preferred.
         */
        fun forDevice(deviceTier: DeviceTier): M1K3Tier =
            when (deviceTier) {
                DeviceTier.FLAGSHIP,
                DeviceTier.HIGH_END,
                -> Big

                DeviceTier.MID_RANGE,
                DeviceTier.BUDGET,
                -> Lil

                DeviceTier.LOW_END -> Mini
            }

        fun all(): List<M1K3Tier> = listOf(Mini, Lil, Big)
    }
}
