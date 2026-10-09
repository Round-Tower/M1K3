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
//  Review: Kev + claude-fable-5.1, 2026-10-09 — schedule-verb cases (any position, after the fold),
//  one-vector-per-turn pin (#512).
//  Review: Kev + claude-fable-5.1, 2026-10-09 — chain fixtures: `alsoCallTools` is pinned alongside `mustCallTool`.

import Foundation
@testable import M1K3Chat
@testable import M1K3Eval
import M1K3Inference
import NaturalLanguage
import Synchronization
import Testing

struct ToolGroupRouterTests {
    /// Two groups over a 2-d vector: the first axis is the user's notes, nothing is none.
    /// (A local family: the head leaves web turns to Apple's pick, #510 review.)
    private let head = ToolGroupRouter.Head(
        groups: ["none", "knowledge"], weights: [[0, 0], [1, 0]], biases: [0, 0], floor: 0.6
    )

    @Test("the reading is the softmax of the L2-normalised logits, whatever the vector's scale")
    func softmaxMath() throws {
        let reading = try #require(ToolGroupRouter.read([1, 0], head: head))
        #expect(reading.group == "knowledge")
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
        let ragged = ToolGroupRouter.Head(groups: ["none", "knowledge"], weights: [[0, 0]], biases: [0, 0], floor: 0)
        #expect(ToolGroupRouter.read([1, 0], head: ragged) == nil)
    }

