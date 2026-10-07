//
//  ToolGroupRouterTests.swift
//  M1K3ChatTests
//
//  The group head's math and its abstentions, the family-to-tool words, the pick
//  cascade (head, then Apple's pick, then the agent) and the all-tiers flag. The
//  shipping weights are pinned only by shape: the stub is untrained, and a Mac run
//  of tools/router/train_tool_router.py replaces it. The fixture suite holds either
//  way: a pick is an abstention or the tool the fixture must call.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.75. Prior: Unknown.
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Eval
import M1K3Inference
import NaturalLanguage
import Testing

struct ToolGroupRouterTests {
    /// Two groups over a 2-d vector: the first axis is web, nothing is none.
    private let head = ToolGroupRouter.Head(
        groups: ["none", "web"], weights: [[0, 0], [1, 0]], biases: [0, 0], floor: 0.6
    )

    @Test("the reading is the softmax of the L2-normalised logits, whatever the vector's scale")
    func softmaxMath() throws {
        let reading = try #require(ToolGroupRouter.read([1, 0], head: head))
        #expect(reading.group == "web")
        #expect(abs(reading.probability - exp(1) / (1 + exp(1))) < 1e-12)
        let scaled = try #require(ToolGroupRouter.read([9, 0], head: head))
        #expect(abs(scaled.probability - reading.probability) < 1e-12)
    }

    @Test("abstains when it can't score: no groups, a shape mismatch, a zero or non-finite vector")
    func abstainsWhenUnscorable() {
        let empty = ToolGroupRouter.Head(groups: [], weights: [], biases: [], floor: 0)
        #expect(ToolGroupRouter.read([1, 0], head: empty) == nil)
        #expect(ToolGroupRouter.read([1, 0, 0], head: head) == nil)
        #expect(ToolGroupRouter.read([0, 0], head: head) == nil)
        #expect(ToolGroupRouter.read([.nan, 0], head: head) == nil)
        let ragged = ToolGroupRouter.Head(groups: ["none", "web"], weights: [[0, 0]], biases: [0, 0], floor: 0)
        #expect(ToolGroupRouter.read([1, 0], head: ragged) == nil)
    }

    @Test("below the floor, on no vector, or on a none reading it abstains; at the floor it picks")
    func floorAndNone() {
        let question = "latest news"
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in [1, 0] }, head: head)?.tool == "web_search")
        let strict = ToolGroupRouter.Head(groups: head.groups, weights: head.weights, biases: head.biases, floor: 0.99)
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in [1, 0] }, head: strict) == nil)
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in nil }, head: head) == nil)
        // The none axis wins: a tools verdict and a none reading disagree, so neither decides.
        let noneFirst = ToolGroupRouter.Head(groups: ["none", "web"], weights: [[1, 0], [0, 0]], biases: [0, 0], floor: 0)
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in [1, 0] }, head: noneFirst) == nil)
    }

    @Test("a device pick needs exactly one named tool")
    func deviceWords() {
        #expect(ToolGroupRouter.deviceTool("What time is it?") == "datetime")
        #expect(ToolGroupRouter.deviceTool("Check my calendar for Friday.") == "calendar_peek")
        #expect(ToolGroupRouter.deviceTool("Battery: how much juice left?") == "battery_status")
        #expect(ToolGroupRouter.deviceTool("How much room on the hard drive?") == "system_status")
        #expect(ToolGroupRouter.deviceTool("Whereabouts am I exactly?") == "current_location")
        #expect(ToolGroupRouter.deviceTool("What is the exact current date and time on this Mac right now?") == "datetime")
        // ADR 0009's spike: a per-group router called this a device question. It names none.
        #expect(ToolGroupRouter.deviceTool("What's 17 × 23?") == nil)
        // Two named: abstain rather than guess which one.
        #expect(ToolGroupRouter.deviceTool("What's the time and my battery?") == nil)
        // Whole words only.
        #expect(ToolGroupRouter.deviceTool("daytime television") == nil)
        #expect(ToolGroupRouter.deviceTool("What day is it?") == "datetime")
        #expect(ToolGroupRouter.deviceTool("What does my day look like?") == "calendar_peek")
        #expect(ToolGroupRouter.deviceTool("Memory usage details.") == "system_status")
        #expect(ToolGroupRouter.deviceTool("Check your memory of what I said") == nil)
    }

    /// Review, 2026-10-07: "schedule a meeting" names the calendar, but it's a write. A
    /// peek would answer it with a list, and the brain might say it booked it.
    @Test("a device write abstains, so the agent (with the tools that act) gets it")
    func deviceWritesAbstain() {
        #expect(ToolGroupRouter.deviceTool("Schedule a meeting with Sean at 3") == nil)
        #expect(ToolGroupRouter.deviceTool("Add an event for lunch tomorrow") == nil)
        #expect(ToolGroupRouter.deviceTool("Set a reminder for 5pm") == nil)
        #expect(ToolGroupRouter.deviceTool("My schedule for today.") == "calendar_peek")
    }

    @Test("each family names its tool; a URL is a fetch and a reference source a lookup")
    func familyTools() {
        #expect(ToolGroupRouter.pick(group: "knowledge", question: "my notes on the seal") == ToolPick(tool: "search_knowledge", query: ""))
        #expect(ToolGroupRouter.pick(group: "activity", question: "what did we do this week") == ToolPick(tool: "recent_activity", query: ""))
        // The thinnest class: Apple's pick decides (it can still say action).
        #expect(ToolGroupRouter.pick(group: "script", question: "run the backup") == nil)
        #expect(ToolGroupRouter.pick(group: "web", question: "Fetch m1k3.app and give me your read")
            == ToolPick(tool: "fetch_page", query: "https://m1k3.app"))
        #expect(ToolGroupRouter.pick(group: "web", question: "Look up Cork's founding year from a reference source.")?.tool == "lookup_fact")
        #expect(ToolGroupRouter.pick(group: "web", question: "Who won the hurling final this year?")?.tool == "web_search")
        #expect(ToolGroupRouter.pick(group: "web", question: "Read https://example.com/post")?.tool == "fetch_page")
        // A dotted name with no fetch verb or scheme is a search, not a site.
        #expect(ToolGroupRouter.pick(group: "web", question: "What is new in Node.js 24?")?.tool == "web_search")
        #expect(ToolGroupRouter.pick(group: "web", question: "Any news on e.coli outbreaks?")?.tool == "web_search")
        #expect(ToolGroupRouter.pick(group: "none", question: "anything") == nil)
        #expect(ToolGroupRouter.pick(group: "weather", question: "anything") == nil)
    }

    @Test("every tool the head can name is one the app may dispatch")
    func namesOnlyDispatchableTools() {
        let named = ToolGroupRouter.deviceCues.map { $0.tool } + ["search_knowledge", "recent_activity", "fetch_page", "lookup_fact", "web_search"]
        #expect(Set(named).isSubset(of: ToolDispatch.dispatchable))
    }

    @Test("the shipping head's arrays agree in shape and name only known groups")
    func shippingShape() {
        let shipping = ToolGroupRouter.Head.shipping
        #expect(shipping.weights.count == shipping.groups.count)
        #expect(shipping.biases.count == shipping.groups.count)
        #expect(Set(shipping.weights.map(\.count)).count <= 1)
        #expect(Set(shipping.groups).isSubset(of: ["none", "device", "knowledge", "web", "activity", "script"]))
    }
}

