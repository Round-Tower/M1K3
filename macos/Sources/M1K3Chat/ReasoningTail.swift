//
//  ReasoningTail.swift
//  M1K3Chat
//
//  The live reasoning panel renders only the thought's tail while it streams. Lil's
//  thought runs to the 1,024-token forced close (~4–5k characters), and the panel
//  re-parsed and re-laid out the WHOLE thought on every ~20Hz flush, so its cost
//  grew with every token: the visible jank on thinking turns. The tail keeps the
//  per-flush cost flat; the settled panel still shows the full thought.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-20, Confidence 0.75 (the cut is TDD'd; the
//  jank fix is verify-by-eye on a local build). Prior: none.
//  Review: Kev + claude-opus-5-5, 2026-10-21 — a negative limit clamps to zero instead of
//  trapping in `suffix` (review fold). Confidence 0.75.
//

/// The streaming thought's visible tail.
public enum ReasoningTail {
    /// About 20 lines of the panel: enough to read the thought as it moves.
    public static let liveLimit = 1500

    /// `reasoning` whole when it fits in `limit` characters; otherwise its last `limit`
    /// characters behind "… ", starting at a line break in the window's first half, else
    /// the first word. A limit below zero counts as zero.
    public static func live(_ reasoning: String, limit: Int = liveLimit) -> String {
        let limit = max(limit, 0)
        guard reasoning.count > limit else { return reasoning }
        let window = reasoning.suffix(limit)
        let half = window.index(window.startIndex, offsetBy: limit / 2)
        let start: Substring.Index = if let line = window[..<half].firstIndex(of: "\n") {
            window.index(after: line)
        } else if let space = window.firstIndex(of: " ") {
            window.index(after: space)
        } else {
            window.startIndex
        }
        return "… " + window[start...]
    }
}
