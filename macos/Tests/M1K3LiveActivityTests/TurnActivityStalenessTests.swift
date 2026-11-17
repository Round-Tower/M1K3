import Foundation
import M1K3LiveActivity
import Testing

/// A card iOS can no longer update (the app was killed mid-turn, before Paused or Ready was written) used to say
/// "thinking…" forever. A working card carries a stale date, and a stale one stops pretending.
struct TurnActivityStalenessTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("a working card goes stale a fixed while after it was last written", arguments: [
        TurnActivityPhase.thinking, .reading, .answering,
    ])
    func workingPhasesGoStale(phase: TurnActivityPhase) throws {
        let stale = try #require(TurnActivityStaleness.staleDate(for: TurnActivityState(phase: phase), now: now))
        #expect(stale == now.addingTimeInterval(TurnActivityStaleness.after))
    }

    @Test("a settled card (Ready, Paused) never goes stale: it says the last true thing", arguments: [
        TurnActivityPhase.ready, .paused,
    ])
    func settledPhasesStay(phase: TurnActivityPhase) {
        #expect(TurnActivityStaleness.staleDate(for: TurnActivityState(phase: phase), now: now) == nil)
    }

    @Test("the window outlasts a background grace (about 30 s), so a live turn is never shown stale")
    func windowOutlastsTheGrace() {
        #expect(TurnActivityStaleness.after >= 90)
    }

    @Test("a stale working card shuts its eyes; a fresh one, and a settled one, keep their own face")
    func staleFace() {
        #expect(TurnActivityStaleness.facePhase(.answering, isStale: true) == .paused)
        #expect(TurnActivityStaleness.facePhase(.thinking, isStale: true) == .paused)
        #expect(TurnActivityStaleness.facePhase(.answering, isStale: false) == .answering)
        #expect(TurnActivityStaleness.facePhase(.ready, isStale: true) == .ready)
    }
}