/// The shipping head over the real embedder on the tool-use fixtures it never trained
/// on: it may abstain (Apple's pick takes over), never name another tool.
@Suite(.enabled(if: NLEmbedding.sentenceEmbedding(for: .english) != nil))
struct ToolGroupRouterFixtureTests {
    private let embedder = NLSentenceEmbedder()

    @Test("a tool-use fixture gets its own tool or an abstention")
    func fixturesGetTheirToolOrNothing() {
        let wrong = ChatEvalFixtures.toolUse.compactMap { fixture -> String? in
            guard let expected = fixture.expectation.mustCallTool,
                  let pick = ToolGroupRouter.pick(for: fixture.prompt, embed: embedder.vector),
                  pick.tool != expected
            else { return nil }
            return "\(fixture.id) → \(pick.tool)"
        }
        #expect(wrong.isEmpty, "wrong picks: \(wrong)")
    }
}

/// The cascade's order and the two new flags.
struct ToolPickCascadeTests {
    private actor RecordingPicker: ToolPicking {
        private(set) var calls = 0
        private let answer: (tool: String, query: String)?

        init(answer: (tool: String, query: String)?) {
            self.answer = answer
        }

        func pickTool(message _: String, instructions _: String) async throws -> (tool: String, query: String) {
            calls += 1
            guard let answer else { throw CancellationError() }
            return answer
        }
    }

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

    @Test("the head speaks first, and Apple's pick is never asked when it does")
    func headFirst() async {
        let fallback = RecordingPicker(answer: ("web_search", "x"))
        let pick = await ToolRouterWiring.cascade(
            question: "q", menu: "m", classify: { _ in ToolPick(tool: "datetime", query: "") }, fallback: fallback
        )
        #expect(pick == ToolPick(tool: "datetime", query: ""))
        #expect(await fallback.calls == 0)
    }

    @Test("an abstaining or absent head hands over to Apple's pick; a failed pick is the agent's")
    func fallsThrough() async {
        let fallback = RecordingPicker(answer: ("web_search", "news"))
        #expect(await ToolRouterWiring.cascade(question: "q", menu: "m", classify: { _ in nil }, fallback: fallback)
            == ToolPick(tool: "web_search", query: "news"))
        #expect(await ToolRouterWiring.cascade(question: "q", menu: "m", classify: nil, fallback: fallback)
            == ToolPick(tool: "web_search", query: "news"))
        #expect(await fallback.calls == 2)
        let failing = RecordingPicker(answer: nil)
        #expect(await ToolRouterWiring.cascade(question: "q", menu: "m", classify: nil, fallback: failing) == nil)
        #expect(await ToolRouterWiring.cascade(question: "q", menu: "m", classify: nil, fallback: nil) == nil)
    }

    @Test("all tiers gives any brain the route; off, it stays Mini's")
    func allTiers() {
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true) == nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true, allTiers: true) != nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: false, allTiers: true) == nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true, dispatch: true, allTiers: true)?.pick != nil)
    }

    @Test("both new flags default OFF: absent reads off, an explicit true reads on")
    func flagsDefaultOff() throws {
        let suite = "ToolPickCascadeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ToolRouterWiring.groupRouterEnabled(defaults))
        #expect(!ToolRouterWiring.allTiersEnabled(defaults))
        defaults.set(true, forKey: ToolRouterWiring.groupRouterKey)
        defaults.set(true, forKey: ToolRouterWiring.allTiersKey)
        #expect(ToolRouterWiring.groupRouterEnabled(defaults))
        #expect(ToolRouterWiring.allTiersEnabled(defaults))
    }
}
