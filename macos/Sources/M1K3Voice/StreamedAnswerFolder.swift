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
//  Review: Kev + claude-fable-5.1, 2026-09-30, Confidence 0.85 — the leak guard
//  runs HERE too. Speech folds sentences out of the stream before ChatSession's
//  end-of-turn PersonaLeakGuard, so a leaked prompt was read aloud and only
//  then replaced on screen (the first review of 2026-09-29 found it). Every
//  ingest asks the guard about the whole stream so far; the first leaking
//  snapshot speaks the refusal once and silences the rest of the turn. A span
//  that straddles a sentence boundary (any terminator: ". ? !") can still let
//  its first clause out — the guard's own 60-character floor bounds that, as
//  it does on screen. An unchanged snapshot never re-runs the guard.

import Foundation

public struct StreamedAnswerFolder: Sendable {
    /// The output-side prompt-leak check, applied to the stream as it arrives.
    /// `leaks` sees the WHOLE streamed text so far (spans can cross sentences);
    /// `refusal` is what gets spoken, once, in place of the leaking turn.
    public struct LeakGuard: Sendable {
        public let leaks: @Sendable (String) -> Bool
        public let refusal: String
        public init(leaks: @escaping @Sendable (String) -> Bool, refusal: String) {
            self.leaks = leaks
            self.refusal = refusal
        }
    }

    private var folder: SentenceStreamFolder
    private var streamedText = ""
    private let leakGuard: LeakGuard?
    /// Whether any sentence has been emitted — callers use it to distinguish
    /// "the model had nothing to say" from a spoken answer.
    public private(set) var emittedAny = false
    /// The guard fired: the refusal has been emitted and nothing more will be.
    public private(set) var tripped = false

    public init(stopMarker: String? = nil, leakGuard: LeakGuard? = nil) {
        folder = SentenceStreamFolder(stopMarker: stopMarker)
        self.leakGuard = leakGuard
    }

    /// See `SentenceStreamFolder.init(stopMatcher:)`.
    public init(stopMatcher: @escaping @Sendable (String) -> String.Index?, leakGuard: LeakGuard? = nil) {
        folder = SentenceStreamFolder(stopMatcher: stopMatcher)
        self.leakGuard = leakGuard
    }

    /// Fold a cumulative snapshot of the streaming answer, returning any newly
    /// completed sentences. Non-prefix updates (shrinks/rewrites) are skipped.
    /// A snapshot the guard rejects returns the refusal instead, once; after
    /// that the turn is silent.
    public mutating func ingest(_ text: String) -> [String] {
        guard !tripped, text.hasPrefix(streamedText) else { return [] }
        // The pollers re-ingest the same snapshot every tick between tokens:
        // nothing new to fold, nothing new for the guard to read.
        guard text != streamedText else { return [] }
        streamedText = text
        if let leakGuard, leakGuard.leaks(text) {
            tripped = true
            emittedAny = true
            return [leakGuard.refusal]
        }
        let sentences = folder.ingest(text)
        if !sentences.isEmpty { emittedAny = true }
        return sentences
    }

    /// The unterminated tail once the stream has settled, if any.
    public mutating func flush() -> String? {
        guard !tripped, let tail = folder.flush() else { return nil }
        emittedAny = true
        return tail
    }
}
