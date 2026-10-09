//
//  Qwen35CallRepair.swift
//  M1K3MLX
//
//  One narrow, local repair for a rejected Qwen3.5 tool call — see Qwen35CallRepairTests.
//
//  Qwen3.5-4B (thinking off) writes `<function=datetime>`, then a stray `</parameter>`, then its
//  real `<parameter=query>…</parameter>`. Upstream's `.qwen35` scanner rightly rejects that as
//  `malformed_syntax` and keeps rejected calls non-executable, so the turn ends with no call and
//  the answer is fabricated (root-caused at launch, docs/GEMMA_1_1_PLAN.md Stream B; 2–3 of 3
//  datetime trials). A closing tag with no open parameter carries no data: dropping it from a
//  function's header region, then re-parsing through the SAME upstream processor the live path
//  runs, accepts the call without loosening any argument rule.
//
//  Gate: `.qwen35` + `malformedSyntax` + a complete (untruncated) preview + the orphan actually
//  present + every recovered name offered. Anything else stays rejected — this is not a general
//  tolerance layer. The upstream fix (the drafted issue, Kev files) retires this file.
//
//  Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85 — pre-push review: the re-parse was
//  STRICTER-and-looser than live (tools on → recovery scanner + schema coercion); now it is the live
//  processor exactly, with the offered-name check done here. The scan stops at each function's first
//  parameter and copies the rest verbatim to `</function>`, so a value holding `<function=` is never
//  read as structure.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8, Prior: none (new file).
//  Challenger 2026-10-07 picked this over router-gated thinking: 0 s, where thinking fixed the
//  miss only by accident at +10 s a turn.
//

import Foundation
import MLXLMCommon

enum Qwen35CallRepair {
    private static let orphanClose = "</parameter>"
    private static let functionOpen = "<function="
    private static let parameterOpen = "<parameter="
    private static let functionClose = "</function>"

    /// `raw` with every `</parameter>` that sits between a `<function=…>` header and that function's first
    /// `<parameter=` (or its `</function>`) removed; nil when there is no such orphan — nothing to repair.
    /// Only that header region is ever touched: from its first parameter the function is copied verbatim
    /// to its `</function>`, so a value that happens to contain `<function=` or `</parameter>` is never
    /// read as structure (the pre-push review's catch).
    static func strippingOrphanCloses(_ raw: String) -> String? {
        var output = ""
        var rest = Substring(raw)
        var changed = false
        while let open = rest.range(of: functionOpen) {
            output += rest[..<open.upperBound]
            rest = rest[open.upperBound...]
            // The function header runs to its `>`; orphans can only follow it.
            guard let headerEnd = rest.firstIndex(of: ">") else { break }
            output += rest[...headerEnd]
            rest = rest[rest.index(after: headerEnd)...]
            // The header region ends at the first parameter or at this function's close.
            let stops = [rest.range(of: parameterOpen)?.lowerBound, rest.range(of: functionClose)?.lowerBound]
            let regionEnd = stops.compactMap { $0 }.min() ?? rest.endIndex
            let region = rest[..<regionEnd]
            let cleaned = region.replacingOccurrences(of: orphanClose, with: "")
            if cleaned != String(region) { changed = true }
            output += cleaned
            rest = rest[regionEnd...]
            // The parameters (values included) pass through untouched, to this function's close.
            guard let close = rest.range(of: functionClose) else { break }
            output += rest[..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        output += rest
        return changed ? output : nil
    }

    /// The calls a rejected Qwen3.5 output really made, once its orphan closes are dropped — or nil
    /// when the gate doesn't hold, the repaired text still doesn't parse cleanly, or it names a tool
    /// that wasn't offered.
    ///
    /// The re-parse uses EXACTLY the live path's processor: `.qwen35` with no tools (the tool loops'
    /// `generate` passes none), so no recovery scanner and no schema coercion run here that didn't run
    /// there — a repaired call carries what the same well-formed call would have. The offered names are
    /// checked separately: a repair may only ever produce a call to a declared tool.
    static func recover(_ rejection: RejectedToolCall, offered: Set<String>) -> [ToolCall]? {
        guard rejection.format == .qwen35, rejection.reason == .malformedSyntax, !rejection.isPreviewTruncated,
              let repaired = strippingOrphanCloses(rejection.rawTextPreview)
        else { return nil }
        let processor = ToolCallProcessor(format: .qwen35)
        _ = processor.processChunk(repaired)
        processor.processEOS()
        let calls = processor.toolCalls
        guard processor.rejectedToolCallCount == 0, !calls.isEmpty,
              calls.allSatisfy({ offered.contains($0.function.name) })
        else { return nil }
        return calls
    }

    /// The function names a tool palette offers (`ToolSpec` is `{"type": "function", "function": {"name": …}}`).
    static func offeredNames(_ specs: [[String: any Sendable]]?) -> Set<String> {
        Set((specs ?? []).compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String })
    }
}
