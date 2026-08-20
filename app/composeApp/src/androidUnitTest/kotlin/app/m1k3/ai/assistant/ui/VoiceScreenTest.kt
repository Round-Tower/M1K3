package app.m1k3.ai.assistant.ui

import app.m1k3.ai.domain.voice.VoiceLoopState
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The pure state → text mapping VoiceScreen renders. Copy is VERBATIM from
 * the iOS shell (macos/M1K3iOSApp/VoiceScreen.swift) so both surfaces feel
 * like the same product. Full Compose rendering needs ComposeTestRule in an
 * instrumented test — this pins the logic that can run in a unit test.
 */
class VoiceScreenTest {
    @Test
    fun `idle prompts a tap`() {
        assertEquals("Tap the mic to talk", voiceCaptionText(VoiceLoopState.Idle))
    }

    @Test
    fun `listening with no partial yet shows a placeholder`() {
        assertEquals("Listening…", voiceCaptionText(VoiceLoopState.Listening("")))
    }

    @Test
    fun `listening with a partial shows the live transcript`() {
        assertEquals("what time is it", voiceCaptionText(VoiceLoopState.Listening("what time is it")))
    }

    @Test
    fun `awaiting answer reads thinking`() {
        assertEquals("Thinking…", voiceCaptionText(VoiceLoopState.AwaitingAnswer("what time is it")))
    }

    @Test
    fun `speaking shows the answer`() {
        assertEquals("Half nine.", voiceCaptionText(VoiceLoopState.Speaking("Half nine.")))
    }

    @Test
    fun `ended has no caption`() {
        assertEquals("", voiceCaptionText(VoiceLoopState.Ended))
    }

    @Test
    fun `accessibility labels name each state plainly`() {
        assertEquals("Voice mode, microphone parked", voiceAccessibilityLabel(VoiceLoopState.Idle))
        assertEquals("Listening", voiceAccessibilityLabel(VoiceLoopState.Listening("hi")))
        assertEquals("Thinking", voiceAccessibilityLabel(VoiceLoopState.AwaitingAnswer("hi")))
        assertEquals("Speaking", voiceAccessibilityLabel(VoiceLoopState.Speaking("hi")))
        assertEquals("Voice mode ended", voiceAccessibilityLabel(VoiceLoopState.Ended))
    }

    @Test
    fun `the polite hint only shows while listening`() {
        assertEquals(true, showsPoliteHint(VoiceLoopState.Listening("")))
        assertEquals(false, showsPoliteHint(VoiceLoopState.Idle))
        assertEquals(false, showsPoliteHint(VoiceLoopState.AwaitingAnswer("q")))
        assertEquals(false, showsPoliteHint(VoiceLoopState.Speaking("a")))
        assertEquals(false, showsPoliteHint(VoiceLoopState.Ended))
    }
}
