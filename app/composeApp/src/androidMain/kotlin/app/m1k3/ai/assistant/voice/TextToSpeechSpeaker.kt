package app.m1k3.ai.assistant.voice

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import app.m1k3.ai.assistant.utils.Logger
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

private val logger = Logger.withTag("TextToSpeechSpeaker")
private const val UTTERANCE_ID = "m1k3-voice"

/**
 * Android's system [TextToSpeech] as [Speaker] — voice mode's DEFAULT, and
 * its floor: no model to load, no ONNX shape errors, works on every device
 * with a TTS engine installed. Kokoro is the richer voice on top of this,
 * never instead of it (see `KokoroOrPlatformSpeaker`).
 *
 * Only ONE utterance is ever in flight per instance (voice mode speaks whole
 * answers serially), so completion doesn't need to match an utterance id —
 * any onDone/onError resumes whichever [speak] call is waiting.
 */
class TextToSpeechSpeaker(
    context: Context,
) : Speaker {
    private var pending: CancellableContinuation<Unit>? = null
    private val engine: TextToSpeech =
        TextToSpeech(context.applicationContext) { status ->
            if (status != TextToSpeech.SUCCESS) {
                logger.w { "platform TTS init failed: status=$status" }
            }
        }.also { tts ->
            tts.setOnUtteranceProgressListener(
                object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}

                    override fun onDone(utteranceId: String?) = resumePending()

                    @Deprecated("legacy API, still called on some devices")
                    override fun onError(utteranceId: String?) = resumePending()

                    override fun onError(
                        utteranceId: String?,
                        errorCode: Int,
                    ) = resumePending()
                },
            )
        }

    override suspend fun speak(text: String) {
        if (text.isBlank()) return
        suspendCancellableCoroutine { cont ->
            pending = cont
            cont.invokeOnCancellation { engine.stop() }
            val result = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE_ID)
            if (result != TextToSpeech.SUCCESS) {
                logger.w { "platform TTS speak() rejected the utterance" }
                resumePending()
            }
        }
    }

    override suspend fun stop() {
        engine.stop()
    }

    /** Frees the engine's own resources — call once, when voice mode is torn down for good. */
    fun release() {
        engine.shutdown()
    }

    private fun resumePending() {
        val cont = pending ?: return
        pending = null
        if (cont.isActive) cont.resume(Unit)
    }
}
