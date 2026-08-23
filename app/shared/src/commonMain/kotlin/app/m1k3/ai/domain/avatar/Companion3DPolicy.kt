package app.m1k3.ai.domain.avatar

/**
 * Decides whether the 3D Phosphor Fox companion may render, or whether the
 * always-safe 2D [PixelFace] must stand in.
 *
 * The 3D path (Filament + a skinned glb) co-initialising with a resident LLM
 * once hit **7.08 GB RSS** on an 8 GB device and Android's LMK killed the
 * foreground app (app/.claude/project-memory.md, 2026-04). So 3D is a
 * headroom-gated *enhancement* that degrades cleanly to 2D on:
 *   - a user opt-out,
 *   - a low-RAM device (`ActivityManager.isLowRamDevice`),
 *   - GL ES < 3 (Filament's floor),
 *   - the brain not yet resident (never spin GL up *during* model load — that
 *     is the exact co-init that OOM'd), or
 *   - too little free memory to risk the allocation.
 *
 * Pure so the decision is unit-tested away from any device.
 */
data class Companion3DInputs(
    val availableMemMb: Long,
    val isLowRamDevice: Boolean,
    val glesMajorVersion: Int,
    val brainResident: Boolean,
    /**
     * True when the resident brain is the heavy tier (Big — Gemma 4 E2B,
     * ~2.8 GB weights / ~6 GB working set). It already claims the memory
     * budget, so stacking a Filament engine on top is the documented OOM
     * path; the fox yields to the 2D face there.
     */
    val residentBrainHeavy: Boolean = false,
    val userEnabled: Boolean = true,
)

enum class Companion3DDecision {
    SHOW_3D,
    FALLBACK_2D,
}

object Companion3DPolicy {
    /**
     * Minimum free memory (MB) to risk bringing Filament up alongside the
     * brain. Set above the ~1.5 GB danger zone seen in the 2026-04 OOM so the
     * GL surface + glb upload has room without tripping the LMK.
     */
    const val MIN_HEADROOM_MB = 2048L

    fun decide(inputs: Companion3DInputs): Companion3DDecision =
        when {
            !inputs.userEnabled -> Companion3DDecision.FALLBACK_2D
            inputs.isLowRamDevice -> Companion3DDecision.FALLBACK_2D
            inputs.glesMajorVersion < 3 -> Companion3DDecision.FALLBACK_2D
            !inputs.brainResident -> Companion3DDecision.FALLBACK_2D
            inputs.residentBrainHeavy -> Companion3DDecision.FALLBACK_2D
            inputs.availableMemMb < MIN_HEADROOM_MB -> Companion3DDecision.FALLBACK_2D
            else -> Companion3DDecision.SHOW_3D
        }
}
