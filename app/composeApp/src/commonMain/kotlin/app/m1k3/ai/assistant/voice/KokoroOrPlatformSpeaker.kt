package app.m1k3.ai.assistant.voice

import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.tts.AudioSample
import app.m1k3.ai.domain.tts.TtsEngine
import app.m1k3.ai.domain.tts.TtsResult
import app.m1k3.ai.domain.tts.Voice

private val logger = Logger.withTag("KokoroOrPlatformSpeaker")

/**
 * Kokoro when it works, the platform voice when it doesn't — voice mode (and
 * "speak replies aloud") must work regardless of Kokoro's ONNX health (the
 * "/encoder/bert/Expand invalid shape" failure logged 2026-04). ANY Kokoro
 * failure — a thrown exception, a load failure, or a [TtsResult.Error] —
 * falls straight through to [platform] rather than surfacing silence.
 *
 * Audio playback for a successful Kokoro synthesis is injected ([playAudio],
 * [stopAudio]) rather than a hard dependency on the concrete `AudioPlayer` —
 * keeps this class portable and testable with plain fakes.
 */
class KokoroOrPlatformSpeaker(
    private val kokoro: TtsEngine,
    private val platform: Speaker,
    private val playAudio: (AudioSample) -> Unit,
    private val stopAudio: () -> Unit,
    private val voice: () -> Voice = { Voice.default },
) : Speaker {
    override suspend fun speak(text: String) {
        if (text.isBlank()) return
        val spokenByKokoro =
            runCatching {
                if (!kokoro.isLoaded) kokoro.loadModel().getOrThrow()
                when (val result = kokoro.synthesize(text, voice())) {
                    is TtsResult.Success -> {
                        playAudio(result.audio)
                        true
                    }

                    is TtsResult.Error -> {
                        logger.w {
                            "Kokoro synth failed (${result.code}): ${result.message} — falling back to the platform voice"
                        }
                        false
                    }
                }
            }.getOrElse { e ->
                logger.w(e) { "Kokoro threw — falling back to the platform voice" }
                false
            }
        if (!spokenByKokoro) platform.speak(text)
    }

    override suspend fun stop() {
        stopAudio()
        platform.stop()
    }
}
