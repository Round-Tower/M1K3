package app.m1k3.ai.domain.voice

import app.m1k3.ai.domain.voice.VoiceLoopCommand as Cmd
import app.m1k3.ai.domain.voice.VoiceLoopEvent as Ev
import app.m1k3.ai.domain.voice.VoiceLoopState as St
import kotlin.test.Test
import kotlin.test.assertEquals

/** Port of the Mac's VoiceLoopMachineTests — the loop is a pure transition table. */
class VoiceLoopMachineTest {
    @Test
    fun `begin starts listening`() {
        val m = VoiceLoopMachine()
        assertEquals(listOf(Cmd.StartListening(afterEchoGrace = false)), m.handle(Ev.Begin))
        assertEquals(St.Listening(""), m.state)
    }

    @Test
    fun `partials update the caption only while listening`() {
        val m = VoiceLoopMachine()
        assertEquals(emptyList(), m.handle(Ev.Partial("hi")))
        m.handle(Ev.Begin)
        m.handle(Ev.Partial("what time"))
        assertEquals(St.Listening("what time"), m.state)
    }

    @Test
    fun `endpointed text runs a turn and whole answer speaks then relistens`() {
        val m = VoiceLoopMachine()
        m.handle(Ev.Begin)
        assertEquals(listOf(Cmd.StopListening, Cmd.RunTurn("what time is it")), m.handle(Ev.Endpointed(" what time is it ")))
        assertEquals(St.AwaitingAnswer("what time is it"), m.state)
        assertEquals(listOf(Cmd.Speak("Half nine.")), m.handle(Ev.AnswerReady("Half nine.")))
        assertEquals(St.Speaking("Half nine."), m.state)
        assertEquals(listOf(Cmd.StartListening(afterEchoGrace = true)), m.handle(Ev.SpeechFinished))
        assertEquals(St.Listening(""), m.state)
    }

    @Test
    fun `chunked answers queue and only relisten once drained and completed`() {
        val m = VoiceLoopMachine()
        m.handle(Ev.Begin)
        m.handle(Ev.Endpointed("tell me a story"))
        assertEquals(listOf(Cmd.Speak("Once.")), m.handle(Ev.AnswerChunk("Once.")))
        assertEquals(listOf(Cmd.Speak("Twice.")), m.handle(Ev.AnswerChunk("Twice.")))
        assertEquals(St.Speaking("Once. Twice."), m.state)
        assertEquals(emptyList(), m.handle(Ev.SpeechFinished))
        assertEquals(emptyList(), m.handle(Ev.AnswerCompleted))
        assertEquals(listOf(Cmd.StartListening(afterEchoGrace = true)), m.handle(Ev.SpeechFinished))
    }

    @Test
    fun `empty listens retry then park idle`() {
        val m = VoiceLoopMachine()
        m.handle(Ev.Begin)
        repeat(VoiceLoopMachine.MAX_EMPTY_LISTENS - 1) {
            assertEquals(listOf(Cmd.StopListening, Cmd.StartListening(afterEchoGrace = false)), m.handle(Ev.Endpointed("")))
        }
        assertEquals(listOf(Cmd.StopListening), m.handle(Ev.Endpointed("   ")))
        assertEquals(St.Idle, m.state)
    }

    @Test
    fun `interrupt while speaking barges in`() {
        val m = VoiceLoopMachine()
        m.handle(Ev.Begin); m.handle(Ev.Endpointed("q")); m.handle(Ev.AnswerReady("a long answer"))
        assertEquals(listOf(Cmd.StopSpeaking, Cmd.StartListening(afterEchoGrace = true)), m.handle(Ev.Interrupt))
        assertEquals(emptyList(), m.handle(Ev.Interrupt))
    }

    @Test
    fun `failure before any speech parks idle, after speech drains`() {
        val m = VoiceLoopMachine()
        m.handle(Ev.Begin); m.handle(Ev.Endpointed("q"))
        assertEquals(emptyList(), m.handle(Ev.AnswerFailed("boom")))
        assertEquals(St.Idle, m.state)
    }

    @Test
    fun `mute parks a listen and exit ends everything`() {
        val m = VoiceLoopMachine()
        m.handle(Ev.Begin)
        assertEquals(listOf(Cmd.StopListening), m.handle(Ev.Mute))
        assertEquals(St.Idle, m.state)
        assertEquals(listOf(Cmd.StopSpeaking, Cmd.StopListening), m.handle(Ev.Exit))
        assertEquals(St.Ended, m.state)
        assertEquals(emptyList(), m.handle(Ev.Begin))
    }
}
