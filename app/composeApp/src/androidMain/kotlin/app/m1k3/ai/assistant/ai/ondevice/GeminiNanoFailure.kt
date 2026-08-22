package app.m1k3.ai.assistant.ai.ondevice

import com.google.mlkit.genai.common.GenAiException

/**
 * GeminiNanoFailure — [GenAiException.getErrorCode] classified into the
 * buckets [GeminiNanoEngine] actually needs to act on differently. Mirrors
 * the Mac's `AFMFailure` shape (overflow vs guardrail vs daemon vs unknown):
 * a classified count across a session is actionable ("Nano refused N times
 * for being busy") in a way forty raw error messages are not.
 *
 * Pure `Int -> GeminiNanoFailure`, decoupled from the exception type itself,
 * so it's unit-testable on the JVM without a device or Robolectric — the
 * `@GenAiException.ErrorCode` constants are plain compile-time `Int`s baked
 * into the AAR's class files.
 */
enum class GeminiNanoFailure {
    /** The model isn't usable right now (ineligible device, needs a system update, out of disk, etc). */
    UNAVAILABLE,

    /** Transient — retry later. Battery/background/rate limits and general busy signals. */
    BUSY,

    /** The request was too large (or, less commonly, too small) for the model's input window. */
    INPUT_SIZE,

    /** The caller cancelled — not a failure to log loudly. */
    CANCELLED,

    /** An error shape this classifier doesn't recognise yet. */
    UNKNOWN,
    ;

    companion object {
        fun classify(errorCode: Int): GeminiNanoFailure =
            when (errorCode) {
                GenAiException.ErrorCode.NOT_AVAILABLE,
                GenAiException.ErrorCode.NOT_SUPPORTED,
                GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
                GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
                GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE,
                -> UNAVAILABLE

                GenAiException.ErrorCode.BUSY,
                GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED,
                GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED,
                -> BUSY

                GenAiException.ErrorCode.REQUEST_TOO_LARGE,
                GenAiException.ErrorCode.REQUEST_TOO_SMALL,
                -> INPUT_SIZE

                GenAiException.ErrorCode.CANCELLED -> CANCELLED

                else -> UNKNOWN
            }
    }
}
