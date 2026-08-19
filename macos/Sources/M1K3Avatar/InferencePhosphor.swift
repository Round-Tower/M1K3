//
//  InferencePhosphor.swift
//  M1K3Avatar
//
//  The "thinking rain" ledger: M1K3's live inference, scrolling up behind the
//  avatar like text on a CRT. Transparency as aesthetic — the anti-black-box.
//  Pure and TDD'd; the Canvas that draws it (M1K3App/InferencePhosphorView)
//  reads `active(at:)` + the opacity/offset math and paints, mirroring
//  CRTOverlay's TimelineView idiom.
//
//  ★ THE PRIVACY LINE IS STRUCTURAL, not a runtime check. Two ingest paths:
//
//    - `ingestOwn(_:source:at:)` — M1K3's OWN generation (its reasoning, its
//      tool activity, its answer). Shown VERBATIM — that IS the transparency.
//    - `ingestVisitor(seed:length:at:)` — a VISITING agent's traffic (an MCP
//      caller, a Brain-at-Home device). Takes only a SEED and a length; there
//      is no text parameter, so a visitor's content cannot reach the glyph
//      string by any code path. The line is derived glyphs from a fixed
//      alphabet — you can see that a visitor is active, never WHAT they asked.
//
//  This mirrors the same own-vs-visitor line the rest of the stack draws
//  (ActivityLabeler shows M1K3's own web query; the Agent Log's visitor text
//  never leaves its opt-in store). A glyph rain that rendered a visitor's
//  prompt would be a leak wearing an animation.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure, TDD'd
//  red-first; the structural privacy split is pinned both ways — visitor
//  lines contain only alphabet glyphs, own lines pass through). Prior: the
//  data-rain seed (project-memory 2026-08-06/16, "own work = real fragments;
//  visitor traffic = derived glyphs ONLY").
//

import Foundation

/// Where a phosphor line came from — drives its tint and whether it is real
/// text (M1K3's own) or derived glyphs (a visitor's).
public enum PhosphorSource: String, Sendable, Equatable, CaseIterable {
    /// M1K3's own chain-of-thought (`<think>` reasoning). Verbatim. (No brain
    /// on the current roster emits this, but the seam is ready for one that
    /// does — a thinking model rains its reasoning here.)
    case thinking
    /// M1K3's own tool dispatch label ("Recalling what I know…"). Verbatim.
    case tool
    /// A heartbeat pulse — M1K3's own ambient narrative of its day. Verbatim.
    case heartbeat
    /// A notification M1K3 raised (answer ready, deep dive finished, …).
    case notification
    /// M1K3's own answer tokens. Verbatim. Deliberately NOT fed to the rain:
    /// the answer already lives in the chat bubble / spoken line, so raining
    /// it duplicates the output. Kept for a future surface that wants it.
    case answer
    /// A visiting agent's traffic — DERIVED GLYPHS ONLY, never their content.
    case visitor

    /// True for M1K3's own generation (shown verbatim); false for a visitor
    /// (glyphs only). The single predicate the ingest paths are built around.
    public var isOwnOutput: Bool {
        self != .visitor
    }
}

/// One ambient fragment awaiting the rain — a complete short string (a
/// heartbeat pulse, a notification body) an app subsystem pushed, before the
/// view splits it into phrase lines. Own output only (the ring that carries
/// these refuses a visitor source).
public struct AmbientNote: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let source: PhosphorSource

    public init(id: Int, text: String, source: PhosphorSource) {
        self.id = id
        self.text = text
        self.source = source
    }
}

/// One line in the rain — already-safe text (own verbatim, or derived glyphs)
/// with the birth time the Canvas ages it from.
public struct PhosphorLine: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let source: PhosphorSource
    public let bornAt: Date

    public init(id: Int, text: String, source: PhosphorSource, bornAt: Date) {
        self.id = id
        self.text = text
        self.source = source
        self.bornAt = bornAt
    }
}

public struct InferencePhosphor: Sendable {
    /// The derived-glyph alphabet for VISITOR lines — deliberately abstract
    /// marks (never letters/digits that could spell content). A visitor line
    /// is drawn only from this set, which is what makes "no content leaks"
    /// checkable: assert every visitor line's characters ⊆ this set.
    public static let glyphAlphabet: [Character] = Array("·:+=*/\\|—░▒▓◦∙°")

    public private(set) var lines: [PhosphorLine] = []
    private var nextID = 0

