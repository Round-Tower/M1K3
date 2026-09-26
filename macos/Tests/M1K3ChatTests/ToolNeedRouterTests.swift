import Foundation
@testable import M1K3Chat
@testable import M1K3Eval
import M1K3Inference
import NaturalLanguage
import Testing

/// The per-turn tool router (Kev, 2026-09-26): a live A/B measured Mini's chat
/// turn at 51.5 s with the tool palette and 13.4 s without, so a turn that
/// needs no tool should not pay for them. The router is a logistic layer over
/// Apple's built-in sentence embedding (scratch/laya-spike FINDINGS, round 3),
/// and it fails OPEN: anything it can't read keeps the tools.
struct ToolNeedRouterTests {
    @Test("fails open: no embedding, a wrong-sized one, or a non-finite score keeps the tools")
    func failsOpen() {
        #expect(ToolNeedRouter.verdict(for: "hello", embed: { _ in nil }) == .tools)
        #expect(ToolNeedRouter.verdict(for: "hello", embed: { _ in [0.1, 0.2] }) == .tools)
        #expect(ToolNeedRouter.verdict(probability: nil) == .tools)
        #expect(ToolNeedRouter.verdict(probability: .nan) == .tools)
    }

    @Test("the threshold splits the verdict: at or above keeps the tools")
    func threshold() {
        let t = ToolNeedRouterWeights.threshold
        #expect(ToolNeedRouter.verdict(probability: t) == .tools)
        #expect(ToolNeedRouter.verdict(probability: t - 0.001) == .chat)
        #expect(ToolNeedRouter.verdict(probability: 1) == .tools)
        #expect(ToolNeedRouter.verdict(probability: 0) == .chat)
    }

    @Test("probability is the logistic of the L2-normalised dot product")
    func probabilityMath() throws {
        let dimension = ToolNeedRouterWeights.weights.count
        #expect(dimension == 512)
        // A zero vector has no direction: fail open rather than divide by zero.
        #expect(ToolNeedRouter.probability([Double](repeating: 0, count: dimension)) == nil)
        // Scaling the input must not change the score (the vector is normalised).
        var unit = [Double](repeating: 0, count: dimension)
        unit[0] = 1
        let p1 = try #require(ToolNeedRouter.probability(unit))
        let p2 = try #require(ToolNeedRouter.probability(unit.map { $0 * 7 }))
        #expect(abs(p1 - p2) < 1e-12)
        let z = ToolNeedRouterWeights.weights[0] + ToolNeedRouterWeights.bias
        #expect(abs(p1 - 1 / (1 + exp(-z))) < 1e-12)
    }
}

/// The shipping weights over the real embedder, scored on the eval fixtures the
/// weights were NOT trained on. Needs Apple's English sentence embedding.
@Suite(.enabled(if: NLEmbedding.sentenceEmbedding(for: .english) != nil))
struct ToolNeedRouterFixtureTests {
    private let embedder = NLSentenceEmbedder()

    @Test("every tool-use fixture keeps its tools (a miss would hide the tool it needs)")
    func toolAsksKeepTools() {
        let misses = ChatEvalFixtures.toolUse.filter {
            ToolNeedRouter.verdict(for: $0.prompt, embed: embedder.vector) != .tools
        }
        #expect(misses.isEmpty, "routed to chat: \(misses.map(\.id))")
    }

    @Test("a real share of plain chat goes tool-free (the point of the router)")
    func chatGoesToolFree() {
        let chat = ChatEvalFixtures.openChat + ChatEvalFixtures.humour + ChatEvalFixtures.worldKnowledge
        let free = chat.filter { ToolNeedRouter.verdict(for: $0.prompt, embed: embedder.vector) == .chat }
        // Spike, frozen threshold: 28/74 of all no-tool fixtures. Chat-shaped kinds sit
        // higher; the floor pins "the router does something", not a tuned number.
        #expect(free.count * 4 >= chat.count, "only \(free.count)/\(chat.count) chat fixtures went tool-free")
    }

    /// Challenger review, 2026-09-26: NLLanguageRecognizer reads "hi" as Catalan,
    /// "lol" as Dutch, "ok cool" as Polish, so a strict dominant-language gate sent
    /// the easiest chat turns of all to the tool palette.
    @Test("short chat turns are read as English, not failed open on a noisy language guess")
    func shortTurnsGetAVector() {
        for text in ["hi", "lol", "ok cool", "thanks!", "Hey M1K3", "nice one"] {
            #expect(embedder.vector(text) != nil, "\(text) abstained")
        }
    }

    @Test("the embedder abstains on non-English text, so the router keeps the tools")
    func nonEnglishFailsOpen() {
        #expect(embedder.vector("¿Cuál es la capital de Australia y por qué la eligieron?") == nil)
        #expect(ToolNeedRouter.verdict(for: "Quelle heure est-il maintenant, s'il vous plaît ?", embed: embedder.vector) == .tools)
    }
}

/// Both shells ask one place whether this turn gets the router: the flag is on
/// AND the brain answering is Apple's on-device model (Mini). The pocket Mini
/// (LFM2 on MLX) and Lil/Big never see it: their prompt cache is keyed on the
/// palette, and the A/B that justified the route was measured on AFM.
struct ToolRouterWiringTests {
    private struct OtherBrain: InferenceProvider {
        let name = "other"
        let isAvailable = true
        func generate(prompt _: String) async throws -> String {
            ""
        }

        func generateStreaming(prompt _: String) -> AsyncStream<String> {
            AsyncStream { $0.finish() }
        }
    }

    @Test("only Mini (AFM) with the flag on gets a route, directly or behind the swappable façade")
    func gate() {
        let mini = AppleFoundationModelsProvider()
        #expect(ToolRouterWiring.route(provider: mini, enabled: true) != nil)
        #expect(ToolRouterWiring.route(provider: mini, enabled: false) == nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true) == nil)
        #expect(ToolRouterWiring.route(provider: SwappableInferenceProvider(mini), enabled: true) != nil)
        #expect(ToolRouterWiring.route(provider: SwappableInferenceProvider(OtherBrain()), enabled: true) == nil)
    }

    /// Kev, 2026-09-26: the route speaks in the standard persona, the one Mini's
    /// agent turns use, so a routed turn keeps the voice and the follow-up chips.
    /// Measured: first words ~5.1 s against ~4.4 s on Mini's trimmed prewarmed one.
    @Test("the app route speaks in the same persona as Mini's agent turns")
    func routeUsesAgentPersona() {
        let mini = AppleFoundationModelsProvider()
        #expect(ToolRouterWiring.route(provider: mini, enabled: true)?.instructions
            == M1K3Persona.systemPrompt(variant: mini.personaVariant))
        #expect(ToolRouterWiring.route(provider: SwappableInferenceProvider(mini), enabled: true)?.instructions
            == M1K3Persona.systemPrompt(variant: .standard))
    }
}
