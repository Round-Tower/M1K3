//
//  MemoryDistillerTests.swift
//  M1K3ChatTests
//
//  The distillation core, pure parts: prompt assembly (caps, role labels),
//  the FACT:-line parser (think-strip, NONE, caps, garbage tolerance), the
//  normalizer that feeds the dedupe hash, and the AFM-first/fallback
//  provider orchestration with fakes.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

// MARK: - Fakes

private struct FakeProvider: InferenceProvider, @unchecked Sendable {
    let name: String
    let isAvailable: Bool
    let result: Result<String, Error>

    func generate(prompt _: String) async throws -> String {
        try result.get()
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { c in
            if case let .success(text) = result { c.yield(text) }
            c.finish()
        }
    }
}

private struct Boom: Error {}

private func turns(_ pairs: [(String, String)]) -> [ChatTurn] {
    pairs.flatMap { [ChatTurn(role: .user, text: $0.0), ChatTurn(role: .assistant, text: $0.1)] }
}

// MARK: - Prompt

struct MemoryDistillationPromptTests {
    @Test("prompt carries role-labelled turns and the FACT: contract")
    func promptShape() {
        let prompt = MemoryDistillationPrompt.build(turns: turns([
            ("My sister is called Aoife", "Lovely name — noted."),
        ]))
        #expect(prompt.contains("USER: My sister is called Aoife"))
        #expect(prompt.contains("ASSISTANT: Lovely name — noted."))
        #expect(prompt.contains("FACT(<kind>): "))
        #expect(prompt.contains("preference"))
        #expect(prompt.contains("NONE"))
    }

    @Test("the prompt's kind prose enumerates every DistilledFactKind")
    func promptEnumeratesAllKinds() {
        // The prompt sentence is hand-written prose — this pin turns a silently
        // missing kind into a red test (the vocab cross-reference doctrine).
        let prompt = MemoryDistillationPrompt.build(turns: [])
        for kind in DistilledFactKind.allCases {
            #expect(prompt.contains("\(kind.rawValue) ("))
        }
    }

    @Test("per-turn text is capped")
    func perTurnCap() {
        let long = String(repeating: "x", count: 2000)
        let prompt = MemoryDistillationPrompt.build(turns: [ChatTurn(role: .user, text: long)])
        #expect(!prompt.contains(String(repeating: "x", count: 500)))
    }

    @Test("a monster transcript is capped from the FRONT — newest turns survive")
    func totalCapKeepsNewest() {
        let many = (0 ..< 100).map { ("question \($0) " + String(repeating: "p", count: 300), "answer \($0)") }
        let prompt = MemoryDistillationPrompt.build(turns: turns(many))
        #expect(prompt.count < 8000)
        #expect(prompt.contains("question 99"))
        #expect(!prompt.contains("question 0 "))
    }
}

// MARK: - Parser

