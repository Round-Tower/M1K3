import M1K3Voice
import Testing

/// Pins when a partial heard WHILE M1K3 speaks is the user cutting in (#640). The
/// mic only hears the room during speech when Mac voice processing is live; even then
/// residual echo can leak M1K3's own words, so a partial that is mostly the answer
/// being spoken is never a barge-in.
struct BargeInPolicyTests {
    private let answer = "The hydraulic seal on the conveyor failed under load last Tuesday afternoon."

    @Test("two words of the user's own while echo cancellation is live is a barge-in")
    func twoOwnWordsBargeIn() {
        #expect(BargeInPolicy.isBargeIn(partial: "hang on", speaking: answer, echoCancellationLive: true))
        #expect(BargeInPolicy.isBargeIn(partial: "no wait what about Friday", speaking: answer, echoCancellationLive: true))
    }

    @Test("without live echo cancellation nothing is a barge-in: the mic may be hearing M1K3 itself")
    func needsLiveEchoCancellation() {
        #expect(!BargeInPolicy.isBargeIn(partial: "hang on a second", speaking: answer, echoCancellationLive: false))
        #expect(!BargeInPolicy.isBargeIn(partial: "stop", speaking: answer, echoCancellationLive: false))
    }

    @Test("one stray word is noise, unless it is a stop word")
    func oneWordNeedsToBeAStopWord() {
        #expect(!BargeInPolicy.isBargeIn(partial: "um", speaking: answer, echoCancellationLive: true))
        #expect(!BargeInPolicy.isBargeIn(partial: "Friday", speaking: answer, echoCancellationLive: true))
        #expect(BargeInPolicy.isBargeIn(partial: "Stop.", speaking: answer, echoCancellationLive: true))
        #expect(BargeInPolicy.isBargeIn(partial: "wait", speaking: answer, echoCancellationLive: true))
    }

    @Test("a partial that is mostly the answer's own words is echo leaking through, not the user")
    func echoOfTheAnswerIsNotABargeIn() {
        #expect(!BargeInPolicy.isBargeIn(
            partial: "the conveyor failed under load", speaking: answer, echoCancellationLive: true
        ))
        #expect(!BargeInPolicy.isBargeIn(partial: "seal on the", speaking: answer, echoCancellationLive: true))
        // A stop word inside the echo doesn't make it the user's.
        #expect(!BargeInPolicy.isBargeIn(
            partial: "wait the hydraulic seal",
            speaking: "Wait, the hydraulic seal failed.",
            echoCancellationLive: true
        ))
    }

    @Test("the user's own words still count after a little echo leaked into the same partial")
    func ownWordsAfterLeakedEcho() {
        #expect(BargeInPolicy.isBargeIn(
            partial: "the conveyor failed under load hang on wait", speaking: answer, echoCancellationLive: true
        ))
        #expect(BargeInPolicy.isBargeIn(
            partial: "the conveyor failed under load what about Friday", speaking: answer, echoCancellationLive: true
        ))
        // One own word that isn't a stop word, buried in echo, is still noise.
        #expect(!BargeInPolicy.isBargeIn(
            partial: "the conveyor failed under load um", speaking: answer, echoCancellationLive: true
        ))
    }

    @Test("a lone stop word counts even when the answer says it too")
    func loneStopWordInTheAnswer() {
        #expect(BargeInPolicy.isBargeIn(
            partial: "stop", speaking: "Don't stop the pump before it cools.", echoCancellationLive: true
        ))
    }

    @Test("an answer with figures: its echo spelled out in words is not the user")
    func spelledOutNumbersAreEcho() {
        let figures = "Revenue grew 3.5% in 2026, to 120 thousand."
        #expect(!BargeInPolicy.isBargeIn(
            partial: "twenty twenty six to one hundred and twenty thousand", speaking: figures, echoCancellationLive: true
        ))
        #expect(BargeInPolicy.isBargeIn(
            partial: "twenty twenty six hang on what about costs", speaking: figures, echoCancellationLive: true
        ))
    }

    // MARK: - The question the user asked, without M1K3's echo

    @Test("a leading run of three or more answer words is echo, dropped whatever its case or punctuation")
    func leadingEchoIsDropped() {
        #expect(BargeInPolicy.userUtterance("the conveyor failed hang on wait", speaking: answer) == "hang on wait")
        #expect(BargeInPolicy.userUtterance("The conveyor failed. Hang on, wait.", speaking: answer) == "Hang on, wait.")
    }

    @Test("the user's first words survive even when the answer has them: short runs are never stripped")
    func shortSharedStartSurvives() {
        #expect(BargeInPolicy.userUtterance("no wait", speaking: "No, the seal held.") == "no wait")
        #expect(BargeInPolicy.userUtterance("is it safe", speaking: "It is safe to run.") == "is it safe")
    }

    @Test("a trailing run of answer words after the user is echo too")
    func trailingEchoIsDropped() {
        #expect(BargeInPolicy.userUtterance("hang on wait the hydraulic seal on", speaking: answer) == "hang on wait")
    }

    @Test("all echo leaves nothing; no echo leaves the text untouched")
    func allOrNothing() {
        #expect(BargeInPolicy.userUtterance("seal on the conveyor failed", speaking: answer) == "")
        #expect(BargeInPolicy.userUtterance("what about Friday", speaking: answer) == "what about Friday")
    }

    @Test("blank and punctuation-only partials are nothing")
    func blankIsNothing() {
        #expect(!BargeInPolicy.isBargeIn(partial: "", speaking: answer, echoCancellationLive: true))
        #expect(!BargeInPolicy.isBargeIn(partial: " … ", speaking: answer, echoCancellationLive: true))
    }
}
