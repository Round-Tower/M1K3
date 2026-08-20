package app.m1k3.ai.assistant.voice

import app.m1k3.ai.domain.tts.AudioSample
import app.m1k3.ai.domain.tts.TtsEngine
import app.m1k3.ai.domain.tts.TtsErrorCode
import app.m1k3.ai.domain.tts.TtsResult
import app.m1k3.ai.domain.tts.Voice
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Kokoro when it works, Android's platform TTS when it doesn't — voice mode
 * must work regardless of Kokoro's ONNX health (the "/encoder/bert/Expand
 * invalid shape" failure logged 2026-04). ANY Kokoro failure — a thrown
 * exception, a load failure, or a [TtsResult.Error] — falls through to the
 * platform [Speaker] rather than surfacing silence.
 */
class KokoroOrPlatformSpeakerTest {
    private class FakeTtsEngine(
        override var isLoaded: Boolean = true,
        private val loadResult: Result<Unit> = Result.success(Unit),
        private val synthesizeResult: (String) -> TtsResult = {
            TtsResult.Success(AudioSample(samples = floatArrayOf(0f, 0f)))
        },
        private val throwOnSynthesize: Throwable? = null,
    ) : TtsEngine {
        override val sampleRate: Int = 24000
        var loadCalled = 0
        var synthesizeCalled = 0

        override suspend fun loadModel(): Result<Unit> {
            loadCalled++
            if (loadResult.isSuccess) isLoaded = true
            return loadResult
        }

        override suspend fun synthesize(
            text: String,
            voice: Voice,
            speed: Float,
        ): TtsResult {
            synthesizeCalled++
            throwOnSynthesize?.let { throw it }
            return synthesizeResult(text)
        }

        override suspend fun synthesizeStreaming(
            text: String,
            voice: Voice,
            speed: Float,
            onChunk: (AudioSample) -> Unit,
        ): Result<Unit> = Result.success(Unit)

        override fun release() {}
    }

    private class FakeSpeaker : Speaker {
        val spoken = mutableListOf<String>()
        var stopCount = 0

        override suspend fun speak(text: String) {
            spoken += text
        }

        override suspend fun stop() {
            stopCount++
        }
    }

    @Test
    fun `plays kokoro audio and never touches the platform voice when synthesis succeeds`() =
        runTest {
            val kokoro = FakeTtsEngine()
            val platform = FakeSpeaker()
            val played = mutableListOf<AudioSample>()
            val speaker =
                KokoroOrPlatformSpeaker(
                    kokoro = kokoro,
                    platform = platform,
                    playAudio = { played += it },
                    stopAudio = {},
                )

            speaker.speak("Half nine.")

            assertEquals(1, played.size)
            assertTrue(platform.spoken.isEmpty())
        }

    @Test
    fun `loads kokoro first when it is not yet loaded`() =
        runTest {
            val kokoro = FakeTtsEngine(isLoaded = false)
            val speaker =
                KokoroOrPlatformSpeaker(
                    kokoro = kokoro,
                    platform = FakeSpeaker(),
                    playAudio = {},
                    stopAudio = {},
                )

            speaker.speak("hello")

            assertEquals(1, kokoro.loadCalled)
            assertEquals(1, kokoro.synthesizeCalled)
        }

    @Test
    fun `falls back to the platform voice when kokoro returns an error result`() =
        runTest {
            val kokoro =
                FakeTtsEngine(
                    synthesizeResult = { TtsResult.Error(TtsErrorCode.SYNTHESIS_FAILED, "bad shape") },
                )
            val platform = FakeSpeaker()
            val played = mutableListOf<AudioSample>()
            val speaker =
                KokoroOrPlatformSpeaker(
                    kokoro = kokoro,
                    platform = platform,
                    playAudio = { played += it },
                    stopAudio = {},
                )

            speaker.speak("hello there")

            assertTrue(played.isEmpty())
            assertEquals(listOf("hello there"), platform.spoken)
        }

    @Test
    fun `falls back to the platform voice when kokoro throws`() =
        runTest {
            val kokoro = FakeTtsEngine(throwOnSynthesize = RuntimeException("onnx blew up"))
            val platform = FakeSpeaker()
            val speaker =
                KokoroOrPlatformSpeaker(
                    kokoro = kokoro,
                    platform = platform,
                    playAudio = {},
                    stopAudio = {},
                )

            speaker.speak("hello there")

            assertEquals(listOf("hello there"), platform.spoken)
        }

    @Test
    fun `falls back to the platform voice when loading kokoro fails`() =
        runTest {
            val kokoro = FakeTtsEngine(isLoaded = false, loadResult = Result.failure(RuntimeException("no model file")))
            val platform = FakeSpeaker()
            val speaker =
                KokoroOrPlatformSpeaker(
                    kokoro = kokoro,
                    platform = platform,
                    playAudio = {},
                    stopAudio = {},
                )

            speaker.speak("hello there")

            assertEquals(0, kokoro.synthesizeCalled) // never got as far as synthesis
            assertEquals(listOf("hello there"), platform.spoken)
        }

    @Test
    fun `blank text speaks nothing on either voice`() =
        runTest {
            val kokoro = FakeTtsEngine()
            val platform = FakeSpeaker()
            val speaker =
                KokoroOrPlatformSpeaker(kokoro = kokoro, platform = platform, playAudio = {}, stopAudio = {})

            speaker.speak("   ")

            assertEquals(0, kokoro.synthesizeCalled)
            assertTrue(platform.spoken.isEmpty())
        }

    @Test
    fun `stop tears down both the kokoro audio path and the platform voice`() =
        runTest {
            val platform = FakeSpeaker()
            var stopAudioCalled = 0
            val speaker =
                KokoroOrPlatformSpeaker(
                    kokoro = FakeTtsEngine(),
                    platform = platform,
                    playAudio = {},
                    stopAudio = { stopAudioCalled++ },
                )

            speaker.stop()

            assertEquals(1, stopAudioCalled)
            assertEquals(1, platform.stopCount)
        }
}
