package app.m1k3.ai.assistant.voice

import app.m1k3.ai.domain.stt.SttEngine
import app.m1k3.ai.domain.stt.SttState
import app.m1k3.ai.domain.voice.EndpointCadence
import app.m1k3.ai.domain.voice.VoiceLoopState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Android driver for VoiceLoopMachine — M1K3 owns the turn boundary, not
 * Android's SpeechRecognizer. Cadence is deliberately tiny here; with a
 * TestScope's virtual clock the numbers don't cost real time, they just need
 * to be small enough to keep the test's own arithmetic easy to read.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceLoopControllerTest {
    private val fastCadence =
        EndpointCadence(
            silenceMs = 300,
            holdMs = 600,
            maxWaitMs = 5_000,
            cadenceMarginMs = 100,
            cadenceCeilingMs = 1_000,
            politeMs = 200,
        )

    private class FakeSttEngine : SttEngine {
        private val _state = MutableStateFlow<SttState>(SttState.Idle)
        override val state: StateFlow<SttState> = _state.asStateFlow()
        var startCount = 0
        var stopCount = 0

        override fun startListening() {
            startCount++
            _state.value = SttState.Listening()
        }

        override fun stopListening() {
            stopCount++
        }

        override fun cancel() {}

        override fun release() {}

        override fun isAvailable(): Boolean = true

        fun emit(state: SttState) {
            _state.value = state
        }
    }

    private class FakeSpeaker : Speaker {
        val spoken = mutableListOf<String>()
        var stopCount = 0
        var holdUntilReleased = false
        private val gate = Channel<Unit>(Channel.RENDEZVOUS)

        override suspend fun speak(text: String) {
            spoken += text
            if (holdUntilReleased) gate.receive()
        }

        override suspend fun stop() {
            stopCount++
        }
    }

    private fun buildController(
        stt: FakeSttEngine,
        speaker: FakeSpeaker,
        scope: TestScope,
        runTurn: suspend (String) -> Result<String>,
    ) = VoiceLoopController(
        stt = stt,
        speaker = speaker,
        runTurn = runTurn,
        scope = scope,
        cadence = fastCadence,
        clock = { scope.testScheduler.currentTime },
        tickMs = 50,
        echoGraceMs = 0,
    )

    @Test
    fun `begin starts listening and forwards partials`() {
        val scope = TestScope(StandardTestDispatcher())
        val stt = FakeSttEngine()
        val speaker = FakeSpeaker()
        val controller = buildController(stt, speaker, scope) { Result.success("never") }

        controller.begin()
        scope.runCurrent()

        assertEquals(1, stt.startCount)
        assertEquals(VoiceLoopState.Listening(""), controller.state.value)

        stt.emit(SttState.Listening("what time"))
        scope.runCurrent()

        assertEquals(VoiceLoopState.Listening("what time"), controller.state.value)

        controller.exit()
        scope.advanceUntilIdle()
    }

    @Test
    fun `silence endpoint runs the turn and speaks the whole answer, then relistens`() {
        val scope = TestScope(StandardTestDispatcher())
        val stt = FakeSttEngine()
        val speaker = FakeSpeaker()
        var askedQuestion: String? = null
        val controller =
            buildController(stt, speaker, scope) { question ->
                askedQuestion = question
                Result.success("Half nine.")
            }

        controller.begin()
        scope.runCurrent()
        stt.emit(SttState.Listening("what time is it"))
        scope.runCurrent()

        // Idle past the silence threshold — the tick loop owns this, not the recognizer.
        scope.testScheduler.advanceTimeBy(400)
        scope.runCurrent()

        assertEquals("what time is it", askedQuestion)
        assertEquals(listOf("Half nine."), speaker.spoken)
        assertEquals(VoiceLoopState.Listening(""), controller.state.value)
        assertEquals(2, stt.startCount) // once for begin(), once for the post-speech relisten

        controller.exit()
        scope.advanceUntilIdle()
    }

    @Test
    fun `recognizer finality mid-turn keeps listening under the same turn`() {
        val scope = TestScope(StandardTestDispatcher())
        val stt = FakeSttEngine()
        val speaker = FakeSpeaker()
        var askedQuestion: String? = null
        val controller =
            buildController(stt, speaker, scope) { question ->
                askedQuestion = question
                Result.success("ok")
            }

        controller.begin()
        scope.runCurrent()

        // Android's own VAD ends the segment — but the user isn't done.
        stt.emit(SttState.Result("hello there"))
        scope.runCurrent()

        assertEquals(VoiceLoopState.Listening("hello there"), controller.state.value)
        assertEquals(2, stt.startCount) // begin() + the segment restart
        assertEquals(null, askedQuestion) // no turn ran yet — only silence ends it

        controller.exit()
        scope.advanceUntilIdle()
    }

    @Test
    fun `interrupt while speaking barges in`() {
        val scope = TestScope(StandardTestDispatcher())
        val stt = FakeSttEngine()
        val speaker = FakeSpeaker().apply { holdUntilReleased = true }
        val controller =
            buildController(stt, speaker, scope) { Result.success("a long answer") }

        controller.begin()
        scope.runCurrent()
        stt.emit(SttState.Listening("question"))
        scope.runCurrent()
        scope.testScheduler.advanceTimeBy(400)
        scope.runCurrent()

        assertIs<VoiceLoopState.Speaking>(controller.state.value)
        assertEquals(1, speaker.spoken.size)

        controller.interrupt()
        scope.runCurrent()

        assertEquals(1, speaker.stopCount)
        assertTrue(controller.state.value is VoiceLoopState.Listening)

        controller.exit()
        scope.advanceUntilIdle()
    }

    @Test
    fun `empty listens retry then park idle`() {
        val scope = TestScope(StandardTestDispatcher())
        val stt = FakeSttEngine()
        val speaker = FakeSpeaker()
        val controller = buildController(stt, speaker, scope) { Result.success("never") }

        controller.begin()
        scope.runCurrent()

        // A permission/audio error before any speech is a silent-listen-ended
        // signal, same as the recognizer honestly finding nothing to say.
        stt.emit(SttState.Error("Microphone permission required"))
        scope.runCurrent()
        stt.emit(SttState.Error("Microphone permission required"))
        scope.runCurrent()

        assertEquals(VoiceLoopState.Idle, controller.state.value)
        assertEquals("Microphone permission required", controller.lastError.value)

        scope.advanceUntilIdle()
    }
}
