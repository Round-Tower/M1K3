package app.m1k3.ai.assistant.voice

import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.stt.SttEngine
import app.m1k3.ai.domain.stt.SttState
import app.m1k3.ai.domain.voice.EndpointCadence
import app.m1k3.ai.domain.voice.SilenceEndpointer
import app.m1k3.ai.domain.voice.VoiceLoopCommand
import app.m1k3.ai.domain.voice.SpeechTextPolish
import app.m1k3.ai.domain.voice.VoiceLoopEvent
import app.m1k3.ai.domain.voice.VoiceLoopMachine
import app.m1k3.ai.domain.voice.VoiceLoopState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.time.Clock

private val logger = Logger.withTag("VoiceLoopController")

/** A user-facing turn failure — the message is shown, not logged-and-lost. */
class VoiceTurnFailure(
    message: String,
) : Exception(message)

/**
 * Voice mode's spoken-audio sink. Injected so the loop stays testable with
 * fakes and the platform layer adapts its own TTS seam (Kokoro, Android
 * `TextToSpeech`, ...) without this module depending on either. [speak]
 * suspends until the utterance is done — that's the loop's only signal that
 * sound reached the user.
 */
interface Speaker {
    suspend fun speak(text: String)

    suspend fun stop()
}

/**
 * The Android driver for the shared [VoiceLoopMachine] — port of the Mac's
 * `VoiceLoopController.swift`, adapted to Kotlin coroutines and Android's
 * one-shot [SttEngine] instead of Swift's continuous `AsyncStream`. The
 * machine stays a pure transition table (shared/domain/voice); everything
 * here is task lifetime + the seams.
 *
 * M1K3 owns the turn boundary, not the recogniser: Android's SpeechRecognizer
 * ends a "segment" on its own VAD (a [SttState.Result] or a benign
 * [SttState.Error]) far sooner than a real pause. A segment that carried text
 * does NOT end the turn — listening restarts immediately under the SAME turn
 * (commit-and-continue) and the accumulated transcript keeps flowing into
 * [SilenceEndpointer], the one thing allowed to actually end it.
 */
class VoiceLoopController(
    private val stt: SttEngine,
    private val speaker: Speaker,
    private val runTurn: suspend (String) -> Result<String>,
    private val scope: CoroutineScope,
    cadence: EndpointCadence = EndpointCadence.CONVERSATIONAL,
    private val clock: () -> Long = { Clock.System.now().toEpochMilliseconds() },
    private val tickMs: Long = 100L,
    private val echoGraceMs: Long = 350L,
) {
    private val machine = VoiceLoopMachine()
    private val endpointer = SilenceEndpointer(cadence)

    private val _state = MutableStateFlow<VoiceLoopState>(VoiceLoopState.Idle)
    val state: StateFlow<VoiceLoopState> = _state.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private var accumulated = ""
    private var sttJob: Job? = null
    private var tickJob: Job? = null
    private var turnJob: Job? = null
    private var speakJob: Job? = null
    private var turnGeneration = 0

    // ===== User intents =====

    fun begin() {
        _lastError.value = null
        dispatch(VoiceLoopEvent.Begin)
    }

    fun interrupt() = dispatch(VoiceLoopEvent.Interrupt)

    fun mute() = dispatch(VoiceLoopEvent.Mute)

    fun exit() = dispatch(VoiceLoopEvent.Exit)

    // ===== Reducer plumbing =====

    private fun dispatch(event: VoiceLoopEvent) {
        val commands = machine.handle(event)
        _state.value = machine.state
        commands.forEach(::execute)
    }

    private fun execute(command: VoiceLoopCommand) {
        when (command) {
            is VoiceLoopCommand.StartListening -> startListen(command.afterEchoGrace)
            VoiceLoopCommand.StopListening -> stopListen()
            is VoiceLoopCommand.RunTurn -> runTurnCommand(command.question)
            is VoiceLoopCommand.Speak -> speak(command.text)
            VoiceLoopCommand.StopSpeaking -> stopSpeaking()
        }
    }

    // ===== Listening internals =====

    private fun startListen(afterEchoGrace: Boolean) {
        accumulated = ""
        endpointer.reset()
        sttJob?.cancel()
        tickJob?.cancel()
        sttJob =
            scope.launch {
                if (afterEchoGrace && echoGraceMs > 0) delay(echoGraceMs)
                if (!isActive) return@launch
                stt.startListening()
                startEndpointTick()
                stt.state.collect { s -> onSttState(s) }
            }
    }

    private fun onSttState(s: SttState) {
        when (s) {
            is SttState.Listening -> {
                ingest(s.partialText, restartSegment = false)
            }

            is SttState.Result -> {
                // A non-empty Result is Android's own segment boundary, not the
                // user's — commit what it heard and keep the same turn going.
                if (s.text.isNotBlank()) ingest(s.text, restartSegment = true)
            }

            is SttState.Error -> {
                _lastError.value = s.message
                logger.w { "voice mic error: ${s.message}" }
                if (accumulated.isNotBlank()) {
                    // Mid-turn: the error is the recogniser's segment boundary.
                    stt.startListening()
                } else {
                    // Nothing heard yet — this is a silent listen ending, same
                    // as the recogniser reporting no speech.
                    tickJob?.cancel()
                    dispatch(VoiceLoopEvent.Endpointed(""))
                }
            }

            else -> {}
        }
    }

    private fun ingest(
        text: String,
        restartSegment: Boolean,
    ) {
        accumulated = if (accumulated.isBlank()) text.trim() else "$accumulated $text".trim()
        dispatch(VoiceLoopEvent.Partial(accumulated))
        endpointer.ingest(accumulated, clock())
        if (restartSegment) stt.startListening()
    }

    private fun stopListen() {
        sttJob?.cancel()
        sttJob = null
        tickJob?.cancel()
        tickJob = null
        stt.stopListening()
    }

    private fun startEndpointTick() {
        tickJob =
            scope.launch {
                while (isActive) {
                    delay(tickMs)
                    val decision = endpointer.decision(clock()) ?: continue
                    logger.i {
                        "voice endpoint: ${decision.reason} idle=${decision.idleMs}ms required=${decision.requiredMs}ms"
                    }
                    dispatch(VoiceLoopEvent.Endpointed(accumulated))
                    return@launch
                }
            }
    }

    // ===== Turn + speak internals =====

    private fun runTurnCommand(question: String) {
        turnGeneration += 1
        val generation = turnGeneration
        turnJob =
            scope.launch {
                val result = runTurn(question)
                if (generation != turnGeneration) return@launch // superseded by barge-in + a new question
                result
                    .onSuccess { answer -> dispatch(VoiceLoopEvent.AnswerReady(answer)) }
                    .onFailure { e ->
                        val message = e.message ?: "The turn failed."
                        _lastError.value = message
                        logger.e(e) { "voice turn failed" }
                        dispatch(VoiceLoopEvent.AnswerFailed(message))
                    }
            }
    }

    private fun speak(text: String) {
        speakJob =
            scope.launch {
                // Markdown, code fences and <think> blocks are for the eye, not the
                // ear (the Mac hit this as #93 — "voice would have spoken raw markdown").
                speaker.speak(SpeechTextPolish.polish(text).ifBlank { text })
                dispatch(VoiceLoopEvent.SpeechFinished)
            }
    }

    private fun stopSpeaking() {
        speakJob?.cancel()
        speakJob = null
        scope.launch { speaker.stop() }
    }
}
