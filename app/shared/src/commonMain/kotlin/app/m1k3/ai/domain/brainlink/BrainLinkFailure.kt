package app.m1k3.ai.domain.brainlink

/**
 * A 429 from the Mac, read into the etiquette it speaks (spec §5): its own turn
 * is running (busy), it is resting a warm machine (cooling), or its brain is
 * still loading (warming), with how long to wait. The Kotlin twin of
 * BrainRefusal in `macos/Sources/M1K3BrainLink/BrainLinkPolicies.swift`.
 *
 * [userMessage] keeps the Mac's copy word for word, so both clients say the
 * same thing; it moves to the presentation layer with the UI that shows it.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9 (reads checked
 * against the Mac's BrainRefusal and BrainConnection on the same bodies).
 * Prior: none (new file). Lineage: BrainLinkPolicies.swift and
 * BrainConnection.swift (Kev + claude-fable-5, 2026-08-24).
 * Review: Kev + claude-opus-5.5, 2026-10-27 — the code-quality fold: classify
 * no longer reads a 2xx as success. The Mac decides on the Content-Type alone
 * and maps any reply that isn't the event stream, a 200 included, to a
 * failure; the twin now does the same and always answers. Confidence 0.85.
 */
data class BrainRefusal(
    val reason: Reason,
    val retryAfterSeconds: Int,
) {
    enum class Reason(
        /** The error string the Mac writes in the 429 body. */
        val wire: String,
    ) {
        BUSY("busy"),
        COOLING("cooling"),
        WARMING("warming"),
    }

    val userMessage: String
        get() =
            when (reason) {
                Reason.BUSY -> "Your Mac is in the middle of its own turn — try again in a moment."
                Reason.COOLING -> "Your Mac is running warm and resting its brain — try again shortly."
                Reason.WARMING -> "Your Mac's brain is still warming up — try again in a moment."
            }

    companion object {
        /** The wait when neither the body nor the header names one. */
        const val DEFAULT_RETRY_AFTER_SECONDS = 15

        /**
         * Null unless [status] is 429. An unknown reason reads as busy, the
         * safest retry posture. The wait is the body's retry_after_s, else the
         * Retry-After header's whole seconds (the raw header value, as the
         * transport received it), else [DEFAULT_RETRY_AFTER_SECONDS].
         */
        fun parse(
            status: Int,
            body: String?,
            retryAfterHeader: String?,
        ): BrainRefusal? {
            if (status != 429) return null
            val json = parseJsonObject(body)
            val wireReason = json?.stringOrNull("error")
            val reason = Reason.entries.firstOrNull { it.wire == wireReason } ?: Reason.BUSY
            val seconds =
                json?.wholeIntOrNull("retry_after_s")
                    ?: retryAfterHeader?.trimSwiftWhitespaces()?.toSwiftIntOrNull()
                    ?: DEFAULT_RETRY_AFTER_SECONDS
            return BrainRefusal(reason, seconds)
        }
    }
}

/**
 * What a reply from the Mac that isn't the event stream means, for the
 * transport to raise and the UI to show honestly (spec §2: a 429 while the
 * brain warms, a 503 rather than a persona-seeded stand-in). Transport
 * failures (unreachable, timed out, a stream cut short) belong to the
 * transport and aren't modelled here. The twin of BrainConnection's status
 * mapping on the Mac.
 */
sealed class BrainLinkFailure {
    /** 429: the Mac asked the phone to wait. */
    data class Refused(
        val refusal: BrainRefusal,
    ) : BrainLinkFailure()

    /** 503: the Mac's active brain can't serve raw generation. */
    data class Unavailable(
        val message: String,
    ) : BrainLinkFailure()

    /** Anything else: the status and the body's error, or "unexpected reply". */
    data class BadResponse(
        val status: Int,
        val message: String,
    ) : BrainLinkFailure()

    companion object {
        /**
         * Call it for a reply whose Content-Type isn't text/event-stream, and
         * only then: the Mac's BrainConnection judges the Content-Type, not the
         * status, so a 2xx that isn't the stream is a BadResponse there and
         * here (a 200 with {"error":"busy"} reads as BadResponse(200, "busy")).
         */
        fun classify(
            status: Int,
            body: String?,
            retryAfterHeader: String?,
        ): BrainLinkFailure {
            BrainRefusal.parse(status, body, retryAfterHeader)?.let { return Refused(it) }
            val message = parseJsonObject(body)?.stringOrNull("error") ?: "unexpected reply"
            return if (status == 503) Unavailable(message) else BadResponse(status, message)
        }
    }
}
