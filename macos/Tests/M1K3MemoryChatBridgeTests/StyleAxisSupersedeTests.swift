//
//  StyleAxisSupersedeTests.swift
//  M1K3MemoryChatBridgeTests
//
//  #699, the contradiction bug MEMSTAT found (docs/evals/2026-10-27-memstat-style.txt): 7 of 8
//  style corrections sit under EmbeddingGemma's 0.95 twin bar, so both rows stayed live and the
//  style line said "long, detailed… short…". The fix, over the REAL stores both shells wire: a
//  new `.style` fact from the live writer retires the NEWEST live `.style` row whose axes
//  (StyleAxis) it covers, through the Tier-2 supersede, so the lineage is kept, a restatement
//  revives and a forget undoes. One victim per write; style only retires style; an unknown or
//  scoped ask takes no part; imports never do it.
//
//  `ApartEmbedder` puts every distinct text on its own direction, so the twin bar never fires
//  and the only supersede left to see is the axis one. The hashing embedder is used where the
//  twin path itself is the subject (the 0.982 order pair, the MEMSTAT .note classes).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
@testable import M1K3Knowledge
import M1K3Memory
@testable import M1K3MemoryChatBridge
import Testing

/// Every distinct text gets its own pseudo-random direction (128 dims, so two facts sit near
/// cosine 0): nothing is ever a semantic twin, and only the axis rule can supersede.
private struct ApartEmbedder: EmbeddingService {
    let dimension = 128
    let fingerprint = "test/apart"

    func embed(_ text: String) async throws -> [Float] {
        var state: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            state ^= UInt64(byte)
            state = state &* 1_099_511_628_211
        }
        return (0 ..< dimension).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            mixed ^= mixed >> 31
            return Float(Int64(bitPattern: mixed) >> 11) / Float(Int64(1) << 52)
        }
    }

    func isAvailable() async -> Bool {
        true
    }
}

private struct Scripted: MemoryDistilling {
    let facts: [DistilledFact]

    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}

/// The corpus, the graph and one coordinator per write, wired like the app's live distillation.
private struct Rig {
    let corpus: KnowledgeStore
    let graph: MemoryStore
    let embedder: any EmbeddingService
    var wiresGraph = true
    var supersedesStyleByAxis = true

    init(embedder: any EmbeddingService = ApartEmbedder()) throws {
        corpus = try KnowledgeStore()
        graph = try MemoryStore(path: nil)
        self.embedder = embedder
    }

    func coordinator(_ facts: [DistilledFact] = []) -> MemoryDistillationCoordinator {
        MemoryDistillationCoordinator(
            distiller: Scripted(facts: facts),
            ingester: DocumentIngester(store: corpus, embedder: embedder),
            store: corpus,
            embedder: embedder,
            graph: wiresGraph ? DistilledFactGraphAdapter(store: graph) : nil,
            supersedesStyleByAxis: supersedesStyleByAxis,
            selfNames: .none
        )
    }

    /// One fact through the one write path (the caller owns attribution, as `store` says).
    @discardableResult
    func say(_ text: String, _ kind: DistilledFactKind = .style) async throws -> Int {
        try await coordinator().store([DistilledFact(text: text, kind: kind)])
    }

    func liveStyles() throws -> [String] {
        try graph.liveStyleTexts()
    }

    func node(_ text: String) throws -> Memory? {
        try graph.allMemories(includeSuperseded: true, limit: 1000).first { $0.text == text }
    }

    func corpusKind(_ text: String) throws -> KnowledgeKind? {
        try corpus.itemID(forSourceRef: MemoryDistillationCoordinator.factSourceRef(text))
            .flatMap { try corpus.item(id: $0)?.kind }
    }

    /// `old` is superseded by `new` in the graph (the edge is the lineage) and out of retrieval in the corpus.
    func expectRetired(_ old: String, by new: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let oldNode = try #require(try node(old), sourceLocation: sourceLocation)
        let newNode = try #require(try node(new), sourceLocation: sourceLocation)
        #expect(oldNode.supersededBy == newNode.id, "\(old) -> \(new)", sourceLocation: sourceLocation)
        #expect(newNode.supersededBy == nil, sourceLocation: sourceLocation)
        #expect(try corpusKind(old) == .memorySuperseded, sourceLocation: sourceLocation)
        #expect(try corpusKind(new) == .memory, sourceLocation: sourceLocation)
    }

    func expectLive(_ texts: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        for text in texts {
            #expect(try node(text)?.supersededBy == nil, "\(text)", sourceLocation: sourceLocation)
            #expect(try node(text) != nil, "\(text)", sourceLocation: sourceLocation)
            #expect(try corpusKind(text) == .memory, "\(text)", sourceLocation: sourceLocation)
        }
    }
}

/// The eight MEMSTAT corrections, each way round.
private let correctionsBothWays: [(String, String)] = ContradictionEvalFixtures.styleCorrections.flatMap {
    [($0.prior, $0.revision), ($0.revision, $0.prior)]
}

