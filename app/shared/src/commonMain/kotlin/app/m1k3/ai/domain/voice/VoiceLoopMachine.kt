package app.m1k3.ai.domain.voice

sealed interface VoiceLoopState {
    data object Idle : VoiceLoopState
    data class Listening(val partial: String) : VoiceLoopState
    data class AwaitingAnswer(val question: String) : VoiceLoopState
    data class Speaking(val answer: String) : VoiceLoopState
    data object Ended : VoiceLoopState
}

sealed interface VoiceLoopEvent {
    data object Begin : VoiceLoopEvent
    data class Partial(val text: String) : VoiceLoopEvent
    data class Endpointed(val text: String) : VoiceLoopEvent
    /** Whole-answer path ≡ one chunk + completion. */
    data class AnswerReady(val answer: String) : VoiceLoopEvent
    data class AnswerChunk(val chunk: String) : VoiceLoopEvent
    data object AnswerCompleted : VoiceLoopEvent
    data class AnswerFailed(val message: String) : VoiceLoopEvent
    data object SpeechFinished : VoiceLoopEvent
    data object Interrupt : VoiceLoopEvent
    data object Mute : VoiceLoopEvent
    data object Exit : VoiceLoopEvent
}

sealed interface VoiceLoopCommand {
    data class StartListening(val afterEchoGrace: Boolean) : VoiceLoopCommand
    data object StopListening : VoiceLoopCommand
    data class RunTurn(val question: String) : VoiceLoopCommand
    data class Speak(val text: String) : VoiceLoopCommand
    data object StopSpeaking : VoiceLoopCommand
}

/**
 * The voice-first loop as a pure transition table (port of the Mac's
 * `VoiceLoopMachine.swift`): listen → endpoint → run turn → speak (chunked or
 * whole) → re-listen, with barge-in, empty-listen parking and exit. The platform
 * driver (Android `VoiceLoopController`) owns the recogniser, TTS and the brain;
 * it feeds events in and executes the commands out. Nothing here touches a clock
 * or a device, so every branch is unit-testable.
 *
 * Signed: Kev + claude-fable-5, 2026-08-20, Confidence 0.9 (byte-for-byte the
 * Mac's transition semantics, test-pinned). Prior: Unknown.
 */
class VoiceLoopMachine {
    var state: VoiceLoopState = VoiceLoopState.Idle
        private set
    private var consecutiveEmptyListens = 0
    private var unspokenChunks = 0
    private var generationDone = false

    fun handle(event: VoiceLoopEvent): List<VoiceLoopCommand> {
        val s = state
        if (s is VoiceLoopState.Ended) return emptyList()
        return when (event) {
            VoiceLoopEvent.Begin -> {
                if (s !is VoiceLoopState.Idle) return emptyList()
                state = VoiceLoopState.Listening("")
                listOf(VoiceLoopCommand.StartListening(afterEchoGrace = false))
            }
            is VoiceLoopEvent.Partial -> {
                if (s !is VoiceLoopState.Listening) return emptyList()
                state = VoiceLoopState.Listening(event.text)
                emptyList()
            }
            is VoiceLoopEvent.Endpointed -> {
                if (s !is VoiceLoopState.Listening) return emptyList()
                val trimmed = event.text.trim()
                if (trimmed.isEmpty()) return emptyListenEnded()
                consecutiveEmptyListens = 0
                unspokenChunks = 0
                generationDone = false
                state = VoiceLoopState.AwaitingAnswer(trimmed)
                listOf(VoiceLoopCommand.StopListening, VoiceLoopCommand.RunTurn(trimmed))
            }
            is VoiceLoopEvent.AnswerReady -> {
                if (s !is VoiceLoopState.AwaitingAnswer) return emptyList()
                unspokenChunks = 1
                generationDone = true
                state = VoiceLoopState.Speaking(event.answer)
                listOf(VoiceLoopCommand.Speak(event.answer))
            }
            is VoiceLoopEvent.AnswerChunk -> when (s) {
                is VoiceLoopState.AwaitingAnswer -> {
                    unspokenChunks = 1
                    generationDone = false
                    state = VoiceLoopState.Speaking(event.chunk)
                    listOf(VoiceLoopCommand.Speak(event.chunk))
                }
                is VoiceLoopState.Speaking -> {
                    unspokenChunks += 1
                    state = VoiceLoopState.Speaking(if (s.answer.isEmpty()) event.chunk else s.answer + " " + event.chunk)
                    listOf(VoiceLoopCommand.Speak(event.chunk))
                }
                else -> emptyList() // stale: barge-in/exit already moved on
            }
            VoiceLoopEvent.AnswerCompleted, is VoiceLoopEvent.AnswerFailed -> when (s) {
                is VoiceLoopState.AwaitingAnswer -> { state = VoiceLoopState.Idle; emptyList() }
                is VoiceLoopState.Speaking -> { generationDone = true; relistenIfDrained() }
                else -> emptyList()
            }
            VoiceLoopEvent.SpeechFinished -> {
                if (s !is VoiceLoopState.Speaking) return emptyList()
                unspokenChunks = maxOf(0, unspokenChunks - 1)
                relistenIfDrained()
            }
            VoiceLoopEvent.Interrupt -> {
                if (s !is VoiceLoopState.Speaking) return emptyList()
                state = VoiceLoopState.Listening("")
                listOf(VoiceLoopCommand.StopSpeaking, VoiceLoopCommand.StartListening(afterEchoGrace = true))
            }
            VoiceLoopEvent.Mute -> {
                if (s !is VoiceLoopState.Listening) return emptyList()
                state = VoiceLoopState.Idle
                listOf(VoiceLoopCommand.StopListening)
            }
            VoiceLoopEvent.Exit -> {
                state = VoiceLoopState.Ended
                listOf(VoiceLoopCommand.StopSpeaking, VoiceLoopCommand.StopListening)
            }
        }
    }

    /** Speaking → listening only when the last queued utterance ended AND generation stopped. */
    private fun relistenIfDrained(): List<VoiceLoopCommand> {
        if (unspokenChunks != 0 || !generationDone) return emptyList()
        state = VoiceLoopState.Listening("")
        return listOf(VoiceLoopCommand.StartListening(afterEchoGrace = true))
    }

    private fun emptyListenEnded(): List<VoiceLoopCommand> {
        consecutiveEmptyListens += 1
        if (consecutiveEmptyListens >= MAX_EMPTY_LISTENS) {
            state = VoiceLoopState.Idle
            return listOf(VoiceLoopCommand.StopListening)
        }
        state = VoiceLoopState.Listening("")
        return listOf(VoiceLoopCommand.StopListening, VoiceLoopCommand.StartListening(afterEchoGrace = false))
    }

    companion object {
        const val MAX_EMPTY_LISTENS = 2
    }
}
