//
//  PrivateCloudTurn.swift
//  M1K3Chat
//
//  What one Private Cloud Compute turn sends, and what the consent sheet shows
//  before it does (ADR 0006). An ALLOWLIST by construction: the request is
//  built from the question and — only when the user ticks it — the exact
//  conversation text the sheet displayed. There is no parameter for memories,
//  documents, todos, the page open beside the chat, tool results or the user
//  profile, so none of them can ride along. A PCC turn never goes through the
//  AgentRAGResponder, whose prompt carries all of those (challenger, 2026-09-14).
//
//  v1 offers one box — "this conversation" — and no per-memory or per-document
//  boxes. "Nothing leaves unless you tick it" holds with fewer boxes, and the
//  earlier local answers the conversation box would carry are shown in full
//  before the user can tick it.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (pure; the sheet and
//  the send are the app's, verify-by-launch). Prior: Unknown
//

import Foundation
import M1K3Inference

public enum PrivateCloudTurn {
    /// The sheet's one sentence: what leaves, and where it goes.
    public static let summary = "Only your message goes to Apple's Private Cloud Compute to be answered. "
        + "Nothing else leaves \(HostPlatform.thisDevice) unless you tick it below."

    /// Apple's own guarantee, in Apple's terms, with where it's published (ADR 0006:
    /// cite it, don't paraphrase it from memory). Source text, 2026-09-14: "PCC uses
    /// that data only to perform the operations requested by the user" and "no user
    /// data is retained in any form after the response is returned."
    public static let appleGuarantee = "Apple says Private Cloud Compute uses what you send only to answer it, "
        + "and keeps none of it after the answer comes back."
    // swiftlint:disable:next force_unwrapping
    public static let appleGuaranteeURL = URL(string: "https://security.apple.com/blog/private-cloud-compute/")!

    /// The shared conversation is capped so the sheet stays readable; the most
    /// recent turns win.
    static let conversationCharacterCap = 12000
    static let earlierTurnsOmitted = "(earlier turns not shared)\n\n"

    /// What the sheet offers for one send.
    public struct Consent: Sendable, Equatable {
        public let question: String
        /// The exact text that goes if the user ticks "this conversation". Nil
        /// when there is nothing earlier to share.
        public let conversation: String?
    }

    /// The one request that goes to PCC.
    public struct Request: Sendable, Equatable {
        public let instructions: String
        public let prompt: String
    }

    /// `history` is the replayable conversation (display-only messages such as
    /// script output are already excluded by the caller, as for local turns).
    public static func consent(question: String, history: [ChatTurn]) -> Consent {
        Consent(question: question, conversation: conversationText(history))
    }

    public static func request(_ consent: Consent, includeConversation: Bool, now: Date) -> Request {
        let instructions = M1K3Persona.privateCloudPrompt(now: now)
        guard includeConversation, let conversation = consent.conversation else {
            return Request(instructions: instructions, prompt: consent.question)
        }
        let prompt = "The conversation so far, which the user chose to share:\n\n"
            + conversation + "\n\nTheir new message:\n" + consent.question
        return Request(instructions: instructions, prompt: prompt)
    }

    /// "You: …" / "M1K3: …" lines, newest kept when the cap bites.
    static func conversationText(_ history: [ChatTurn]) -> String? {
        let lines = history.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (turn.role == .user ? "You: " : "M1K3: ") + text
        }
        guard !lines.isEmpty else { return nil }
        let whole = lines.joined(separator: "\n\n")
        guard whole.count > conversationCharacterCap else { return whole }
        // Cut: the omitted-turns marker counts against the cap too (the
        // `HistoryWindow.render` rule), so the shown text never exceeds it.
        let budget = max(1, conversationCharacterCap - earlierTurnsOmitted.count)
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            let cost = line.count + (kept.isEmpty ? 0 : 2)
            if total + cost > budget {
                if kept.isEmpty {
                    // One turn longer than the cap: keep its tail, the part nearest the question.
                    kept.append("…" + String(line.suffix(max(0, budget - 1))))
                }
                break
            }
            kept.append(line)
            total += cost
        }
        return earlierTurnsOmitted + kept.reversed().joined(separator: "\n\n")
    }
}
