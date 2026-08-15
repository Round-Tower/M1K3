import Foundation
import M1K3Voice
import Testing

/// Pins the accumulator's commit-and-continue fold, the piece that makes
/// mid-listen recognizer restarts safe. When voice-first keeps listening
/// through Apple Speech's `isFinal` (FinalityPolicy.keepsListening), the
/// restarted recognition session's partials are cumulative FROM EMPTY — under
/// the old "latest non-empty wins" fold they would silently REPLACE everything
/// already finalized. Finalized text is now committed; later partials only ever
/// extend it.
struct TranscriptContinuationTests {
    @Test("partials after a final append to the committed text, never replace it")
    func partialsAfterFinalAppend() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "I went to Cork", isFinal: true))
        acc.ingest(TranscriptSegment(text: "and", isFinal: false))
        acc.ingest(TranscriptSegment(text: "and then home", isFinal: false))
        #expect(acc.text == "I went to Cork and then home")
    }

    @Test("cumulative partials after a final replace only the live tail")
    func tailStaysCumulative() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "what is", isFinal: false))
        acc.ingest(TranscriptSegment(text: "what is in the doc", isFinal: true))
        acc.ingest(TranscriptSegment(text: "about the", isFinal: false))
        acc.ingest(TranscriptSegment(text: "about the plan", isFinal: false))
        #expect(acc.text == "what is in the doc about the plan")
    }

    @Test("a second final commits the tail too")
    func secondFinalCommits() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "first thought", isFinal: true))
        acc.ingest(TranscriptSegment(text: "second", isFinal: false))
        acc.ingest(TranscriptSegment(text: "second thought", isFinal: true))
        acc.ingest(TranscriptSegment(text: "third", isFinal: false))
        #expect(acc.text == "first thought second thought third")
    }

    @Test("empty partials after a final keep the committed text")
    func emptyPartialKeepsCommitted() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "keep this", isFinal: true))
        acc.ingest(TranscriptSegment(text: "", isFinal: false))
        #expect(acc.text == "keep this")
    }

    @Test("confidence still tracks the latest non-empty segment across a restart")
    func confidenceTracksAcrossRestart() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "solid start", isFinal: true, confidence: 0.9))
        #expect(acc.confidence == 0.9)
        // The restarted session's partials carry no confidence (Apple reports a
        // meaningless 0 on non-finals, which the transcriber now yields as nil).
        acc.ingest(TranscriptSegment(text: "and more", isFinal: false, confidence: nil))
        #expect(acc.confidence == nil)
    }

    @Test("isFinal stays latched once any final has been seen")
    func finalLatches() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "done", isFinal: true))
        acc.ingest(TranscriptSegment(text: "more", isFinal: false))
        #expect(acc.isFinal)
    }
}
