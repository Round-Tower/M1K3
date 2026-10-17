//
//  ToolNeedRouterTests.swift
//  M1K3ChatTests
//
//  The tool router's pure math, its fail-open language gate (every length ×
//  signal × confidence cell pinned across the PR #414 review rounds), the
//  shipping weights over the real embedder on fixtures they never trained on,
//  and the one gate both shells read.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.85. Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — pins #622's held-out rig lines: thanks and news go tool-free,
//  past-session look-backs keep their tools. Confidence 0.8 (the OS sentence embedding can shift scores).
//  Review: Kev + claude-opus-5-5, 2026-09-27 — `routeSeesThroughFacades`: the Mac responder holds
//  the app's RuntimeInferenceProvider, which the route never saw through (build 373 shipped
//  with the router dead on the Mac). A runtime-shaped façade pins it. Confidence 0.9.
//

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

    /// #622: a question that points back at this conversation is answered from it, never a tool's
    /// output, when the chat has history. Not one tool-use fixture may trip it.
    @Test("no tool-use fixture reads as pointing back at the chat")
    func toolAsksNeverPointBack() {
        let tripped = ChatEvalFixtures.toolUse.filter { ToolNeedRouter.pointsBackInChat($0.prompt) }
        #expect(tripped.isEmpty, "tripped: \(tripped.map(\.prompt))")
    }

    @Test("questions about what was said in this chat point back", arguments: [
        "What did you say about names earlier?",
        "Who did I say is coming to stay, and why does that matter for the cat?",
        "What was the name you suggested a minute ago?",
        "Can you repeat what you just said?",
        "What did you mean by that?",
        "Which one did you recommend?",
    ])
    func pointsBack(question: String) {
        #expect(ToolNeedRouter.pointsBackInChat(question))
    }

    @Test("past sessions and the user's stores do not", arguments: [
        "What did we talk about yesterday?",
        "What did you say last week about the garage?",
        "What did I tell you on Monday?",
        "Search my notes for what I said about the boiler.",
        "What did I say in the meeting recording?",
        "Check my calendar for what I told Anna.",
        "What's the weather in Cork tomorrow?",
        "Thanks Mike, that's really helpful.",
        // Challenger, 2026-10-17: everyday requests whose verbs read like a look-back.
        "Can you tell me the weather in Cork?",
        "Could you tell me the time?",
        "Can you recommend a podcast?",
        "Can you suggest somewhere to eat near me?",
        "Can you call my mum?",
        "I told you to set a timer.",
        "What's the latest on what you told me about the election?",
        "We talked about booking flights, what are prices now?",
    ])
    func doesNotPointBack(question: String) {
        #expect(!ToolNeedRouter.pointsBackInChat(question))
    }

    /// #622: lines the voice rig sent to tools, held out of training. Thanks, news and a plain question
    /// sit near 0.05–0.10 against a ~0.32 threshold; the look-backs at a past session sit near 0.87.
    @Test("mid-conversation turns go tool-free; look-backs at a past session keep their tools", arguments: [
        ("Thanks Mike, that's really helpful.", ToolNeedRouter.Verdict.chat),
        ("My sister Rachel is coming to stay next month, and she's really allergic to cats.", .chat),
        ("Do cats really need a scratching post?", .chat),
        ("What did we talk about yesterday?", .tools),
        ("Mike, what's on my calendar tomorrow?", .tools),
    ])
    func conversationalTurns(prompt: String, verdict: ToolNeedRouter.Verdict) {
        #expect(ToolNeedRouter.verdict(for: prompt, embed: embedder.vector) == verdict)
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

    /// PR #414 review: skipping the guess for every short turn also scored short
    /// NON-English tool asks with the English model. A confident non-English guess
    /// (measured: es 0.93–0.98, fr 0.99, de 1.00) abstains at any length; the noisy
    /// short-English misreads are low-confidence ("hi" ca 0.80, "lol" nl 0.24).
    @Test("a short but confidently non-English turn abstains, so its tools stay")
    func shortNonEnglishFailsOpen() {
        for text in ["busca mi correo", "envía un email", "wie spät ist es?", "abre la web"] {
            #expect(embedder.vector(text) == nil, "\(text) was scored as English")
        }
    }

    /// PR #414 review (fe9a04ac): a long turn with NO language signal (the recognizer
    /// returns nil for digits and emoji) must abstain, as it did before the short-turn fold.
    @Test("a long turn with no language signal abstains; a short one is still read")
    func noSignalLongTurnFailsOpen() {
        #expect(embedder.vector("1234567890 0987654321 1122334455") == nil)
        #expect(embedder.vector(String(repeating: "🙂", count: 30)) == nil)
        #expect(NLSentenceEmbedder.readsAsEnglish("123"))
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

    /// Kev, 2026-09-26: default ON. An absent key is on; only an explicit false
    /// turns the router off (the escape hatch if a build needs it gone).
    @Test("dispatch has its own kill switch, also on by default; the route carries a picker only when it's on")
    func dispatchFlag() throws {
        let suite = "ToolDispatchFlag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ToolRouterWiring.dispatchEnabled(defaults))
        defaults.set(false, forKey: ToolRouterWiring.dispatchKey)
        #expect(!ToolRouterWiring.dispatchEnabled(defaults))
        let mini = AppleFoundationModelsProvider()
        #expect(ToolRouterWiring.route(provider: mini, enabled: true, dispatch: true)?.pick != nil)
        #expect(ToolRouterWiring.route(provider: mini, enabled: true, dispatch: false)?.pick == nil)
    }

    @Test("the flag defaults on: absent reads on, an explicit false reads off")
    func defaultsOn() throws {
        let suite = "ToolRouterWiringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ToolRouterWiring.isEnabled(defaults))
        defaults.set(false, forKey: ToolRouterWiring.enabledKey)
        #expect(!ToolRouterWiring.isEnabled(defaults))
        defaults.set(true, forKey: ToolRouterWiring.enabledKey)
        #expect(ToolRouterWiring.isEnabled(defaults))
    }

    /// 2026-09-26, reversed on evidence: on Mini's dispatch arm the standard persona
    /// narrated 12 of 39 answers in the third person ("M1K3, the AI who wears every
    /// sci-fi villain's grin…"); Mini's own trimmed persona narrated 0 of 100 across
    /// every arm, and was faster (tool turns 10.1 s against 13.1 s). The route keeps
    /// the provider's own persona (nil), the one Mini's synthesised answers always used.
    @Test("the app route keeps Mini's own persona (no override)")
    func routeUsesMiniPersona() {
        let mini = AppleFoundationModelsProvider()
        #expect(ToolRouterWiring.route(provider: mini, enabled: true)?.instructions == nil)
        #expect(ToolRouterWiring.route(provider: SwappableInferenceProvider(mini), enabled: true)?.instructions == nil)
    }

    /// Build 373, 2026-09-27: the Mac responder holds the app's RuntimeInferenceProvider,
    /// not a SwappableInferenceProvider, so `servedMini` never found AFM and the route
    /// never ran in the shipped Mac app ("what's the latest Apple news?" took the
    /// native session, overflowed at 5,509 tokens, and answered from local notes).
    /// Every eval handed the bare provider. The router asks which brain serves through
    /// `BackendRouting`, however many façades deep.
    @Test("the route reaches Mini through any façade, and stays off for other brains")
    func routeSeesThroughFacades() {
        let mini = AppleFoundationModelsProvider()
        #expect(ToolRouterWiring.route(provider: RoutingFacade(mini), enabled: true) != nil)
        #expect(ToolRouterWiring.route(provider: RoutingFacade(SwappableInferenceProvider(mini)), enabled: true) != nil)
        #expect(ToolRouterWiring.route(provider: RoutingFacade(OtherBrain()), enabled: true) == nil)
        #expect(ToolRouterWiring.route(provider: RoutingFacade(SwappableInferenceProvider(OtherBrain())), enabled: true) == nil)
    }
}

/// The app's RuntimeInferenceProvider in miniature: routes each turn to one backend.
private final class RoutingFacade: InferenceProvider, BackendRouting, Sendable {
    let name = "runtime-shaped"
    let routedBackend: any InferenceProvider
    init(_ backend: any InferenceProvider) {
        routedBackend = backend
    }

    var isAvailable: Bool {
        routedBackend.isAvailable
    }

    func generate(prompt: String) async throws -> String {
        try await routedBackend.generate(prompt: prompt)
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        routedBackend.generateStreaming(prompt: prompt)
    }
}