    @Test("below the floor, on no vector, or on a none reading it abstains; at the floor it picks")
    func floorAndNone() {
        let question = "my notes on the seal"
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in [1, 0] }, head: head)?.tool == "search_knowledge")
        let strict = ToolGroupRouter.Head(groups: head.groups, weights: head.weights, biases: head.biases, floor: 0.99)
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in [1, 0] }, head: strict) == nil)
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in nil }, head: head) == nil)
        // The none axis wins: a tools verdict and a none reading disagree, so neither decides.
        let noneFirst = ToolGroupRouter.Head(groups: ["none", "knowledge"], weights: [[1, 0], [0, 0]], biases: [0, 0], floor: 0)
        #expect(ToolGroupRouter.pick(for: question, embed: { _ in [1, 0] }, head: noneFirst) == nil)
    }

    @Test("the device words name the tools a turn reads, whole words only")
    func deviceWords() {
        #expect(ToolGroupRouter.deviceTools("What time is it?") == ["datetime"])
        #expect(ToolGroupRouter.deviceTools("Check my calendar for Friday.") == ["calendar_peek"])
        #expect(ToolGroupRouter.deviceTools("Battery: how much juice left?") == ["battery_status"])
        #expect(ToolGroupRouter.deviceTools("How much room on the hard drive?") == ["system_status"])
        #expect(ToolGroupRouter.deviceTools("Whereabouts am I exactly?") == ["current_location"])
        #expect(ToolGroupRouter.deviceTools("What is the exact current date and time on this Mac right now?") == ["datetime"])
        // ADR 0009's spike: a per-group router called this a device question. It names none.
        #expect(ToolGroupRouter.deviceTools("What's 17 × 23?").isEmpty)
        // Two named: no single tool. Without chains the head abstains; with them it runs both.
        #expect(ToolGroupRouter.deviceTools("What's the time and my battery?") == ["battery_status", "datetime"])
        #expect(ToolGroupRouter.pick(group: "device", question: "What's the time and my battery?") == nil)
        #expect(ToolGroupRouter.pick(group: "device", question: "What's the time and my battery?", chain: true)
            == ToolPick(tool: "battery_status", query: "", then: [ToolPick(tool: "datetime", query: "")]))
        // Whole words only.
        #expect(ToolGroupRouter.deviceTools("daytime television").isEmpty)
        #expect(ToolGroupRouter.deviceTools("What day is it?") == ["datetime"])
        #expect(ToolGroupRouter.deviceTools("What does my day look like?") == ["calendar_peek"])
        #expect(ToolGroupRouter.deviceTools("Memory usage details.") == ["system_status"])
        #expect(ToolGroupRouter.deviceTools("Check your memory of what I said").isEmpty)
        // #510 review: a bare "time" or "charge" is not a device read.
        #expect(ToolGroupRouter.deviceTools("When was the last time we talked about this?").isEmpty)
        #expect(ToolGroupRouter.deviceTools("What's the charge for the meeting room?") == ["calendar_peek"])
        #expect(ToolGroupRouter.deviceTools("Tell me the time, please.") == ["datetime"])
        #expect(ToolGroupRouter.deviceTools("Any current events in Ukraine?").isEmpty)
        #expect(ToolGroupRouter.deviceTools("How big is the solar system?").isEmpty)
        #expect(ToolGroupRouter.deviceTools("When is the due date for my taxes?").isEmpty)
        #expect(ToolGroupRouter.deviceTools("Check system resources.") == ["system_status"])
    }

    /// Review, 2026-10-07: "schedule a meeting" names the calendar, but it's a write. A
    /// peek would answer it with a list, and the brain might say it booked it.
    @Test("a device write abstains, so the agent (with the tools that act) gets it")
    func deviceWritesAbstain() {
        #expect(ToolGroupRouter.deviceTools("Schedule a meeting with Sean at 3").isEmpty)
        #expect(ToolGroupRouter.deviceTools("Add an event for lunch tomorrow").isEmpty)
        #expect(ToolGroupRouter.deviceTools("Set a reminder for 5pm").isEmpty)
        #expect(ToolGroupRouter.deviceTools("My schedule for today.") == ["calendar_peek"])
        // #510 review 3: "schedule" as a verb is a write, however it's phrased.
        #expect(ToolGroupRouter.deviceTools("Schedule lunch with Sean tomorrow").isEmpty)
        #expect(ToolGroupRouter.deviceTools("schedule time with Anna").isEmpty)
        #expect(ToolGroupRouter.deviceTools("Could you schedule it for 3?").isEmpty)
        #expect(ToolGroupRouter.deviceTools("What's on the schedule today?") == ["calendar_peek"])
        // Code-quality fold: the verb mid-sentence, beside a calendar cue, is still a write.
        #expect(ToolGroupRouter.deviceTools("Can you schedule time with Anna for the meeting?").isEmpty)
        #expect(ToolGroupRouter.deviceTools("Please schedule a meeting with Sean").isEmpty)
        #expect(ToolGroupRouter.deviceTools("What's on today's schedule for my meeting?") == ["calendar_peek"])
        #expect(ToolGroupRouter.schedulesSomething("What's on today's schedule?") == false)
        #expect(ToolGroupRouter.deviceTools("Show me the schedule for the meeting") == ["calendar_peek"])
        #expect(ToolGroupRouter.schedulesSomething("my schedule") == false)
        #expect(ToolGroupRouter.schedulesSomething("schedule") == true)
    }

    @Test("each local family names its tool; web and script are left to Apple's pick")
    func familyTools() {
        #expect(ToolGroupRouter.pick(group: "knowledge", question: "my notes on the seal") == ToolPick(tool: "search_knowledge", query: ""))
        #expect(ToolGroupRouter.pick(group: "activity", question: "what did we do this week") == ToolPick(tool: "recent_activity", query: ""))
        // The thinnest class: Apple's pick decides (it can still say action).
        #expect(ToolGroupRouter.pick(group: "script", question: "run the backup") == nil)
        // #510 review: a wrong web pick is egress, so the head leaves every web turn to Apple's pick.
        #expect(ToolGroupRouter.pick(group: "web", question: "Fetch m1k3.app and give me your read") == nil)
        #expect(ToolGroupRouter.pick(group: "web", question: "Who won the hurling final this year?") == nil)
        #expect(ToolGroupRouter.pick(group: "none", question: "anything") == nil)
        #expect(ToolGroupRouter.pick(group: "weather", question: "anything") == nil)
    }

    @Test("every tool the head can name is one the app may dispatch")
    func namesOnlyDispatchableTools() {
        let named = ToolGroupRouter.deviceCues.map { $0.tool } + ["search_knowledge", "recent_activity"]
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
                  pick.tool != expected,
                  !fixture.expectation.alsoCallTools.contains(pick.tool)
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

    @Test("the gate and the head share one sentence vector per turn; a new turn embeds again (#512)")
    func vectorCachedPerTurn() {
        let calls = Mutex<[String]>([])
        let cache = OneTurnEmbedder { text in
            calls.withLock { $0.append(text) }
            return [1, 2, 3]
        }
        #expect(cache.vector("what time is it?") == [1, 2, 3])
        #expect(cache.vector("what time is it?") == [1, 2, 3])
        #expect(calls.withLock { $0 } == ["what time is it?"])
        _ = cache.vector("and my battery?")
        #expect(calls.withLock { $0 } == ["what time is it?", "and my battery?"])
    }

    private actor ChainPicker: ToolPicking {
        private(set) var chained = 0

        func pickTool(message _: String, instructions _: String) async throws -> (tool: String, query: String) {
            ("web_search", "weather")
        }

        func pickTools(message _: String, instructions: String) async throws -> [(tool: String, query: String)] {
            chained += 1
            #expect(instructions.contains(ToolDispatch.chainInstructions))
            return [(tool: "web_search", query: "weather"), (tool: "calendar_peek", query: "")]
        }
    }

    @Test("with chains on, Apple's pick is asked for two and the second rides as then; off, it names one")
    func chainedPick() async {
        let picker = ChainPicker()
        let chained = await ToolRouterWiring.cascade(question: "q", menu: "m", classify: nil, fallback: picker, chain: true)
        #expect(chained == ToolPick(tool: "web_search", query: "weather", then: [ToolPick(tool: "calendar_peek", query: "")]))
        let single = await ToolRouterWiring.cascade(question: "q", menu: "m", classify: nil, fallback: picker)
        #expect(single == ToolPick(tool: "web_search", query: "weather"))
        #expect(await picker.chained == 1)
    }

    @Test("a picker that can't chain names one tool even with chains on")
    func singlePickerWithChainOn() async {
        let picker = RecordingPicker(answer: ("datetime", ""))
        let pick = await ToolRouterWiring.cascade(question: "q", menu: "m", classify: nil, fallback: picker, chain: true)
        #expect(pick == ToolPick(tool: "datetime", query: ""))
        #expect(await picker.calls == 1)
    }

    @Test("all tiers gives any brain the route; off, it stays Mini's")
    func allTiers() {
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true) == nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true, allTiers: true) != nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: false, allTiers: true) == nil)
        #expect(ToolRouterWiring.route(provider: OtherBrain(), enabled: true, dispatch: true, allTiers: true)?.pick != nil)
    }

    @Test("the new flags default OFF: absent reads off, an explicit true reads on")
    func flagsDefaultOff() throws {
        let suite = "ToolPickCascadeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ToolRouterWiring.groupRouterEnabled(defaults))
        #expect(!ToolRouterWiring.allTiersEnabled(defaults))
        #expect(!ToolRouterWiring.chainEnabled(defaults))
        defaults.set(true, forKey: ToolRouterWiring.groupRouterKey)
        defaults.set(true, forKey: ToolRouterWiring.allTiersKey)
        defaults.set(true, forKey: ToolRouterWiring.chainKey)
        #expect(ToolRouterWiring.groupRouterEnabled(defaults))
        #expect(ToolRouterWiring.allTiersEnabled(defaults))
        #expect(ToolRouterWiring.chainEnabled(defaults))
    }
}