struct MemoryFactParserTests {
    @Test("FACT: lines parse, chatter is ignored")
    func parsesFactLines() {
        let raw = """
        Sure! Here is what I found:
        FACT: Kev's sister is called Aoife.
        Some rambling between lines.
        FACT: The user prefers metric units.
        Hope that helps!
        """
        #expect(MemoryFactParser.parse(raw).map(\.text) == [
            "Kev's sister is called Aoife.",
            "The user prefers metric units.",
        ])
    }

    @Test("FACT(<kind>): lines carry the distiller's classification")
    func parsesKinds() {
        let raw = """
        FACT(profile): Kev's sister is called Aoife.
        FACT(preference): The user prefers metric units.
        FACT(decision): Kev chose RRF over learned fusion.
        FACT(episode): Kev shipped the companion on Friday.
        """
        #expect(MemoryFactParser.parse(raw) == [
            DistilledFact(text: "Kev's sister is called Aoife.", kind: .profile),
            DistilledFact(text: "The user prefers metric units.", kind: .preference),
            DistilledFact(text: "Kev chose RRF over learned fusion.", kind: .decision),
            DistilledFact(text: "Kev shipped the companion on Friday.", kind: .episode),
        ])
    }

    @Test("a bare FACT: line and an unknown label fall back to note; labels are case-insensitive")
    func kindFallbackAndCase() {
        let raw = """
        FACT: Kev lives in Cork.
        FACT(mood): The user enjoys sea swimming.
        FACT(PREFERENCE): The user likes tabs over spaces.
        """
        #expect(MemoryFactParser.parse(raw) == [
            DistilledFact(text: "Kev lives in Cork.", kind: .note),
            DistilledFact(text: "The user enjoys sea swimming.", kind: .note),
            DistilledFact(text: "The user likes tabs over spaces.", kind: .preference),
        ])
    }

    @Test("the same fact under two labels dedupes to one — the first classification wins")
    func dedupeIgnoresKind() {
        let raw = "FACT(profile): Kev lives in Cork.\nFACT(episode): Kev lives in Cork."
        #expect(MemoryFactParser.parse(raw) == [DistilledFact(text: "Kev lives in Cork.", kind: .profile)])
    }

    @Test("a FACT( line with no closing paren is malformed — dropped, not misread")
    func malformedKindDropped() {
        #expect(MemoryFactParser.parse("FACT(profile Kev lives in Cork.").isEmpty)
    }

    @Test("a FACT-prefixed WORD is not a FACT line — the delimiter guards are the boundary")
    func factPrefixedWordRejected() {
        // Pins the deliberate hasPrefix("FACT") + guard design (PR #13 doc
        // comment): "FACTUAL:" enters provisionally and dies on the guards.
        #expect(MemoryFactParser.parse("FACTUAL: The user enjoys sea swimming.").isEmpty)
    }

    @Test("whitespace around the delimiters is tolerated — a sloppy model loses no facts")
    func whitespaceAroundDelimitersTolerated() {
        let raw = """
        FACT (profile): Kev lives in Cork.
        FACT(preference) : The user likes tabs over spaces.
        FACT : The user enjoys sea swimming.
        """
        #expect(MemoryFactParser.parse(raw) == [
            DistilledFact(text: "Kev lives in Cork.", kind: .profile),
            DistilledFact(text: "The user likes tabs over spaces.", kind: .preference),
            DistilledFact(text: "The user enjoys sea swimming.", kind: .note),
        ])
    }

    @Test("NONE means no facts — cleanly")
    func noneIsEmpty() {
        #expect(MemoryFactParser.parse("NONE").isEmpty)
        #expect(MemoryFactParser.parse("  NONE\n").isEmpty)
    }

    @Test("a <think> block is stripped before parsing")
    func thinkStripped() {
        let raw = "<think>FACT: not a real fact, just thinking</think>FACT: Kev lives in Cork."
        #expect(MemoryFactParser.parse(raw).map(\.text) == ["Kev lives in Cork."])
    }

    @Test("caps: at most 8 facts, overlong and tiny facts dropped, duplicates collapsed")
    func capsAndFilters() {
        let tenFacts = (1 ... 10).map { "FACT: The user fact number \($0) is durable." }
        #expect(MemoryFactParser.parse(tenFacts.joined(separator: "\n")).count == 8)

        let overlong = "FACT: " + String(repeating: "very long fact ", count: 30)
        #expect(MemoryFactParser.parse(overlong).isEmpty)

        #expect(MemoryFactParser.parse("FACT: yes").isEmpty)

        let dupes = "FACT: Kev lives in Cork.\nFACT: Kev lives in Cork."
        #expect(MemoryFactParser.parse(dupes).count == 1)
    }

    @Test("pure garbage parses to empty, never throws")
    func garbageIsEmpty() {
        #expect(MemoryFactParser.parse("I am a helpful assistant and I think...").isEmpty)
        #expect(MemoryFactParser.parse("").isEmpty)
    }

    @Test("role-fence: a fact conflating the user with the assistant is dropped")
    func dropsAssistantConflation() {
        let raw = """
        FACT: The user's name is M1K3.
        FACT: The user prefers metric units.
        """
        #expect(MemoryFactParser.parse(raw).map(\.text) == ["The user prefers metric units."])
    }
}

// MARK: - Validator (role-fence)

struct MemoryFactValidatorTests {
    @Test("rejects facts that conflate the user with the assistant by name")
    func rejectsNameConflation() {
        #expect(!MemoryFactValidator.isAcceptable("The user's name is M1K3"))
        #expect(!MemoryFactValidator.isAcceptable("The user is called M1K3."))
        #expect(!MemoryFactValidator.isAcceptable("The user is M1K3"))
        #expect(!MemoryFactValidator.isAcceptable("M1K3 is the user"))
    }

    /// Live witnesses, 2026-08-09: "The user identifies as M1K3." was found
    /// sitting in the real store, having walked straight through the fence —
    /// the guard was a FIXED PHRASE LIST, and a small distiller paraphrases.
    /// A lookup table only ever covers the wordings someone thought of; these
    /// pin the CLASS (user ⟵copula⟶ assistant name), not seven spellings.
    @Test("rejects name conflation however the copula is phrased")
    func rejectsNameConflationParaphrases() {
        #expect(!MemoryFactValidator.isAcceptable("The user identifies as M1K3."))
        #expect(!MemoryFactValidator.isAcceptable("The user identifies themselves as M1K3"))
        #expect(!MemoryFactValidator.isAcceptable("The user refers to himself as M1K3."))
        #expect(!MemoryFactValidator.isAcceptable("The user goes by the name M1K3"))
    }

    /// Review catch on PR #112: the possessive check was NOT apostrophe-
    /// normalised — the exact bug class the sibling commit in the same PR fixed
    /// in the eval scorer. A model emitting the curly U+2019 walks through a
    /// straight-quoted `user's name is`.
    @Test("possessive name conflation survives a curly apostrophe")
    func possessiveConflationIsApostropheNormalised() {
        #expect(!MemoryFactValidator.isAcceptable("The user\u{2019}s name is M1K3"))
        #expect(!MemoryFactValidator.isAcceptable("The user\u{02BC}s name is M1K3."))
        // The false-positive guard still holds through the same normalisation.
        #expect(MemoryFactValidator.isAcceptable("The user\u{2019}s project is called M1K3."))
    }

