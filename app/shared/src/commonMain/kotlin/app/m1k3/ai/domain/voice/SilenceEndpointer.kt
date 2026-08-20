package app.m1k3.ai.domain.voice

enum class EndpointReason { COMPLETE_THOUGHT, MID_THOUGHT_HOLD, POLITE_WORD, MAX_WAIT }

/** Why the listen ended, with the idle gap and the threshold that applied — for the log. */
data class EndpointDecision(val reason: EndpointReason, val idleMs: Long, val requiredMs: Long)

/**
 * Owns the turn boundary instead of the recogniser. A non-empty partial that stops
 * CHANGING for long enough is the user being done; the driver polls [decision] and
 * ends the listen itself. Completeness-aware (hold longer mid-thought), polite-word
 * fast path, maxWait anti-hang, and CADENCE-ADAPTIVE: every intra-utterance pause
 * the speaker demonstrably recovered from raises a floor under later waits, clamped
 * at the ceiling. The learned pause deliberately survives [reset] — it belongs to
 * the speaker, not the utterance; the session boundary is this object's lifetime.
 *
 * Instants are caller-supplied milliseconds (any monotonic clock) so this stays pure.
 * Port of the Mac's `SilenceEndpointer.swift` (2026-08-15 revision).
 */
class SilenceEndpointer(private val cadence: EndpointCadence = EndpointCadence.CONVERSATIONAL) {
    private var lastText = ""
    private var lastChange: Long? = null
    private var firstSpeech: Long? = null
    private var learnedPause = 0L

    /** The longest pause this speaker has been observed to speak THROUGH. */
    val observedPauseMs: Long get() = learnedPause

    /** Feed every partial. Identical re-emissions do NOT reset the clock. */
    fun ingest(partial: String, at: Long) {
        if (partial == lastText) return
        learnCadence(resumingAt = at)
        lastText = partial
        lastChange = at
        if (firstSpeech == null && partial.isNotBlank()) firstSpeech = at
    }

    private fun learnCadence(resumingAt: Long) {
        val previous = lastChange ?: return
        if (lastText.isBlank()) return // don't learn mic warm-up as thinking
        val gap = resumingAt - previous
        if (gap < cadence.silenceMs) return // ordinary word-by-word growth
        learnedPause = maxOf(learnedPause, minOf(gap, cadence.cadenceCeilingMs))
    }

    fun shouldEndpoint(at: Long): Boolean = decision(at) != null

    fun decision(at: Long): EndpointDecision? {
        val changed = lastChange ?: return null
        if (lastText.isBlank()) return null
        val idle = at - changed
        val first = firstSpeech
        if (first != null && at - first >= cadence.maxWaitMs && idle >= cadence.silenceMs) {
            return EndpointDecision(EndpointReason.MAX_WAIT, idle, cadence.silenceMs)
        }
        if (PoliteEndpoint.isSubmit(lastText) && idle >= cadence.politeMs) {
            return EndpointDecision(EndpointReason.POLITE_WORD, idle, cadence.politeMs)
        }
        val complete = UtteranceCompleteness.looksComplete(lastText)
        val base = if (complete) cadence.silenceMs else cadence.holdMs
        val needed = maxOf(base, minOf(learnedPause + cadence.cadenceMarginMs, cadence.cadenceCeilingMs))
        if (idle < needed) return null
        return EndpointDecision(
            if (complete) EndpointReason.COMPLETE_THOUGHT else EndpointReason.MID_THOUGHT_HOLD,
            idle,
            needed,
        )
    }

    /** Clear for the next listen; KEEPS the learned cadence. */
    fun reset() {
        lastText = ""
        lastChange = null
        firstSpeech = null
    }
}
