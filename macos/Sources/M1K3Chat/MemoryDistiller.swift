//
//  MemoryDistiller.swift
//  M1K3Chat
//
//  The distillation core: turn a finished conversation slice into 0-N durable
//  facts about the user. Prompt + parser + normalizer are pure (TDD'd); the
//  ProviderMemoryDistiller orchestrates AFM-first with an MLX fallback (the
//  SummarizationPipeline two-tier shape, sequential because one output is
//  consumed, not two).
//
//  Output contract is line-based — "FACT(<kind>): <one sentence>" or exactly
//  "NONE" — because small local models fumble JSON (CallSummaryParser
//  precedent) and FACT: lines parse with zero ambiguity. The parser is the
//  defence layer: whatever persona-flavoured chatter a model emits, only FACT
//  lines survive, and any malformed/unknown kind label degrades to `.note`,
//  never to a dropped fact.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.85 (pure cores
//  tested; real-model fact quality is verify-at-⌘R). Prior: Unknown
//
//  Review (2026-07-08, Kev + claude-fable-5): the distiller now CLASSIFIES —
//  facts carry a DistilledFactKind (profile/preference/decision/episode/note)
//  parsed from a FACT(<kind>): label, closing the "both write paths tag .note"
//  TODO: on MemoryKind. Bare FACT: lines still parse (kind = .note), so a model
//  that ignores the new label loses nothing. Kev's product call, 2026-07-08.

import Foundation
import M1K3Inference
import os

// MARK: - Typed fact

/// The distiller's kind vocabulary — a Chat-local mirror of the memory graph's
/// open `MemoryKind` (M1K3Chat must not depend on M1K3Memory; the
/// M1K3MemoryChatBridge adapter maps rawValue across). `note` is the fallback
/// for a bare `FACT:` line or an unrecognized label: misclassification
/// degrades to the old untyped behaviour, never to a dropped fact.
///
/// Vocabulary cross-reference — adding a kind means updating ALL of:
/// `MemoryKind.catalogued` (M1K3Memory/MemoryStore.swift), the prompt's kind
/// list in `MemoryDistillationPrompt.build` below, the MCP `remember` tool's
/// description prose (M1K3MCPKit/IntelligenceMCPTools.swift), and the expected
/// map in DistilledFactGraphAdapterTests. The derived halves (schema enum,
/// bridge mapping) follow automatically; the prose halves are pinned by tests.
public enum DistilledFactKind: String, Sendable, Codable, CaseIterable {
    case profile, preference, decision, episode, note
}

/// One distilled fact: the sentence plus the distiller's own classification.
public struct DistilledFact: Sendable, Equatable, Codable {
    public let text: String
    public let kind: DistilledFactKind

    public init(text: String, kind: DistilledFactKind = .note) {
        self.text = text
        self.kind = kind
    }
}

// MARK: - Protocol

/// Extracts durable facts from a transcript slice. Throws ONLY on total
/// generation failure — the caller withholds the distillation watermark on
/// throw so the same slice is retried at the next trigger.
public protocol MemoryDistilling: Sendable {
    func distill(turns: [ChatTurn]) async throws -> [DistilledFact]
}

// MARK: - Prompt

public enum MemoryDistillationPrompt {
    /// Neutral note-taker instructions — deliberately NOT M1K3Persona (a
    /// judge shouldn't be the defendant's twin; the distiller reads M1K3's
    /// own conversations).
    public static let instructions = """
    You are a neutral note-taker. You read conversations and extract only \
    durable facts about the user. You never chat, never add commentary, and \
    reply only in the exact format requested.
    """

    static let maxCharsPerTurn = 400
    static let maxTotalChars = 6000

