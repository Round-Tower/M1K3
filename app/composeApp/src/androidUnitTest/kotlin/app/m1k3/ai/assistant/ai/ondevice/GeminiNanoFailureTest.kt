package app.m1k3.ai.assistant.ai.ondevice

import com.google.mlkit.genai.common.GenAiException
import kotlin.test.Test
import kotlin.test.assertEquals

class GeminiNanoFailureTest {
    @Test
    fun `device-ineligible codes classify as unavailable`() {
        assertEquals(GeminiNanoFailure.UNAVAILABLE, GeminiNanoFailure.classify(GenAiException.ErrorCode.NOT_AVAILABLE))
        assertEquals(
            GeminiNanoFailure.UNAVAILABLE,
            GeminiNanoFailure.classify(GenAiException.ErrorCode.AICORE_INCOMPATIBLE),
        )
        assertEquals(
            GeminiNanoFailure.UNAVAILABLE,
            GeminiNanoFailure.classify(GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE),
        )
    }

    @Test
    fun `rate-limit codes classify as busy`() {
        assertEquals(GeminiNanoFailure.BUSY, GeminiNanoFailure.classify(GenAiException.ErrorCode.BUSY))
        assertEquals(
            GeminiNanoFailure.BUSY,
            GeminiNanoFailure.classify(GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED),
        )
    }

    @Test
    fun `size codes classify as input size`() {
        assertEquals(GeminiNanoFailure.INPUT_SIZE, GeminiNanoFailure.classify(GenAiException.ErrorCode.REQUEST_TOO_LARGE))
        assertEquals(GeminiNanoFailure.INPUT_SIZE, GeminiNanoFailure.classify(GenAiException.ErrorCode.REQUEST_TOO_SMALL))
    }

    @Test
    fun `cancelled classifies distinctly`() {
        assertEquals(GeminiNanoFailure.CANCELLED, GeminiNanoFailure.classify(GenAiException.ErrorCode.CANCELLED))
    }

    @Test
    fun `unrecognised code classifies as unknown`() {
        assertEquals(GeminiNanoFailure.UNKNOWN, GeminiNanoFailure.classify(-9999))
    }
}