    /// Newest-first cap: the rain holds at most this many lines.
    public let maxLines: Int
    /// Per-line character cap — a long reasoning chunk becomes a legible
    /// fragment, not a wall. Own text is trimmed to this; visitor length is
    /// clamped to it.
    public let fragmentCap: Int
    /// How long a line lives before it has fully faded and is dropped.
    public let lineTTL: TimeInterval
    /// Fade-in ramp at the head of a line's life (rest of life it holds, then
    /// fades out over the final `lineTTL - fadeIn`… see `opacity`).
    public let fadeIn: TimeInterval

    public init(
        maxLines: Int = 14,
        fragmentCap: Int = 48,
        lineTTL: TimeInterval = 6,
        fadeIn: TimeInterval = 0.35
    ) {
        self.maxLines = max(1, maxLines)
        self.fragmentCap = max(1, fragmentCap)
        self.lineTTL = max(0.1, lineTTL)
        self.fadeIn = max(0, min(fadeIn, self.lineTTL / 2))
    }

    // MARK: - Ingest (the structural own/visitor split)

    /// Ingest M1K3's OWN output — shown verbatim. Whitespace is collapsed and
    /// the fragment capped; empty/blank input and a `.visitor` source are
    /// ignored (a visitor can only enter via `ingestVisitor`, which has no
    /// text). A run identical to the current head is skipped so a poll that
    /// re-reads the same chunk doesn't stack duplicates.
    public mutating func ingestOwn(_ text: String, source: PhosphorSource, at now: Date) {
        guard source.isOwnOutput else { return }
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !flattened.isEmpty else { return }
        let fragment = String(flattened.prefix(fragmentCap))
        append(text: fragment, source: source, at: now)
    }

    /// Ingest a VISITING agent's activity as DERIVED GLYPHS. No text crosses
    /// this boundary — only a seed (e.g. a call count, a hash of the tool
    /// NAME, a timestamp) and a desired length. The glyphs are drawn
    /// deterministically from `glyphAlphabet`, so the line signals "a visitor
    /// is working" and nothing about what they asked.
    public mutating func ingestVisitor(seed: UInt64, length: Int, at now: Date) {
        let count = max(1, min(length, fragmentCap))
        var state = seed &+ 0x9E37_79B9_7F4A_7C15 // avoid a 0-seed fixed point
        var glyphs = ""
        let alphabet = Self.glyphAlphabet
        for _ in 0 ..< count {
            // SplitMix64 step — deterministic, no Foundation RNG (SelfTest/CI
            // reproducibility), and content-free by construction.
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            glyphs.append(alphabet[Int(z % UInt64(alphabet.count))])
        }
        append(text: glyphs, source: .visitor, at: now)
    }

    private mutating func append(text: String, source: PhosphorSource, at now: Date) {
        if let last = lines.last, last.text == text, last.source == source { return }
        lines.append(PhosphorLine(id: nextID, text: text, source: source, bornAt: now))
        nextID += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    // MARK: - Age / visibility (pure — the Canvas paints from these)

    /// Drop fully-expired lines and return what should still be on screen,
    /// oldest first (the Canvas stacks newest at the bottom, rising).
    public mutating func prune(at now: Date) {
        lines.removeAll { now.timeIntervalSince($0.bornAt) >= lineTTL }
    }

    /// The live lines at `now`, oldest first — non-mutating (the view reads
    /// this every frame; `prune` is the periodic cleanup).
    public func active(at now: Date) -> [PhosphorLine] {
        lines.filter { now.timeIntervalSince($0.bornAt) < lineTTL }
    }

    /// A line's opacity for its age: ramp up over `fadeIn`, hold, then fade to
    /// 0 across the tail. 0 before birth and after TTL.
    public func opacity(for line: PhosphorLine, at now: Date) -> Double {
        let age = now.timeIntervalSince(line.bornAt)
        guard age >= 0, age < lineTTL else { return 0 }
        if age < fadeIn { return age / fadeIn }
        let holdEnd = lineTTL * 0.55
        if age <= holdEnd { return 1 }
        let tail = lineTTL - holdEnd
        return max(0, 1 - (age - holdEnd) / tail)
    }

    /// Vertical rise (points) for a line's age — 0 at birth, climbing to
    /// `riseHeight` at TTL. The Canvas subtracts this from the baseline so
    /// lines drift upward as they fade.
    public func rise(for line: PhosphorLine, at now: Date, riseHeight: Double) -> Double {
        let age = max(0, min(now.timeIntervalSince(line.bornAt), lineTTL))
        return riseHeight * (age / lineTTL)
    }
}
