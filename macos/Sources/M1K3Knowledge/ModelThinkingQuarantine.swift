//
//  ModelThinkingQuarantine.swift
//  M1K3Knowledge
//
//  M1K3 must not index its own scratchpad. Found live on 2026-08-12 by asking
//  the running app over MCP: the Summary of `Call 2 Jul 2026 at 22:14` was not a
//  summary at all, it was the model reasoning about how to write one —
//
//      <|channel>thought Thinking Process: **Analyze the Request:** The user
//      wants me to analyze a short transcript snippet…
//
//  — stored, retrievable, and injectable as grounding for six weeks. The
//  generator has since been fixed (`ThinkStripper` knew only `<think>` while
//  the resident summariser speaks gemma-4's channel dialect), but a fixed
//  generator does not un-store a stored row. This is the data half.
//
//  The sibling `SelfWiringQuarantine` is the model of it, down to the shape of
//  the rule: derive from what you are guarding, demand more than a mention, and
//  run on EVERY launch, because a maintenance chore nobody performs is not a
//  control.
//
//  ★ POSITION, NOT PRESENCE — the whole precision argument. This repo discusses
//  these tokens constantly, and Kev ingests his own documents (the OSS runsheet
//  is in his corpus today). A presence-anywhere rule would quarantine the
//  documentation ABOUT the fix along with the thing it fixes. Model thinking
//  always OPENS with its marker; prose about model thinking does not.
//
//  Signed: Kev + claude-opus-5, 2026-08-12, Confidence 0.85 (the rule is pinned
//  against the real stored text and against the false positive that would
//  actually hurt; the sweep follows a shape already proven in production by
//  SelfWiringQuarantine. Honest opens: it catches the OPENING marker only, so a
//  summary that begins with a sentence of prose and then lapses into reasoning
//  is not caught — that shape has not been observed; and the tokens are named
//  here rather than imported, because M1K3Knowledge deliberately does not depend
//  on M1K3Inference — the equality is pinned by ModelThinkingMarkerPinTests.)
//  Prior: Unknown
//

import Foundation

public enum ModelThinkingQuarantine {
    /// Reasoning-block openers, in both dialects the roster speaks: qwen's
    /// `<think>` and gemma-4's `<|channel>thought`.
    ///
    /// Deliberately duplicated from `ReasoningSplit.openTags` rather than
    /// imported — M1K3Knowledge takes no dependency on M1K3Inference (the same
    /// boundary SelfWiringQuarantine respects by having its spans injected). The
    /// duplication is the lesser evil ONLY because it is pinned:
    /// `ModelThinkingMarkerPinTests` asserts this set equals
    /// `ReasoningSplit.openTags`, via a TEST-ONLY dependency on M1K3Inference
    /// (the pattern Package.swift already uses for M1K3ChatTests → M1K3Eval).
    /// Review caught that this comment previously CLAIMED such a pin without one
    /// existing — which is the same defect as the bug below, one file over.
    public static let openMarkers = ["<|channel>thought", "<think>"]

    /// True when `text` IS model thinking rather than text that mentions it.
    ///
    /// The test is positional: after trimming leading whitespace the content must
    /// BEGIN with a marker. A document that quotes, explains or teaches these
    /// tokens has prose in front of them and is left alone.
    public static func isModelThinking(_ text: String) -> Bool {
        let head = text.drop { $0.isWhitespace || $0.isNewline }
        guard !head.isEmpty else { return false }
        return openMarkers.contains { head.hasPrefix($0) }
    }
}

public extension KnowledgeStore {
    /// Re-kind every stored item whose text opens as model thinking. Returns the
    /// ids moved; idempotent, so it is safe on every launch.
    ///
    /// Scans a chunk at a time rather than the joined item text: a call document
    /// is Summary + transcript, and it is the SUMMARY chunk that gets poisoned —
    /// joining them would bury the marker mid-string and the positional rule
    /// would (correctly, and uselessly) decline to fire.
    func quarantineModelThinking() throws -> [UUID] {
        var moved: [UUID] = []
        for kind in [KnowledgeKind.document, .call, .note, .memory] {
            for item in try allItems(kind: kind, limit: 100_000) {
                let poisoned = try chunks(forItem: item.id)
                    .contains { ModelThinkingQuarantine.isModelThinking($0.content) }
                guard poisoned else { continue }
                if try setKind(id: item.id, newKind: .quarantined) { moved.append(item.id) }
            }
        }
        return moved
    }
}
