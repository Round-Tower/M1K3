//
//  ScreengrabCadenceTests.swift
//  M1K3ScreengrabTests
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.9, Prior: Unknown
//

import M1K3Screengrab
import M1K3Voice
import Testing

struct ScreengrabCadenceTests {
    @Test func onlyMaxWaitIsStretched() {
        let c = EndpointCadence.screengrab, base = EndpointCadence.conversational
        #expect(c.maxWait >= .seconds(600))
        #expect(c.silence == base.silence && c.hold == base.hold)
        #expect(c.emptyListensBeforeParking == base.emptyListensBeforeParking)
    }
}
