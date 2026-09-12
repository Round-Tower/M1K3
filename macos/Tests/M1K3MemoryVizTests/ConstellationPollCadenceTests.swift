//
//  ConstellationPollCadenceTests.swift
//  M1K3MemoryVizTests
//
//  The constellation canvas polls the memory store for growth. Until the
//  2026-09-12 thermal audit the cadence only knew "hot or not" — a canvas in
//  an occluded window (or a menu-bar popover that had been closed) kept the
//  2 s store poll going. Hidden now beats throttled beats active.
//

@testable import M1K3MemoryViz
import Testing

struct ConstellationPollCadenceTests {
    private let cadence = ConstellationPollCadence(active: .seconds(2), throttled: .seconds(10), hidden: .seconds(30))

    @Test("visible on a cool Mac polls at the active cadence")
    func activeWhenVisibleAndCool() {
        #expect(cadence.interval(hidden: false, throttled: false) == .seconds(2))
    }

    @Test("visible under thermal / low-power pressure backs off to throttled")
    func throttledWhenHot() {
        #expect(cadence.interval(hidden: false, throttled: true) == .seconds(10))
    }

    @Test("a hidden canvas backs off to the hidden cadence — whether or not the Mac is hot")
    func hiddenWinsOverThrottle() {
        #expect(cadence.interval(hidden: true, throttled: false) == .seconds(30))
        #expect(cadence.interval(hidden: true, throttled: true) == .seconds(30))
    }

    @Test("the default cadence matches the Mac canvas' historical 2 s / 10 s")
    func defaultsMatchHistory() {
        let historic = ConstellationPollCadence()
        #expect(historic.interval(hidden: false, throttled: false) == .seconds(2))
        #expect(historic.interval(hidden: false, throttled: true) == .seconds(10))
        #expect(historic.interval(hidden: true, throttled: false) > .seconds(10))
    }
}
