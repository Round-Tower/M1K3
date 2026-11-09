//
//  ToolNarration.swift
//  M1K3Voice
//
//  Voice-first tool transparency: short spoken interstitials for the agent's
//  tool dispatches, so a hands-free user HEARS what M1K3 is doing (and what
//  leaves the device) instead of dead air. The phrase map is a deliberate,
//  credited near-duplicate of M1K3Chat's ActivityLabeler tool copy — M1K3Voice
//  stays dependency-free (the VoiceTier precedent), and spoken register wants
//  complete short sentences, not ellipsized progress labels.
//
//  ToolAnnouncementTracker is per-turn state: feed it the cumulative
//  tools-used list each poll tick and it returns only the not-yet-announced
//  names, in dispatch order. A fresh turn constructs a fresh tracker.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (pure, pinned by
//  ToolNarrationTests; the speak wiring is verify-at-⌘R). Prior: Unknown.
//  Review: Kev + claude-fable-5.2, 2026-11-09 — `unspoken` (#768): the look's tag is set when its answer is
//  final, so the tracker drops it rather than say "Using look." after the answer it names.
//

import Foundation

/// Tool name → a short spoken sentence ("Checking the web.").
public enum ToolNarration {
    /// Tags that are never announced. A look ("look", M1K3Chat's
    /// `LookPrompt.toolName`, spelled here because M1K3Voice imports nothing)
    /// is tagged when its answer lands: there is no wait to fill, and the
    /// camera being on is already on screen.
    public static let unspoken: Set<String> = ["look"]

    public static func phrase(forTool name: String) -> String {
        switch name {
        case "web_search": "Checking the web."
        case "search_knowledge": "Searching your knowledge."
        case "fetch_page": "Reading a web page."
        case "lookup_fact": "Looking that up."
        case "datetime": "Checking the clock."
        case "system_status": "Checking the machine."
        case "delegate_deep": "Starting a deep dive."
        case "list_documents": "Scanning your documents."
        case "get_document": "Opening a document."
        case "open_link": "Opening a link."
        case "recent_activity": "Looking back over the week."
        // Unknown tools humanize (underscores → spaces) rather than speak
        // snake_case aloud.
        default: "Using \(name.replacingOccurrences(of: "_", with: " "))."
        }
    }
}

/// Per-turn dedupe: which tools have already been announced aloud.
public struct ToolAnnouncementTracker: Sendable {
    private var announced: Set<String> = []

    public init() {}

    /// Given the turn's cumulative tools-used list, returns the names not yet
    /// announced, in list (dispatch) order, and marks them announced. A tag in
    /// `ToolNarration.unspoken` is never returned.
    public mutating func newAnnouncements(from toolsUsed: [String]) -> [String] {
        let fresh = toolsUsed.filter { !announced.contains($0) && !ToolNarration.unspoken.contains($0) }
        announced.formUnion(fresh)
        return fresh
    }
}
