//
//  HashingMemoryGateTests.swift
//  M1K3KnowledgeTests
//
//  #447: on the hashing embedder (Mini's, and every iPhone's) a memory reaches the prompt only
//  if it shares a content word with the question. Hashing cosine is bucket collisions: "tell me
//  a joke" scored 0.387 against a Galway half marathon, and Mini worked that memory into 14 of
//  15 unrelated answers whatever the header said (2026-10-29 eval). A profile ask ("What do you
//  remember about me?", a shipped door chip) keeps every memory, as today. No stemming: the
//  challenger measured it as cost without benefit ("weather like" would meet "likes tabs").
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.7 (the rule is pinned here; its
//  held-out blind bar FAILED and Kev overrode it knowingly, see HashingMemoryGateTurnTests).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct HashingMemoryGateTests {
    static let hashing = "hashing/v1"
    static let gemma = "mlx/mlx-community/embeddinggemma-300m-4bit@512"

    static func memory(_ fact: String) -> ChunkHit {
        ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: fact, kind: .memory, heading: nil, content: fact)
    }

    static let galway = memory("The user is into trail running and did the Galway half in 2025.")
    static let doughNut = memory("The user keeps sourdough starter called Dough Nut.")
    static let sister = memory("Kev's sister is called Aoife.")

    private func admitted(_ question: String, _ memories: [ChunkHit], fingerprint: String = hashing) -> [String] {
        HashingMemoryGate.admitted(memories, question: question, fingerprint: fingerprint).map(\.content)
    }

    @Test("on any other embedder the gate is the identity: Lil and Big on EmbeddingGemma stay byte-identical")
    func otherEmbeddersUntouched() {
        let all = [Self.galway, Self.doughNut]
        #expect(admitted("why is the sky blue?", all, fingerprint: Self.gemma) == all.map(\.content))
    }

    @Test("the #447 probes carry no unrelated memory")
    func noiseProbesDropUnrelated() {
        for question in [
            "How's my battery doing right now?", "what's up?", "tell me a joke",
            "how long do I boil an egg for?", "why is the sky blue?",
        ] {
            #expect(admitted(question, [Self.galway, Self.doughNut]).isEmpty, "\(question)")
        }
    }

    @Test("a memory the question names still reaches the prompt, and only that one")
    func namedMemoryKept() {
        let sourdough = admitted("what's my sourdough starter called?", [Self.galway, Self.doughNut])
        #expect(sourdough == [Self.doughNut.content])
        #expect(admitted("what's my sister's name?", [Self.galway, Self.sister]) == [Self.sister.content])
    }

    @Test("a profile ask keeps every memory, as today; 'about' anything else is not one")
    func profileAsk() {
        let all = [Self.galway, Self.doughNut, Self.sister]
        for question in ["What do you remember about me?", "who am I?", "Tell me everything you know about myself"] {
            #expect(HashingMemoryGate.isProfileAsk(question), "\(question)")
            #expect(admitted(question, all) == all.map(\.content), "\(question)")
        }
        for question in ["tell me about meteors", "what do you know about my sister?", "how about a joke?"] {
            #expect(!HashingMemoryGate.isProfileAsk(question), "\(question)")
        }
        #expect(admitted("what do you know about my sister?", all) == [Self.sister.content])
    }

    @Test("no stemming: 'like' does not meet 'likes'")
    func noStemming() {
        #expect(admitted("what's the weather like in Tokyo?", [Self.memory("Kev likes tabs over spaces.")]).isEmpty)
    }

    @Test("the distiller's register word 'user' is not a shared subject")
    func registerWordsDontCount() {
        #expect(admitted("how many users does M1K3 have?", [Self.memory("The user prefers metric units.")]).isEmpty)
    }
}
