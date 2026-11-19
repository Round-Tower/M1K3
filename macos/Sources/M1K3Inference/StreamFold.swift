//
//  StreamFold.swift
//  M1K3Inference
//
//  The one home for the InferenceProvider streaming contract's normalisation
//  rule. `generateStreaming` yields cumulative-or-delta chunks (backend-
//  defined): Apple Foundation Models sends cumulative snapshots, MLX sends
//  plain deltas. The rule that reconciles them — a chunk that extends the
//  accumulated text is a snapshot (replace / diff it), anything else is a
//  delta (append) — was hand-implemented three times across M1K3Chat and
//  M1K3Agent; it lives here once, next to the seam that defines the contract.
//
//  Signed: Kev + claude-fable-5, 2026-07-02, Confidence 0.9 (pure, two-line
//  policy, test-pinned; behavior byte-identical to the three inlined copies
//  it replaces — the empty-current case folds through both branches to the
//  same result). Prior: Kev + claude-opus-4-8 (ChatSession.fold).
//  Review: Kev + claude-opus-5.5, 2026-11-19 (the 11-18 wide eval read: two checklists frozen at "## ⚙" / "### ⏱" after
//  441 / 410 decoded tokens) — `extends` compares scalars; `fold`/`delta` use it.
//  A grapheme `hasPrefix` read an AFM snapshot completing an emoji as a delta and doubled the text. Confidence 0.9.
//

import Foundation

/// Normalisation for the dual provider stream contract (snapshot vs delta).
public enum StreamFold {
    /// Whether `text` begins with `prefix`, scalar by scalar. Never `String.hasPrefix` on streamed
    /// text: it compares grapheme clusters, and a U+FE0F, skin tone or joiner arriving after an
    /// emoji rewrites the emoji's cluster, so the text so far stops being a "prefix" of its own
    /// continuation (2026-11-19: answers frozen at "## ⚙"). Scalars also mean no canonical
    /// equivalence: a stream that re-normalised earlier text (NFC ↔ NFD) would read as a delta.
    /// No runtime here does that.
    public static func extends(_ text: String, _ prefix: String) -> Bool {
        text.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// Fold a chunk into the accumulated text: snapshot replaces, delta appends.
    public static func fold(current: String, chunk: String) -> String {
        extends(chunk, current) ? chunk : current + chunk
    }

    /// The new text a chunk contributes: a snapshot's tail past `current`, or
    /// the whole chunk when it's already a delta.
    public static func delta(current: String, chunk: String) -> String {
        guard extends(chunk, current) else { return chunk }
        return String(String.UnicodeScalarView(chunk.unicodeScalars.dropFirst(current.unicodeScalars.count)))
    }
}