/// Asks on different axes (and one scoped ask): both stay live, in either order.
private let compatibles: [(String, String)] = [
    ("The user prefers short answers.", "The user wants no emoji in answers."),
    ("The user prefers a casual tone.", "The user wants no bullet lists."),
    ("The user prefers plain words without jargon.", "The user wants the code before the explanation."),
    ("The user prefers answers that skip the preamble.", "The user prefers a formal tone."),
    ("The user wants no tables.", "The user wants headings in long answers."),
    ("The user wants no jokes.", "The user prefers a casual tone."),
    ("The user wants a list of sources at the end.", "The user wants no bullet lists."),
    ("The user wants to be asked before the assistant searches the web.",
     "The user wants the code before the explanation."),
    ("The user wants answers in plain text.", "The user prefers plain words without jargon."),
    ("The user prefers concise answers.", "The user wants the answer first."),
    ("The user wants a detailed answer for code reviews.", "The user prefers short answers."),
]

struct StyleAxisSupersedeTests {
    // MARK: - The bug: a style correction retires the ask it corrects

    @Test("each MEMSTAT style correction supersedes its prior, either way round, in the graph AND the corpus",
          arguments: correctionsBothWays)
    func correctionsSupersede(old: String, new: String) async throws {
        let rig = try Rig()
        #expect(try await rig.say(old) == 1)
        #expect(try await rig.say(new) == 1)

        try rig.expectRetired(old, by: new)
        #expect(try rig.liveStyles() == [new])
        // …so the style line the persona carries says only the correction.
        #expect(try UserStyleBlock.render(newestFirst: rig.liveStyles(), cap: M1K3Persona.styleCharacterCap) == new)
    }

    @Test("asks on different axes never supersede each other, in either order", arguments: compatibles)
    func compatiblesStayLive(first: String, second: String) async throws {
        for (old, new) in [(first, second), (second, first)] {
            let rig = try Rig()
            try await rig.say(old)
            try await rig.say(new)
            try rig.expectLive([old, new])
            #expect(try rig.liveStyles() == [new, old])
        }
    }

    // MARK: - Kind: style only retires style, both ways

    @Test("a preference on the same axis survives a style ask, and a note never retires a style row")
    func styleOnlyRetiresStyle() async throws {
        let rig = try Rig()
        try await rig.say("The user prefers short emails.", .preference)
        try await rig.say("The user prefers long, detailed answers.")
        try rig.expectLive(["The user prefers short emails.", "The user prefers long, detailed answers."])
        #expect(try rig.node("The user prefers short emails.")?.kind == .preference)

        try await rig.say("The user prefers short answers.", .note)
        try rig.expectLive(["The user prefers long, detailed answers.", "The user prefers short answers."])
        #expect(try rig.liveStyles() == ["The user prefers long, detailed answers."])
    }

    @Test(
        "the MEMSTAT contradictions and compatibles filed as .note keep their twin-bar outcome, no more",
        arguments: ContradictionEvalFixtures.contradictions + ContradictionEvalFixtures.compatibles
    )
    func notesKeepTheirOutcome(pair: ContradictionEvalFixtures.Pair) async throws {
        let rig = try Rig(embedder: HashingEmbeddingService())
        let bar = MemoryDistillationCoordinator.semanticDedupeThreshold(for: rig.embedder)
        let cosine = try await VectorMath.cosineSimilarity(
            rig.embedder.embed(pair.prior), rig.embedder.embed(pair.revision)
        )
        try await rig.say(pair.prior, .note)
        try await rig.say(pair.revision, .note)

        let retired = try rig.corpusKind(pair.prior) == .memorySuperseded
        #expect(retired == (cosine >= bar), "\(pair.prior) -> \(pair.revision) at \(cosine)")
        #expect(try (rig.node(pair.prior)?.supersededBy != nil) == retired)
    }

    // MARK: - Multi-axis

    @Test("a narrower correction leaves a wider ask live (pinned residue); a covering one retires it")
    func multiAxis() async throws {
        let shortCasual = "The user prefers short, casual answers."
        let formal = "The user prefers a formal tone."

        let narrower = try Rig()
        try await narrower.say(shortCasual)
        try await narrower.say(formal)
        try narrower.expectLive([shortCasual, formal]) // residue: "formal" corrects half of it

        let wider = try Rig()
        try await wider.say(formal)
        try await wider.say(shortCasual)
        try wider.expectRetired(formal, by: shortCasual)

        let both = try Rig()
        try await both.say(shortCasual)
        try await both.say("The user prefers long, formal answers.")
        try both.expectRetired(shortCasual, by: "The user prefers long, formal answers.")
    }

    @Test("two live victims: only the NEWEST goes, one per write (pinned residue)")
    func oneVictimPerWrite() async throws {
        let rig = try Rig()
        try await rig.say("The user prefers short answers.")
        try await rig.say("The user prefers a casual tone.")
        try await rig.say("The user prefers long, formal answers.")

        try rig.expectRetired("The user prefers a casual tone.", by: "The user prefers long, formal answers.")
        #expect(try rig.liveStyles() == ["The user prefers long, formal answers.", "The user prefers short answers."])
    }

