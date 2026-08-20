package app.m1k3.ai.assistant.voice

import android.app.Application
import android.speech.tts.TextToSpeech
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowTextToSpeech

/**
 * Android's system TextToSpeech as [Speaker] — voice mode's DEFAULT, so it
 * works even when Kokoro's ONNX synth doesn't (see [KokoroOrPlatformSpeaker]).
 *
 * Speaks through Robolectric's [ShadowTextToSpeech] directly — the shadow
 * queues its own completion callback on the main Looper's Handler, but this
 * driver only cares that whatever [android.speech.tts.UtteranceProgressListener]
 * gets registered eventually resumes [speak]; firing it directly keeps the
 * test deterministic without idling the Looper.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class TextToSpeechSpeakerTest {
    private fun shadow(): ShadowTextToSpeech = shadowOf(ShadowTextToSpeech.getLastTextToSpeechInstance())

    @Test
    fun `speak hands text to the platform engine`() =
        runTest {
            val speaker = TextToSpeechSpeaker(ApplicationProvider.getApplicationContext<Application>())

            val job = launch { speaker.speak("half nine") }
            runCurrent()

            assertEquals("half nine", shadow().lastSpokenText)
            assertFalse(job.isCompleted) // still awaiting the utterance's completion

            shadow().utteranceProgressListener?.onDone("m1k3-voice")
            runCurrent()

            assertTrue(job.isCompleted)
        }

    @Test
    fun `speak does not call the engine for blank text`() =
        runTest {
            val speaker = TextToSpeechSpeaker(ApplicationProvider.getApplicationContext<Application>())

            speaker.speak("   ")

            assertNotNull(shadow()) // engine exists...
            assertEquals(null, shadow().lastSpokenText) // ...but was never asked to speak
        }

    @Test
    fun `stop calls through to the platform engine`() =
        runTest {
            val speaker = TextToSpeechSpeaker(ApplicationProvider.getApplicationContext<Application>())
            val job = launch { speaker.speak("keep talking") }
            runCurrent()
            assertFalse(shadow().isStopped)

            speaker.stop()

            assertTrue(shadow().isStopped)

            shadow().utteranceProgressListener?.onDone("m1k3-voice")
            runCurrent()
            assertTrue(job.isCompleted)
        }

    @Test
    fun `an onError completion also resumes the caller instead of hanging forever`() =
        runTest {
            val speaker = TextToSpeechSpeaker(ApplicationProvider.getApplicationContext<Application>())
            val job = launch { speaker.speak("trouble ahead") }
            runCurrent()

            @Suppress("DEPRECATION")
            shadow().utteranceProgressListener?.onError("m1k3-voice")
            runCurrent()

            assertTrue(job.isCompleted)
        }
}
