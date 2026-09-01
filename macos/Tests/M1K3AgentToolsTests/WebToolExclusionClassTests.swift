//
//  WebToolExclusionClassTests.swift
//  M1K3AgentToolsTests
//
//  Pins the P1 exclusion classes on the SHIPPING tools: every tool that can
//  move data off the Mac (or render remote content) is .network, so the
//  same-turn script↔web exclusion in LocalAgent actually bites. A new web
//  tool that forgets its class silently punches a hole in the rule — this
//  test is the tripwire.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

@testable import M1K3AgentTools
import Testing

struct WebToolExclusionClassTests {
    @Test("every network-reaching tool carries the .network exclusion class")
    func networkToolsAreClassed() {
        #expect(WebSearchTool().exclusionClass == .network)
        #expect(FetchPageTool().exclusionClass == .network)
        #expect(WikipediaTool().exclusionClass == .network)
        #expect(OpenLinkTool { _ in }.exclusionClass == .network)
        // delegate_deep spins up a web-capable child agent — it is an off-Mac
        // egress path, so it must carry .network (Finding 1).
        #expect(DelegateDeepTool(startDelegation: { _ in "" }).exclusionClass == .network)
    }

    @Test("local-only tools stay unclassed — battery-and-search must keep working")
    func localToolsAreUnclassed() {
        #expect(DateTimeTool().exclusionClass == nil)
        #expect(SystemStatusTool().exclusionClass == nil)
        // battery_status is exclusion-EXEMPT by charter, explicitly.
        #expect(BatteryStatusTool(provider: LiveBatteryHealthProvider()).exclusionClass == nil)
    }

    @Test("the context senses carry .localSensitive — they must never mix with web tools in a turn")
    func sensesAreLocalSensitive() {
        #expect(CalendarPeekTool(provider: NullCalendarPeeking()).exclusionClass == .localSensitive)
        #expect(CurrentLocationTool(provider: NullLocationProviding(), precision: .coarse)
            .exclusionClass == .localSensitive)
    }
}
