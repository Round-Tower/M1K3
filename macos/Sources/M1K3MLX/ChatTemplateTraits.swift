//
//  ChatTemplateTraits.swift
//  M1K3MLX
//
//  What a model's chat template does around reasoning, read from the TEMPLATE
//  TEXT rather than the repo name (#264, second half): whether the generation
//  prompt pre-opens a `<think>` tag (the model then emits only the closing tag,
//  and the app must prepend the opener or the thoughts stream as the answer —
//  Ornith, 2026-09-10), and whether the template understands `enable_thinking`.
//
//  Text heuristics, not a Jinja parse: the generation-prompt block is the text
//  after the LAST `add_generation_prompt`; an emitted `<think>` in it that is
//  not closed inside the same literal is a pre-open. Verified against the
//  templates on disk for Qwen3.5 / Qwen3.8 / Ornith (pre-open), LFM2.5-2.6B
//  (pre-open, no toggle), Qwen3-2507 / gemma-4 / LFM2.5-1.2B (no pre-open).
//  Applied FILL-ONLY: a family the name heuristic knows keeps its pinned answer
//  (gemma-4's template mentions enable_thinking; the shipped tier stays as
//  measured), an unknown family gets the template's answer after the load.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.8 (heuristic pinned on
//  the real templates; the fill-only rule keeps every shipped tier byte-identical).
//  Prior: Unknown.
//

import Foundation

public struct ChatTemplateTraits: Equatable, Sendable {
    /// The generation prompt ends with an OPEN `<think>`.
    public let preOpensThink: Bool
    /// The template reads `enable_thinking`.
    public let supportsThinkingToggle: Bool

    public init(preOpensThink: Bool, supportsThinkingToggle: Bool) {
        self.preOpensThink = preOpensThink
        self.supportsThinkingToggle = supportsThinkingToggle
    }

    /// Read the traits off a chat template's text. nil when the text carries
    /// no generation-prompt block at all (not a chat template we understand).
    public init?(template: String) {
        guard let marker = template.range(of: "add_generation_prompt", options: .backwards) else { return nil }
        let block = template[marker.upperBound...]
        self.init(
            preOpensThink: Self.emitsOpenThink(in: block),
            supportsThinkingToggle: template.contains("enable_thinking")
        )
    }

    /// An emitted string literal containing `<think>` that does not also close
    /// it — `'<think>\n'` and `"…assistant\n<think>"` are opens; the fast-mode
    /// `'<think>\n\n</think>\n\n'` pair is not. The literal's end is the next
    /// quote of EITHER kind — not escape-aware and not matched to the opening
    /// quote; fine on every verified template, a sharp edge for one that puts
    /// an escaped or opposite quote inside the think literal.
    private static func emitsOpenThink(in block: Substring) -> Bool {
        var search = block.startIndex
        while let open = block.range(of: "<think>", range: search ..< block.endIndex) {
            // The literal runs to the next quote after the tag.
            let rest = block[open.upperBound...]
            let literalEnd = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) ?? rest.endIndex
            if !rest[..<literalEnd].contains("</think>") { return true }
            search = open.upperBound
        }
        return false
    }
}
