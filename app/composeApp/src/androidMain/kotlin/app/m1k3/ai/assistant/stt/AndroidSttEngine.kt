package app.m1k3.ai.assistant.stt

/**
 * Signed: Kev + claude-sonnet-4-6, 2026-04-06
 * Format: MurphySig v0.1 (https://murphysig.dev/spec)
 *
 * Context: Android SpeechRecognizer implementation of domain SttEngine interface.
 * Chose Android's built-in recognizer over Whisper (too heavy for a background task)
 * and CMU PocketSphinx (unmaintained). On-device on Android 13+, cloud fallback on
 * older versions — consistent with M1K3's privacy-first approach where possible.
 * Domain interface lives in shared/ so iOS gets SFSpeechRecognizer when we get there.
 * RECORD_AUDIO permission added to manifest.
 *
 * Confidence: 0.8 — SpeechRecognizer is well-understood Android API. Partial results
 * wired for real-time text preview in input field. Main uncertainty: ERROR_RECOGNIZER_BUSY
 * on rapid retaps needs UX guard (already handled via isListening check).
 * Open: Should we debounce mic button to prevent accidental double-taps?
 */

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import app.m1k3.ai.domain.stt.SttEngine
import app.m1k3.ai.domain.stt.SttState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Android Speech-to-Text engine using SpeechRecognizer.
 *
 * Uses the built-in Android speech recognition service.
 * On-device when available (Android 13+), cloud fallback otherwise.
 *
 * Must be created on the main thread.
 */
class AndroidSttEngine(
    private val context: Context
) : SttEngine {

    companion object {
        private const val TAG = "AndroidSttEngine"
    }

    private val _state = MutableStateFlow<SttState>(SttState.Idle)
    override val state: StateFlow<SttState> = _state.asStateFlow()

    private var recognizer: SpeechRecognizer? = null

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            Log.d(TAG, "Ready for speech")
            _state.value = SttState.Listening()
        }

        override fun onBeginningOfSpeech() {
            Log.d(TAG, "Speech begun")
        }

        override fun onRmsChanged(rmsdB: Float) {
            // Could drive a volume indicator animation
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {
            Log.d(TAG, "End of speech")
            _state.value = SttState.Processing
        }

        override fun onError(error: Int) {
            val message = when (error) {
                SpeechRecognizer.ERROR_NO_MATCH -> "No speech detected"
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Speech timeout"
                SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
                SpeechRecognizer.ERROR_NETWORK -> "Network error"
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
                SpeechRecognizer.ERROR_CLIENT -> "Client error"
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission required"
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognizer busy"
                SpeechRecognizer.ERROR_SERVER -> "Server error"
                else -> "Recognition error ($error)"
            }
            Log.w(TAG, "STT error: $message ($error)")
            _state.value = SttState.Error(message)
        }

        override fun onResults(results: Bundle?) {
            val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val text = matches?.firstOrNull() ?: ""
            Log.d(TAG, "Result: $text")
            _state.value = if (text.isNotBlank()) {
                SttState.Result(text)
            } else {
                SttState.Error("No speech detected")
            }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val partial = matches?.firstOrNull() ?: ""
            if (partial.isNotBlank()) {
                _state.value = SttState.Listening(partialText = partial)
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    override fun startListening() {
        if (_state.value is SttState.Listening || _state.value is SttState.Processing) {
            Log.w(TAG, "Already listening/processing")
            return
        }

        try {
            recognizer?.destroy()
            recognizer = SpeechRecognizer.createSpeechRecognizer(context).also {
                it.setRecognitionListener(recognitionListener)
            }

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }

            _state.value = SttState.Listening()
            recognizer?.startListening(intent)
            Log.d(TAG, "Started listening")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start listening", e)
            _state.value = SttState.Error("Failed to start: ${e.message}")
        }
    }

    override fun stopListening() {
        try {
            recognizer?.stopListening()
            Log.d(TAG, "Stopped listening")
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping", e)
        }
    }

    override fun cancel() {
        try {
            recognizer?.cancel()
            _state.value = SttState.Idle
            Log.d(TAG, "Cancelled")
        } catch (e: Exception) {
            Log.w(TAG, "Error cancelling", e)
            _state.value = SttState.Idle
        }
    }

    override fun release() {
        try {
            recognizer?.destroy()
            recognizer = null
            _state.value = SttState.Idle
            Log.d(TAG, "Released")
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing", e)
        }
    }

    override fun isAvailable(): Boolean {
        return SpeechRecognizer.isRecognitionAvailable(context)
    }
}
