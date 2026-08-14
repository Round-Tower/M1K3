//
//  StreamedAnswerFolder.swift
//  M1K3Voice
//
//  SentenceStreamFolder plus the fold-forward guard: ingest cumulative
//  snapshots of a streaming answer and emit completed sentences, folding ONLY
//  prefix-extending updates. A FOLLOWUPS split or polish rewrite SHRINKS the
//  message text mid-stream; feeding that shrunken snapshot to the sentence
//  folder trips its divergence reset and re-speaks the whole answer (the
//  2026-07-25 review finding). The guard used to live inline in the Mac
//  shell's voice adapter; extracted so chat auto-speak and the voice loop
//  share one tested implementation instead of two drifting copies.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.9 (pure extraction
//  of shipped, review-hardened logic; pinned red-first). Prior: the inline
//  foldForward in AppEnvironment+VoiceMode.swift (Kev + claude-opus-5).

import Foundation

public struct StreamedAnswerFolder: Sendable {
    private var folder: SentenceStreamFolder
    private var streamedText = ""
    /// Whether any sentence has been emitted — callers use it to distinguish
    /// "the model had nothing to say" from a spoken answer.
    public private(set) var emittedAny = false

    public init(stopMarker: String? = nil) {
        folder = SentenceStreamFolder(stopMarker: stopMarker)
    }

    /// Fold a cumulative snapshot of the streaming answer, returning any newly
    /// completed sentences. Non-prefix updates (shrinks/rewrites) are skipped.
    public mutating func ingest(_ text: String) -> [String] {
        guard text.hasPrefix(streamedText) else { return [] }
        streamedText = text
        let sentences = folder.ingest(text)
        if !sentences.isEmpty { emittedAny = true }
        return sentences
    }

    /// The unterminated tail once the stream has settled, if any.
    public mutating func flush() -> String? {
        guard let tail = folder.flush() else { return nil }
        emittedAny = true
        return tail
    }
}
