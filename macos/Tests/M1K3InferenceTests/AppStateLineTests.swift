//
//  AppStateLineTests.swift
//  M1K3InferenceTests
//
//  "Is it ready now?" — the first App Store review (iPhone, 2026-11-01): M1K3 couldn't see its own state,
//  so the answer rambled. The line tells the brain what is true right now, and says nothing at all in the
//  steady state, so ordinary prompts stay byte-identical.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.8. Prior: Unknown.
//

import Foundation
@testable import M1K3Inference
import Testing

struct AppStateLineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ load: ModelLoadState, brain: String = "Lil", answering: String? = nil,
        stalled: Bool = false, readySince: Date? = nil, afmGettingReady: Bool = false
    ) -> AppStateSnapshot {
        AppStateSnapshot(
            brain: brain, load: load, answeringBrain: answering, downloadStalled: stalled,
            readySince: readySince, appleIntelligenceGettingReady: afmGettingReady
        )
    }

    @Test("steady state says nothing")
    func steadyStateIsSilent() {
        #expect(AppStateLine.render(snapshot(.idle), now: now) == nil)
        #expect(AppStateLine.render(snapshot(.ready), now: now) == nil)
        #expect(AppStateLine.render(snapshot(.ready, readySince: now.addingTimeInterval(-3600)), now: now) == nil)
    }

    @Test("downloading: the brain, the percent, and who answers meanwhile")
    func downloading() {
        #expect(AppStateLine.render(snapshot(.downloading(fraction: 0.42)), now: now)
            == "M1K3 right now: Lil is still downloading (42%), so it isn't ready yet.")
        #expect(AppStateLine.render(snapshot(.downloading(fraction: 0.42), answering: "Mini"), now: now)
            == "M1K3 right now: Lil is still downloading (42%), so it isn't ready yet. Mini is answering until then.")
    }

    @Test("a stalled download says what it needs")
    func stalled() {
        #expect(AppStateLine.render(snapshot(.downloading(fraction: 0.1), stalled: true), now: now)
            == "M1K3 right now: Lil is still downloading (10%), so it isn't ready yet. "
            + "The download has stalled: it needs Wi-Fi, and M1K3 kept open.")
    }

    @Test("preparing and failed")
    func preparingAndFailed() {
        #expect(AppStateLine.render(snapshot(.preparing), now: now)
            == "M1K3 right now: Lil is downloaded and still loading, so it isn't ready yet.")
        #expect(AppStateLine.render(snapshot(.failed(message: "Not enough space on this device.")), now: now)
            == "M1K3 right now: Lil couldn't load: Not enough space on this device.")
    }

    @Test("just became ready: say so for ten minutes, then go quiet")
    func justReady() {
        #expect(AppStateLine.render(snapshot(.ready, readySince: now.addingTimeInterval(-60)), now: now)
            == "M1K3 right now: Lil finished getting ready and is answering now.")
        #expect(AppStateLine.render(snapshot(.ready, readySince: now.addingTimeInterval(-601)), now: now) == nil)
    }

    @Test("Apple Intelligence still getting ready, for Mini")
    func afmGettingReady() {
        #expect(AppStateLine.render(snapshot(.idle, brain: "Mini", afmGettingReady: true), now: now)
            == "M1K3 right now: Apple Intelligence is still getting ready on this device, so Mini isn't ready yet.")
    }

    @Test("a long, multi-line failure is one clipped line in the prompt")
    func failureIsClipped() throws {
        let long = "First line.\n" + String(repeating: "x", count: 400)
        let line = try #require(AppStateLine.render(snapshot(.failed(message: long)), now: now))
        #expect(!line.contains("\n"))
        #expect(line.hasSuffix("…"))
        #expect(line.count < 220)
    }

    @Test("a started download under half a percent reads <1%, like the bar")
    func tinyFraction() {
        #expect(AppStateLine.render(snapshot(.downloading(fraction: 0.002)), now: now)?.contains("(<1%)") == true)
    }
}
