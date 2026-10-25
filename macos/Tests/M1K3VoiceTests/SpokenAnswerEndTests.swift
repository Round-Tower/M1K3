import Foundation
import M1K3Voice
import Testing

/// Where a streamed answer stops being spoken (Kev, 2026-10-25: voice mode read its web
/// sources aloud): the follow-ups trailer or a sources header, whichever comes first.
/// The folder-level streaming case lives in StreamedAnswerFolderTests.
struct SpokenAnswerEndTests {
    @Test("a model-written Sources: list and the Wikipedia block stop speech too, in any case or bold")
    func otherSourceHeadersStop() {
        for header in ["Sources:", "**Sources:**", "Source:", "Wikipedia sources:", "sources: [1] britannica.com"] {
            let text = "Cork is in Munster.\n\n\(header)\n- britannica.com"
            #expect(SpokenAnswerEnd.start(in: text, followUps: { _ in nil }) != nil, "\(header)")
        }
    }

    @Test("prose that mentions sources keeps speaking")
    func proseAboutSourcesSpeaks() {
        for text in [
            "Two sources: the river and the bay.",
            "It has many water sources: rivers, lakes and wells.",
            "Sources: rivers and lakes.",
        ] {
            #expect(SpokenAnswerEnd.start(in: text, followUps: { _ in nil }) == nil, "\(text)")
        }
    }

    @Test("whichever comes first wins: follow-ups before sources, or sources before follow-ups")
    func earliestEndWins() {
        let sourcesFirst = "Answer.\n\nWeb sources:\n• a.com\nFOLLOWUPS: [\"x\"]"
        let end = SpokenAnswerEnd.start(in: sourcesFirst, followUps: { $0.range(of: "FOLLOWUPS:")?.lowerBound })
        #expect(end.map { String(sourcesFirst[..<$0]) }?.trimmingCharacters(in: .whitespacesAndNewlines) == "Answer.")
        let followUpsFirst = "Answer. FOLLOWUPS: [\"x\"]"
        let end2 = SpokenAnswerEnd.start(in: followUpsFirst, followUps: { $0.range(of: "FOLLOWUPS:")?.lowerBound })
        #expect(end2 == followUpsFirst.range(of: "FOLLOWUPS:")?.lowerBound)
    }
}
