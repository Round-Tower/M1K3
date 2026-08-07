//
//  HeartbeatEmptyRuleTests.swift
//  M1K3HeartbeatTests
//
//  Pins the anti-noise rule from the challenger pass: "nothing happened" is
//  not a status update. A quiet window records no pulse — except the day's
//  first, which always fires (the morning hello, fun fact and all), so the
//  surface never goes fully silent but never nags either.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pure rule,
//  pinned red-first). Prior: none (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct HeartbeatEmptyRuleTests {
    @Test("activity always pulses")
    func activityPulses() {
        #expect(HeartbeatEmptyRule.shouldPulse(hasActivity: true, isFirstPulseToday: false))
        #expect(HeartbeatEmptyRule.shouldPulse(hasActivity: true, isFirstPulseToday: true))
    }

    @Test("a quiet window pulses only as the day's first")
    func quietWindow() {
        #expect(HeartbeatEmptyRule.shouldPulse(hasActivity: false, isFirstPulseToday: true))
        #expect(!HeartbeatEmptyRule.shouldPulse(hasActivity: false, isFirstPulseToday: false))
    }
}

struct HeartbeatContextActivityTests {
    private func makeContext(
        memory: HeartbeatContext.MemoryActivity? = nil,
        chat: HeartbeatContext.ChatActivity? = nil,
        mcp: HeartbeatContext.MCPActivity? = nil
    ) -> HeartbeatContext {
        HeartbeatContext(
            date: Date(timeIntervalSince1970: 1_754_480_000),
            device: HeartbeatContext.Device(thermal: .nominal),
            memory: memory,
            chat: chat,
            mcp: mcp,
            funFact: .init(text: "Towers.", sourceTitle: "Irish towers")
        )
    }

    @Test("device state and a fun fact alone are not activity")
    func quietContext() {
        #expect(!makeContext().hasActivity)
    }

    @Test("memory, chat, or MCP movement each count as activity")
    func activeContext() {
        #expect(makeContext(memory: .init(newFactTitles: ["A"], supersededCount: 0)).hasActivity)
        #expect(makeContext(memory: .init(newFactTitles: [], supersededCount: 1)).hasActivity)
        #expect(makeContext(chat: .init(touchedConversationTitles: ["T"])).hasActivity)
        #expect(makeContext(mcp: .init(callCount: 3, topTools: [])).hasActivity)
    }

    @Test("empty activity sections count as quiet")
    func emptySectionsAreQuiet() {
        let context = makeContext(
            memory: .init(newFactTitles: [], supersededCount: 0),
            chat: .init(touchedConversationTitles: []),
            mcp: .init(callCount: 0, topTools: [])
        )
        #expect(!context.hasActivity)
    }
}