    /// The transcript rendered newest-last with role labels, capped per turn
    /// and in total (newest turns survive the total cap — they're the ones
    /// the watermark says are new).
    public static func build(turns: [ChatTurn]) -> String {
        var lines: [String] = []
        var total = 0
        for turn in turns.reversed() {
            let label = turn.role == .user ? "USER" : "ASSISTANT"
            let text = String(turn.text.prefix(maxCharsPerTurn))
            let line = "\(label): \(text)"
            if total + line.count > maxTotalChars { break }
            lines.append(line)
            total += line.count
        }
        let transcript = lines.reversed().joined(separator: "\n")
        // The "FACT(<kind>)" sentence below enumerates DistilledFactKind.allCases
        // in prose — keep in sync when adding a kind (pinned by the
        // allCases-containment test in MemoryDistillerTests).
        return """
        Read the conversation below and extract facts about the user worth \
        remembering long-term: stable personal facts, preferences, decisions, \
        relationships, ongoing projects.

        Do NOT extract: small talk, transient states ("user is tired today"), \
        questions the user merely asked about, or anything the assistant said \
        about itself. The assistant is called M1K3 — NEVER write that the user \
        is M1K3, is named M1K3, or is an AI/assistant/program; those describe \
        the assistant, not the user.

        Reply with one line per fact, each starting with exactly \
        "FACT(<kind>): " where <kind> is one of: profile (a stable fact about \
        the user), preference (a standing preference), decision (a decision \
        the user made and why), episode (something that happened), or note \
        (anything else durable). Each fact must be one short standalone \
        sentence about the user. \
        If there is nothing durable, reply with exactly "NONE".

        CONVERSATION:
        \(transcript)
        """
    }
}

// MARK: - Parser

public enum MemoryFactParser {
    static let maxFacts = 8
    static let maxFactLength = 200
    static let minFactLength = 10

    /// Keep only well-formed FACT lines. Garbage in → [] out, never a throw:
    /// the parser is the defence against off-format model output.
    public static func parse(_ raw: String) -> [DistilledFact] {
        // Reasoning models think first — the facts live in the answer half.
        let answer = ReasoningSplit.split(raw).answer
        var seen = Set<String>()
        var facts: [DistilledFact] = []
        for line in answer.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let (kind, fact) = factLine(trimmed) else { continue }
            // Overlong = the model rambled mid-line; drop rather than cut a
            // fact mid-thought. Tiny = no information ("FACT: yes").
            guard fact.count >= minFactLength, fact.count <= maxFactLength else { continue }
            // Role-fence: a weak model attributes M1K3's OWN persona/self-talk to
            // "the user" ("the user's name is M1K3"). The prompt asks it not to;
            // this is the deterministic backstop that the prompt can't guarantee.
            guard MemoryFactValidator.isAcceptable(fact) else { continue }
            // Durability gate: fed a transcript, a small model summarises the
            // CONVERSATION when it was asked for facts about a person. "The user
            // asked for tips on keeping curry fresh" is true about a turn and
            // worthless about Kev — and stored for ever it out-ranks the facts
            // that matter. Measured over the live store 2026-08-09: 36 of 321
            // rows, 11% (a floor), via the MEMSTAT durability census.
            guard FactDurabilityPolicy.isDurable(fact) else { continue }
            // Dedupe on TEXT alone — the same fact under two labels is one
            // fact; the first classification wins.
            guard seen.insert(MemoryFactNormalizer.normalize(fact)).inserted else { continue }
            facts.append(DistilledFact(text: fact, kind: kind))
            if facts.count == maxFacts { break }
        }
        return facts
    }

    /// Split one "FACT: …" / "FACT(<kind>): …" line. An unrecognized kind
    /// label falls back to `.note` when the line is otherwise well-formed,
    /// and whitespace around the delimiters is tolerated ("FACT (kind) : …")
    /// — a sloppy model misclassifies, it never loses a fact. Any
    /// FACT-prefixed word ("FACTUAL:") enters provisionally and is rejected
    /// by the delimiter guards — a bare `hasPrefix("FACT:")` can't coexist
    /// with the whitespace tolerance, so the guards ARE the boundary. A line
    /// that isn't a FACT line at all (no colon, unclosed paren) returns nil.
    private static func factLine(_ line: String) -> (kind: DistilledFactKind, fact: String)? {
        guard line.hasPrefix("FACT") else { return nil }
        var rest = line.dropFirst("FACT".count).drop(while: \.isWhitespace)
        var kind = DistilledFactKind.note
        if rest.first == "(" {
            guard let close = rest.firstIndex(of: ")") else { return nil }
            let label = rest[rest.index(after: rest.startIndex) ..< close]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            kind = DistilledFactKind(rawValue: label) ?? .note
            rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
        }
        guard rest.first == ":" else { return nil }
        let fact = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return (kind, fact)
    }

    /// True when the model explicitly said there is nothing durable.
    static func isExplicitNone(_ raw: String) -> Bool {
        ReasoningSplit.split(raw).answer
            .trimmingCharacters(in: .whitespacesAndNewlines) == "NONE"
    }
}