    // MARK: - Unknown axis

    @Test(
        "an ask on no known axis never supersedes and is never superseded",
        arguments: [
            "The user wants answers in Irish.",
            "The user wants no fluff.",
            "The user prefers simple answers.",
            "The user wants step-by-step answers.",
        ]
    )
    func unknownNeverTakesPart(unknown: String) async throws {
        let rig = try Rig()
        try await rig.say("The user prefers short answers.")
        try await rig.say(unknown)
        try await rig.say("The user prefers long, detailed answers.")

        try rig.expectRetired("The user prefers short answers.", by: "The user prefers long, detailed answers.")
        try rig.expectLive([unknown])
    }

    // MARK: - Flows through the Tier-2 machinery

    @Test("flip back: short, long, short (the same words) ends with short live and long retired")
    func flipBack() async throws {
        let rig = try Rig()
        let short = "The user prefers short answers."
        let long = "The user prefers long, detailed answers."
        try await rig.say(short)
        try await rig.say(long)
        #expect(try await rig.say(short) == 1) // a revive, not a duplicate

        #expect(try rig.liveStyles() == [short])
        #expect(try rig.corpusKind(short) == .memory)
        #expect(try rig.corpusKind(long) == .memorySuperseded)
    }

    @Test("forgetting the correction in Memories brings the ask it retired back, in both stores")
    func forgetUndoes() async throws {
        let rig = try Rig()
        let short = "The user prefers short answers."
        let long = "The user prefers long, detailed answers."
        try await rig.say(short)
        try await rig.say(long)

        let editor = MemoryEditor(
            graph: rig.graph, corpus: rig.corpus,
            ingester: DocumentIngester(store: rig.corpus, embedder: rig.embedder), embedder: rig.embedder
        )
        _ = try editor.forget(#require(try rig.node(long)).id)

        #expect(try rig.liveStyles() == [short])
        #expect(try rig.corpusKind(short) == .memory)
        #expect(try rig.corpusKind(long) == nil)

        // Saying it again is a true duplicate: one live row, never two.
        #expect(try await rig.say(short) == 0)
        #expect(try rig.liveStyles() == [short])
    }

    @Test("the order pair (the 0.982 MEMSTAT twin) supersedes once, through the twin path")
    func orderPairSupersedesOnce() async throws {
        let rig = try Rig(embedder: HashingEmbeddingService())
        let old = "The user wants the code before the explanation."
        let new = "The user wants the explanation before the code."
        let cosine = try await VectorMath.cosineSimilarity(rig.embedder.embed(old), rig.embedder.embed(new))
        #expect(cosine >= MemoryDistillationCoordinator.semanticDedupeThreshold(for: rig.embedder))

        try await rig.say(old)
        try await rig.say(new)

        try rig.expectRetired(old, by: new)
        #expect(try rig.graph.totalCount() == 2) // one supersede node, not two
        #expect(try rig.liveStyles() == [new])
    }

    @Test("one slice that says short and later long ends with long live, whatever order the distiller emits")
    func sliceOrderFollowsTheUser() async throws {
        let rig = try Rig()
        let short = DistilledFact(text: "The user prefers short answers.", kind: .style)
        let long = DistilledFact(text: "The user prefers long, detailed answers.", kind: .style)
        // Exit-path distillation sends the whole chat as one slice.
        let written = try await rig.coordinator([long, short]).distillAndStore(turns: [
            ChatTurn(role: .user, text: "short answers please"),
            ChatTurn(role: .assistant, text: "Short it is."),
            ChatTurn(role: .user, text: "actually, make them long and detailed please"),
            ChatTurn(role: .assistant, text: "Long it is."),
        ])

        #expect(written == 2)
        try rig.expectRetired(short.text, by: long.text)
        #expect(try rig.liveStyles() == [long.text])
    }

    @Test("a coordinator with no graph does no axis work and does not fail")
    func noGraphNoAxisWork() async throws {
        var rig = try Rig()
        rig.wiresGraph = false
        #expect(try await rig.say("The user prefers short answers.") == 1)
        #expect(try await rig.say("The user prefers long, detailed answers.") == 1)

        #expect(try rig.corpusKind("The user prefers short answers.") == .memory)
        #expect(try rig.corpusKind("The user prefers long, detailed answers.") == .memory)
    }

    @Test("a writer built with supersedesStyleByAxis false (an import) never supersedes by axis")
    func gatedOffForOtherWriters() async throws {
        var rig = try Rig()
        rig.supersedesStyleByAxis = false
        try await rig.say("The user prefers short answers.")
        try await rig.say("The user prefers long, detailed answers.")

        try rig.expectLive(["The user prefers short answers.", "The user prefers long, detailed answers."])
    }
}