    @Test("rejects facts that describe the user as an AI/assistant (assistant self-description)")
    func rejectsIdentityAttribution() {
        #expect(!MemoryFactValidator.isAcceptable("The user is an AI assistant"))
        #expect(!MemoryFactValidator.isAcceptable("The user is a chatbot."))
        #expect(!MemoryFactValidator.isAcceptable("The user is a language model"))
    }

    @Test("keeps genuine user facts, including near-keyword phrasings (no false positives)")
    func keepsGenuineFacts() {
        #expect(MemoryFactValidator.isAcceptable("Kev's sister is called Aoife."))
        #expect(MemoryFactValidator.isAcceptable("The user prefers metric units."))
        #expect(MemoryFactValidator.isAcceptable("Kev lives in Cork."))
        // false-positive guards: mentions M1K3 / contains "program" but is genuine
        #expect(MemoryFactValidator.isAcceptable("The user is building an app called M1K3."))
        #expect(MemoryFactValidator.isAcceptable("The user is a programmer."))
        // The user builds a THING named M1K3 — the conflation is "the user IS
        // M1K3", not "the user's project is M1K3". Subject must be the user.
        #expect(MemoryFactValidator.isAcceptable("The user's project is called M1K3."))
        #expect(MemoryFactValidator.isAcceptable("The user's app is named M1K3."))
        #expect(MemoryFactValidator.isAcceptable("The user's project name is M1K3."))
        #expect(MemoryFactValidator.isAcceptable("The user is a research assistant."))
    }
}

// MARK: - Normalizer

struct MemoryFactNormalizerTests {
    @Test("case, whitespace and trailing punctuation collapse")
    func normalizes() {
        #expect(
            MemoryFactNormalizer.normalize("Kev's  sister is Aoife.")
                == MemoryFactNormalizer.normalize("kev's sister is aoife")
        )
        #expect(
            MemoryFactNormalizer.normalize("Prefers metric units!!!")
                == "prefers metric units"
        )
    }
}

// MARK: - Provider orchestration

struct ProviderMemoryDistillerTests {
    @Test("primary's facts win; fallback never consulted")
    func primaryWins() async throws {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .success("FACT: Kev lives in Cork.")),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .failure(Boom()))
        )
        let facts = try await distiller.distill(turns: turns([("I live in Cork", "Noted")]))
        #expect(facts.map(\.text) == ["Kev lives in Cork."])
    }

    @Test("a clean NONE from the primary is a valid empty — no fall-through")
    func noneDoesNotFallThrough() async throws {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .success("NONE")),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .success("FACT: phantom fact here."))
        )
        let facts = try await distiller.distill(turns: turns([("hey", "hi")]))
        #expect(facts.isEmpty)
    }

    @Test("primary unavailable → fallback runs")
    func unavailablePrimaryFallsBack() async throws {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: false, result: .failure(Boom())),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .success("FACT: From the fallback model."))
        )
        let facts = try await distiller.distill(turns: turns([("a", "b")]))
        #expect(facts.map(\.text) == ["From the fallback model."])
    }

    @Test("primary throws → fallback runs")
    func throwingPrimaryFallsBack() async throws {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .failure(Boom())),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .success("FACT: From the fallback model."))
        )
        let facts = try await distiller.distill(turns: turns([("a", "b")]))
        #expect(facts.map(\.text) == ["From the fallback model."])
    }

    @Test("primary garbage (not NONE, no facts) → fallback runs")
    func garbagePrimaryFallsBack() async throws {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .success("As an AI I cannot…")),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .success("FACT: From the fallback model."))
        )
        let facts = try await distiller.distill(turns: turns([("a", "b")]))
        #expect(facts.map(\.text) == ["From the fallback model."])
    }

    @Test("both throw → the error propagates (caller keeps the watermark and retries)")
    func bothThrowPropagates() async {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .failure(Boom())),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .failure(Boom()))
        )
        await #expect(throws: (any Error).self) {
            try await distiller.distill(turns: turns([("a", "b")]))
        }
    }

    @Test("both garbage → empty, NOT a throw (retrying garbage forever would loop)")
    func bothGarbageIsEmpty() async throws {
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .success("blah")),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .success("more blah"))
        )
        let facts = try await distiller.distill(turns: turns([("a", "b")]))
        #expect(facts.isEmpty)
    }

    @Test("cancellation rethrows immediately — the fallback is never consulted")
    func cancellationNeverFallsBack() async {
        // A cancelled distillation must not burn a fallback generation; the
        // caller's watermark stays put and the next exit retries.
        let distiller = ProviderMemoryDistiller(
            primary: FakeProvider(name: "afm", isAvailable: true, result: .failure(CancellationError())),
            fallback: FakeProvider(name: "mlx", isAvailable: true, result: .success("FACT: must never appear."))
        )
        await #expect(throws: CancellationError.self) {
            try await distiller.distill(turns: turns([("a", "b")]))
        }
    }
}