// MARK: - Validator (role-fence)

/// Rejects "facts" that conflate the user with the assistant — the dominant
/// pollution class observed live ("the user's name is M1K3", "the user is an AI
/// assistant"). A weak distiller, fed M1K3's own ASSISTANT turns and its
/// Irish/Cork persona, mislabels M1K3's self-description as a user fact. The
/// prompt forbids this; the parser CAN'T trust a small model to obey, so this
/// is the deterministic backstop. Deliberately HIGH-PRECISION: it only fires on
/// identity conflation, never on genuine facts that merely mention M1K3 or sit
/// near a keyword (verified by false-positive tests).
public enum MemoryFactValidator {
    /// The assistant's own name(s). A user-fact equating the user with one of
    /// these is conflation, not memory.
    static let assistantNames: Set<String> = ["m1k3"]

    /// True when the fact is a genuine user fact worth storing.
    public static func isAcceptable(_ fact: String) -> Bool {
        !conflatesUserWithAssistant(fact)
    }

    static func conflatesUserWithAssistant(_ fact: String) -> Bool {
        let norm = MemoryFactNormalizer.normalize(fact)
        // 1. Name conflation — the USER (as subject) is / is called / is named
        //    the assistant. Anchored to "user" so a genuine fact about a THING
        //    the user named M1K3 survives ("the user's project is called M1K3",
        //    "the user is building an app called M1K3").
        for name in assistantNames {
            let phrases = [
                "user's name is \(name)", "user name is \(name)",
                "user is \(name)", "user is called \(name)", "user is named \(name)",
                "\(name) is the user", "user goes by \(name)",
            ]
            if phrases.contains(where: norm.contains) { return true }
        }
        // 2. Identity attribution — the user described as the assistant's KIND.
        //    \b after each kind so "programmer"/"botanist" don't match
        //    "program"/"bot".
        let kindPattern =
            #"\buser is an? (a\.?i\.?|artificial intelligence|ai assistant|assistant|chatbot|bot|language model|llm|program)\b"#
        return norm.range(of: kindPattern, options: .regularExpression) != nil
    }
}

// MARK: - Normalizer

/// Canonical form for the dedupe hash: the same fact re-distilled with
/// different capitalisation/spacing/punctuation must collapse to one row.
public enum MemoryFactNormalizer {
    public static func normalize(_ fact: String) -> String {
        var text = fact.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while let last = text.last, ".,;:!?".contains(last) {
            text = String(text.dropLast())
        }
        return text
    }
}

// MARK: - Provider orchestration

/// AFM-first, fallback second. A clean "NONE" from the primary is a valid
/// empty result (no fall-through); garbage (no FACT: lines, not NONE) tries
/// the fallback. Both producing garbage returns [] — retrying garbage forever
/// would re-distill the same slice at every conversation exit. Only a throw
/// from the final attempted provider propagates (the watermark-retry signal).
public struct ProviderMemoryDistiller: MemoryDistilling {
    private static let log = Logger(subsystem: "app.m1k3", category: "memory-distill")
    private let primary: any InferenceProvider
    private let fallback: any InferenceProvider

    public init(primary: any InferenceProvider, fallback: any InferenceProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func distill(turns: [ChatTurn]) async throws -> [DistilledFact] {
        let prompt = MemoryDistillationPrompt.build(turns: turns)
        if primary.isAvailable {
            do {
                let raw = try await primary.generate(prompt: prompt)
                let facts = MemoryFactParser.parse(raw)
                if !facts.isEmpty || MemoryFactParser.isExplicitNone(raw) {
                    return facts
                }
                // Off-format output: give the fallback a chance.
            } catch is CancellationError {
                // The turn was cancelled — never burn a fallback generation.
                throw CancellationError()
            } catch {
                // Primary generation failed: the fallback is the retry. Note it so
                // a primary that throws every time isn't masked as silent success.
                Self.log.notice("primary distiller failed, using fallback: \(error.localizedDescription, privacy: .public)")
            }
        }
        let raw = try await fallback.generate(prompt: prompt)
        return MemoryFactParser.parse(raw)
    }
}
