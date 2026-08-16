//
//  ToolNarrationTests.swift
//  M1K3VoiceTests
//
//  Voice-first tool transparency: when the agent dispatches a tool mid-turn,
//  the loop speaks a short interstitial ("Checking the web.") instead of
//  sitting silent. The phrase map and the per-turn dedupe tracker are pure;
//  the wiring rides the existing runTurnStreaming poller.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (pure policy,
//  exhaustively pinned; the spoken wiring is verify-at-⌘R). Prior: Unknown.
//

import M1K3Voice
import Testing

struct ToolNarrationTests {
    @Test("known tools get short spoken phrases")
    func knownPhrases() {
        #expect(ToolNarration.phrase(forTool: "web_search") == "Checking the web.")
        #expect(ToolNarration.phrase(forTool: "search_knowledge") == "Searching your knowledge.")
        #expect(ToolNarration.phrase(forTool: "fetch_page") == "Reading a web page.")
        #expect(ToolNarration.phrase(forTool: "lookup_fact") == "Looking that up.")
        #expect(ToolNarration.phrase(forTool: "datetime") == "Checking the clock.")
        #expect(ToolNarration.phrase(forTool: "system_status") == "Checking the machine.")
        #expect(ToolNarration.phrase(forTool: "delegate_deep") == "Starting a deep dive.")
        #expect(ToolNarration.phrase(forTool: "list_documents") == "Scanning your documents.")
        #expect(ToolNarration.phrase(forTool: "get_document") == "Opening a document.")
        #expect(ToolNarration.phrase(forTool: "open_link") == "Opening a link.")
    }

    @Test("unknown tools humanize instead of speaking snake_case")
    func unknownPhrase() {
        #expect(ToolNarration.phrase(forTool: "query_graph") == "Using query graph.")
    }

    @Test("the tracker announces each tool once, in dispatch order")
    func trackerDedupes() {
        var tracker = ToolAnnouncementTracker()
        #expect(tracker.newAnnouncements(from: []) == [])
        #expect(tracker.newAnnouncements(from: ["web_search"]) == ["web_search"])
        // Same list again — nothing new to say.
        #expect(tracker.newAnnouncements(from: ["web_search"]) == [])
        // The list grows; only the growth is announced.
        #expect(tracker.newAnnouncements(from: ["web_search", "datetime"]) == ["datetime"])
        #expect(tracker.newAnnouncements(from: ["web_search", "datetime"]) == [])
    }

    @Test("a fresh tracker is a fresh turn — re-announces the same tool")
    func trackerIsPerTurn() {
        var first = ToolAnnouncementTracker()
        _ = first.newAnnouncements(from: ["web_search"])
        var second = ToolAnnouncementTracker()
        #expect(second.newAnnouncements(from: ["web_search"]) == ["web_search"])
    }
}
