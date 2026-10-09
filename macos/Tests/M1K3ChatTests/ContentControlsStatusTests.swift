//
//  ContentControlsStatusTests.swift
//  M1K3ChatTests
//
//  What the Content Controls row says about the stored band (Mac + iOS Settings).
//  2026-10-09: an adult who shared their age range read "No age range declared",
//  beside a "Clear" and an "Update" that said the opposite.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-09, Confidence 0.9. Prior: none (new file).
//

@testable import M1K3Chat
import Testing

struct ContentControlsStatusTests {
    @Test("nothing shared: says so, offers Set up, nothing to clear")
    func undeclared() {
        let status = AgeBand.undeclared.contentControlsStatus
        #expect(status.title == "No age range declared")
        #expect(status.actionTitle == "Set up")
        #expect(!status.canClear)
        #expect(status.systemImage == "person.crop.circle")
    }

    @Test("an adult who shared is not told nothing was declared")
    func adult() {
        let status = AgeBand.adult.contentControlsStatus
        #expect(status.title == "Adult: no adjustments")
        #expect(status.actionTitle == "Update")
        #expect(status.canClear)
        #expect(status.systemImage == "person.crop.circle.badge.checkmark")
    }

    @Test("every minor band says its adjustments are on", arguments: [AgeBand.under13, .teen13to15, .teen16to17])
    func minors(band: AgeBand) {
        let status = band.contentControlsStatus
        #expect(status.title == "Age-appropriate adjustments active")
        #expect(status.actionTitle == "Update")
        #expect(status.canClear)
        #expect(status.systemImage == "person.crop.circle.badge.checkmark")
    }
}
