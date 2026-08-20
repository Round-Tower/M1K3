package app.m1k3.ai.domain.voice

/**
 * The one tuning preset for "when has the user finished talking" — ported from the
 * Mac's `M1K3Voice/EndpointCadence.swift` so every M1K3 surface shares a single
 * copy. Two hand-typed copies of a tuning knob means the next fix lands on one
 * surface and the other keeps clipping you (that bug shipped twice on macOS/iOS).
 *
 * These are a FLOOR, not the whole story: [SilenceEndpointer] learns the speaker's
 * own pause rhythm on top, so the constants only have to be right for the first
 * pause of a session.
 *
 * Signed: Kev + claude-fable-5, 2026-08-20, Confidence 0.85 (values are the Mac's
 * measured-and-lived preset as of 2026-08-11; the Android recogniser's partial
 * cadence is verify-by-ear). Prior: Unknown.
 */
data class EndpointCadence(
    /** Gap that ends a listen on a complete-sounding thought. */
    val silenceMs: Long = 2_500,
    /** Longer gap when the partial trails off mid-thought. Must be ≥ [silenceMs]. */
    val holdMs: Long = 5_000,
    /** Anti-hang cap from first speech. */
    val maxWaitMs: Long = 30_000,
    /** Headroom added over the speaker's observed worst pause. */
    val cadenceMarginMs: Long = 750,
    /** Clamp on the learned floor — one long silence can't stall the loop. */
    val cadenceCeilingMs: Long = 6_000,
    /** Grace after a trailing "please" so a recogniser hop can still continue it. */
    val politeMs: Long = 1_200,
) {
    init {
        require(holdMs >= silenceMs) {
            "holdMs ($holdMs) must be ≥ silenceMs ($silenceMs) — a shorter hold would endpoint " +
                "incomplete partials FASTER than complete ones, inverting the intent."
        }
    }

    companion object {
        val CONVERSATIONAL = EndpointCadence()
    }
}
