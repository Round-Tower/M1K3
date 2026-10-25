//
//  PostToolAnswer.swift
//  M1K3Chat
//
//  What a native tool turn does with the loop's OWN answer once a tool has run. Today (and by
//  default) nothing: `AgentRAGResponder` drops the post-tool step's answer tokens and runs a
//  second generation over the observations (`fallBack` → `streamFallback`), because small
//  models used to free-form a content-free "let me look" preamble after a tool and ignore what
//  it returned (gemma, 2026-09-04). That second generation is a whole decode a turn pays and
//  never shows — think and answer — on a route where the first answer had the full history and
//  the synthesis prompt has none (plan item 2, 2026-10-25).
//
//  `.use` is the A/B arm (`M1K3 -postToolAnswer use`): keep a conclusion that reads as an answer;
//  synthesise only when it does not (empty, or shorter than `usableConclusionChars` — the preamble
//  shape), after whatever already streamed. Decided per paired chateval (tool-use, grounded-Q,
//  open-chat) before any default moves; a tier may keep synthesis if its brain earns it.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-25, Confidence 0.8 (the decision table is pinned in
//  PostToolAnswerTests; the responder wiring is verify-by-eval). Prior: none (new file).
//

import Foundation

public enum PostToolAnswerPolicy: String, Sendable, Equatable {
    /// The shipped behaviour: the post-tool step's answer is discarded and re-synthesised.
    case synthesise
    /// The A/B arm: the post-tool step's answer stands when it reads as one.
    case use
}

public enum PostToolAnswer {
    /// `M1K3 -postToolAnswer use|synthesise`, read the way the other in-app A/B switches are (on
    /// macOS 27 `defaults write` never reaches the sandboxed app). Anything else is the default.
    public static func policy(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> PostToolAnswerPolicy {
        guard let raw = arguments["postToolAnswer"] as? String else { return .synthesise }
        return PostToolAnswerPolicy(rawValue: raw.lowercased()) ?? .synthesise
    }

    /// Fewer characters than this after a tool is the "let me look" shape, not an answer.
    public static let usableConclusionChars = 40

    public enum Verdict: Equatable {
        /// Run the synthesis generation; `afterPreamble` when conclusion text already streamed and the
        /// synthesis must read as a continuation of it (the ReAct dangling-preamble treatment).
        case synthesise(afterPreamble: Bool)
        /// The loop's conclusion is the answer; only the sources blocks follow it.
        case keepConclusion
    }

    /// The native route, a tool has run, the loop concluded with `conclusion` (trimmed), of which
    /// `streamed` says whether any of it reached the person live. `evidence` is whether any tool came
    /// back with something informative (the fallback prompt's own filter: not an error, not a repeat):
    /// without it the default degrades to plain RAG, and so must the arm — a 40-char apology for a
    /// rate-limited search is not an answer to keep (review fold, 2026-10-25).
    public static func verdict(
        policy: PostToolAnswerPolicy, conclusion: String, streamed: Bool, evidence: Bool = true
    ) -> Verdict {
        switch policy {
        case .synthesise:
            return .synthesise(afterPreamble: false)
        case .use:
            let trimmed = conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard evidence, trimmed.count >= usableConclusionChars else {
                return .synthesise(afterPreamble: streamed && !trimmed.isEmpty)
            }
            return .keepConclusion
        }
    }
}
