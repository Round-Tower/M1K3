@testable import M1K3Voice
import Testing

/// #621: the launch warm must not build beside a voice turn. A turn runs from the first heard word to the
/// last spoken one; an open mic that has heard nothing is not a turn.
struct VoiceLoopHoldsTheBrainTests {
    @Test("an open mic that has heard nothing leaves the brain free")
    func quietMicIsFree() {
        #expect(!VoiceLoopState.listening(partial: "").holdsTheBrain)
        #expect(!VoiceLoopState.listening(partial: "  \n").holdsTheBrain)
        #expect(!VoiceLoopState.idle.holdsTheBrain)
        #expect(!VoiceLoopState.ended.holdsTheBrain)
    }

    @Test("from the first heard word to the last spoken one, the turn holds the brain")
    func aTurnHolds() {
        #expect(VoiceLoopState.listening(partial: "what").holdsTheBrain)
        #expect(VoiceLoopState.awaitingAnswer(question: "what time is it").holdsTheBrain)
        #expect(VoiceLoopState.speaking(answer: "Half past nine.").holdsTheBrain)
    }
}
