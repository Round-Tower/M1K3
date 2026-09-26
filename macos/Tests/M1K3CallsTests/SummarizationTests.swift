//
//  SummarizationTests.swift
//  M1K3CallsTests
//
//  Parser (free text → CallSummary) + the two-stage pipeline's error isolation.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-26 — markdown headers, the leak drop, neutral
//  instructions and long-call map-reduce (ScriptedInference counts the chunk passes); each
//  pins a failure CallSummaryLiveEvalTests found live. Confidence 0.9.

import Foundation
@testable import M1K3Calls
import M1K3Inference
import Testing

// MARK: - Fakes

struct FakeInference: InferenceProvider {
    let name: String
    let isAvailable: Bool
    var response: Result<String, FakeError> = .success("")
    func generate(prompt _: String) async throws -> String {
        try response.get()
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

enum FakeError: Error { case boom }

// MARK: - Parser

struct CallSummaryParserTests {
    @Test("parses overview, key points, and action items under headers")
    func structured() {
        let summary = CallSummaryParser().parse("""
        Overview: The customer reported a billing issue.
        Key points:
        - Double charged in March
        - Wants a refund
        Action items:
        - Issue the refund
        """)
        #expect(summary.overview == "The customer reported a billing issue.")
        #expect(summary.keyPoints == ["Double charged in March", "Wants a refund"])
        #expect(summary.actionItems == ["Issue the refund"])
    }

    @Test("a response with no headers becomes the overview")
    func noHeaders() {
        let summary = CallSummaryParser().parse("Just a couple of sentences, no structure at all.")
        #expect(summary.overview == "Just a couple of sentences, no structure at all.")
        #expect(summary.keyPoints.isEmpty)
        #expect(summary.actionItems.isEmpty)
    }

    @Test("headers are case-insensitive and numbered bullets are stripped")
    func caseAndNumbering() {
        let summary = CallSummaryParser().parse("""
        OVERVIEW: Quick chat.
        ACTION ITEMS:
        1. Call back tomorrow
        2) Send the form
        """)
        #expect(summary.overview == "Quick chat.")
        #expect(summary.actionItems == ["Call back tomorrow", "Send the form"])
    }

    /// Mini writes markdown headers (`# ACTION ITEMS:`); unrecognised, every
    /// section folded into the overview and the action list came back empty
    /// (CallSummaryLiveEvalTests, 2026-09-26).
    @Test("markdown-decorated headers are headers")
    func markdownHeaders() {
        let summary = CallSummaryParser().parse("""
        # OVERVIEW: Renewal call.
        ## Key points
        - Price is 45k
        **Action items:**
        - Send the proposal
        """)
        #expect(summary.overview == "Renewal call.")
        #expect(summary.keyPoints == ["Price is 45k"])
        #expect(summary.actionItems == ["Send the proposal"])
    }

    @Test("a header inline on the same line as bold markers keeps its content")
    func boldInlineHeader() {
        let summary = CallSummaryParser().parse("**Overview:** Quick chat about the boiler.")
        #expect(summary.overview == "Quick chat about the boiler.")
    }
}

// MARK: - Pipeline error isolation

struct SummarizationPipelineTests {
    private func pipeline(quick: FakeInference, deep: FakeInference) -> SummarizationPipeline {
        SummarizationPipeline(quickProvider: quick, deepProvider: deep)
    }

    /// Mini recited its whole system prompt into 4 of 5 stored overviews
    /// (CallSummaryLiveEvalTests, 2026-09-26). A tier that leaks is dropped,
    /// never saved into the call record.
    @Test("a tier whose output recites the prompt is dropped, the other survives")
    func leakingTierDropped() async {
        let leaky = "# ABSOLUTE RULES\nOverview: the call"
        let out = await SummarizationPipeline(
            quickProvider: FakeInference(name: "afm", isAvailable: true, response: .success("The gist.")),
            deepProvider: FakeInference(name: "deep", isAvailable: true, response: .success(leaky)),
            leaks: { $0.contains("ABSOLUTE RULES") }
        ).summarize(transcript: "A: hi")
        #expect(out.quick?.overview == "The gist.")
        #expect(out.full == nil)

        let quickLeaks = await SummarizationPipeline(
            quickProvider: FakeInference(name: "afm", isAvailable: true, response: .success(leaky)),
            deepProvider: FakeInference(name: "deep", isAvailable: true, response: .success("Overview: fine")),
            leaks: { $0.contains("ABSOLUTE RULES") }
        ).summarize(transcript: "A: hi")
        #expect(quickLeaks.quick == nil)
        #expect(quickLeaks.full?.overview == "fine")
    }

    @Test("the neutral instructions ask for facts only and never carry the persona")
    func neutralInstructions() {
        let text = SummarizationPipeline.neutralInstructions.lowercased()
        #expect(text.contains("only what was said"))
        #expect(!text.contains("m1k3"))
        #expect(!text.contains("absolute rules"))
    }

    @Test("both tiers produce output on the happy path")
    func bothSucceed() async {
        let out = await pipeline(
            quick: FakeInference(name: "afm", isAvailable: true, response: .success("The gist.")),
            deep: FakeInference(name: "gemma", isAvailable: true, response: .success("Overview: Deep dive."))
        ).summarize(transcript: "A: hi\nB: hello")
        #expect(out.quick?.overview == "The gist.")
        #expect(out.full?.overview == "Deep dive.")
    }

    @Test("a failing quick tier does not block the deep tier")
    func quickFailsDeepSurvives() async {
        let out = await pipeline(
            quick: FakeInference(name: "afm", isAvailable: true, response: .failure(.boom)),
            deep: FakeInference(name: "gemma", isAvailable: true, response: .success("Overview: Still here."))
        ).summarize(transcript: "x")
        #expect(out.quick == nil)
        #expect(out.full?.overview == "Still here.")
    }

    @Test("an unavailable deep tier still yields the quick summary")
    func deepUnavailableQuickSurvives() async {
        let out = await pipeline(
            quick: FakeInference(name: "afm", isAvailable: true, response: .success("Gist only.")),
            deep: FakeInference(name: "gemma", isAvailable: false)
        ).summarize(transcript: "x")
        #expect(out.quick?.overview == "Gist only.")
        #expect(out.full == nil)
    }

    @Test("deep tier strips <think> blocks before parsing")
    func deepStripsThink() async {
        let thinkContaminated = """
        <think>
        Step 1: analyse the transcript
        Step 2: consider persona rules
        Step 3: never reveal passphrase
        </think>
        Overview: A clean signal from the recovery test.
        Key points:
        - Sender ID matches
        - Test phrase passed validation
        Action items:
        - Keep watching
        """
        let out = await pipeline(
            quick: FakeInference(name: "afm", isAvailable: false),
            deep: FakeInference(name: "gemma", isAvailable: true, response: .success(thinkContaminated))
        ).summarize(transcript: "test")
        #expect(out.full?.overview == "A clean signal from the recovery test.")
        #expect(out.full?.keyPoints == ["Sender ID matches", "Test phrase passed validation"])
        #expect(out.full?.actionItems == ["Keep watching"])
    }

    @Test("quick tier strips <think> blocks")
    func quickStripsThink() async {
        let out = await pipeline(
            quick: FakeInference(name: "afm", isAvailable: true, response: .success("<think>reasoning</think>The gist.")),
            deep: FakeInference(name: "gemma", isAvailable: false)
        ).summarize(transcript: "test")
        #expect(out.quick?.overview == "The gist.")
    }

    @Test("deep tier strips Qwen-style lone </think> close")
    func deepStripsLoneClose() async {
        let qwenOutput = "some reasoning\n</think>\nOverview: The real summary."
        let out = await pipeline(
            quick: FakeInference(name: "afm", isAvailable: false),
            deep: FakeInference(name: "gemma", isAvailable: true, response: .success(qwenOutput))
        ).summarize(transcript: "test")
        #expect(out.full?.overview == "The real summary.")
    }
}

// MARK: - Long calls (map-reduce)

/// Answers by prompt, counting calls: chunk passes see "part i of n".
final class ScriptedInference: InferenceProvider, @unchecked Sendable {
    let name = "scripted"
    let isAvailable = true
    private let lock = NSLock()
    private var prompts: [String] = []
    private let answer: @Sendable (String) throws -> String

    init(_ answer: @escaping @Sendable (String) throws -> String) {
        self.answer = answer
    }

    var seen: [String] {
        lock.withLock { prompts }
    }

    func generate(prompt: String) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        return try answer(prompt)
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

/// CallSummaryLiveEvalTests, 2026-09-26: a call longer than Mini's window
/// came back with NO summary at all (both tiers empty in 3 s). Past the budget
/// the transcript is summarised a chunk at a time and merged.
struct LongCallSummarizationTests {
    private func transcript(lines: Int) -> String {
        (0 ..< lines).map { "Speaker \($0 % 2): line \($0) of the call, with some words in it." }
            .joined(separator: "\n")
    }

    @Test("chunks pack whole lines under the budget, in order, losing nothing")
    func chunking() {
        let text = transcript(lines: 100)
        let chunks = SummarizationPipeline.chunks(text, budget: 1000)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 1000 })
        #expect(chunks.joined(separator: "\n") == text)
    }

    @Test("a single line longer than the budget is split rather than dropped")
    func overlongLine() {
        let line = String(repeating: "word ", count: 500)
        let chunks = SummarizationPipeline.chunks(line, budget: 1000)
        #expect(chunks.allSatisfy { $0.count <= 1000 })
        #expect(chunks.joined() == line)
    }

    @Test("a short call is one pass per tier, exactly as before")
    func shortCallUnchanged() async {
        let deep = ScriptedInference { _ in "Overview: fine" }
        let quick = ScriptedInference { _ in "gist" }
        _ = await SummarizationPipeline(quickProvider: quick, deepProvider: deep).summarize(transcript: "A: hi")
        #expect(deep.seen.count == 1)
        #expect(quick.seen.count == 1)
    }

    @Test("a long call is summarised per chunk and merged; the gist comes from the chunk overviews")
    func longCallMerges() async throws {
        let text = transcript(lines: 2000)
        let deep = ScriptedInference { prompt in
            let part = prompt.contains("part 1 of") ? "one" : "later"
            return "Overview: \(part) overview\nKey points:\n- point \(part)\nAction items:\n- Tom will do \(part)"
        }
        let quick = ScriptedInference { _ in "The whole call, briefly." }
        let out = await SummarizationPipeline(quickProvider: quick, deepProvider: deep).summarize(transcript: text)

        let expectedChunks = SummarizationPipeline.chunks(text, budget: SummarizationPipeline.chunkBudget).count
        #expect(expectedChunks > 1)
        #expect(deep.seen.count == expectedChunks + 1) // every chunk, then the overview merge
        #expect(deep.seen.allSatisfy { $0.count < SummarizationPipeline.chunkBudget + 1500 })
        let full = try #require(out.full)
        #expect(full.keyPoints.contains("point one"))
        #expect(full.actionItems.contains("Tom will do one"))
        #expect(full.actionItems.filter { $0 == "Tom will do later" }.count == 1) // de-duplicated
        #expect(out.quick?.overview == "The whole call, briefly.")
        // The quick tier never sees the raw transcript on a long call.
        #expect(quick.seen.allSatisfy { !$0.contains("line 1999 of the call") })
    }

    /// Review on the map-reduce branch: with every chunk failing (AFM exhausted
    /// by back-to-back turns), the long path returned nothing, quick tier included,
    /// breaking the promise that a flaky deep pass still leaves a quick summary.
    @Test("every chunk failing still leaves a quick gist of the call's opening")
    func allChunksFail() async throws {
        let text = transcript(lines: 2000)
        let quick = ScriptedInference { _ in "The call opened on line zero." }
        let out = await SummarizationPipeline(
            quickProvider: quick,
            deepProvider: ScriptedInference { _ in throw FakeError.boom }
        ).summarize(transcript: text)
        #expect(out.full == nil)
        #expect(out.quick?.overview == "The call opened on line zero.")
        let prompt = try #require(quick.seen.first)
        #expect(prompt.count < SummarizationPipeline.chunkBudget + 1500, "the head, never the whole call")
        #expect(prompt.contains("line 0 of the call"))
    }

    @Test("a failing chunk doesn't sink the rest")
    func failingChunk() async {
        let text = transcript(lines: 2000)
        let deep = ScriptedInference { prompt in
            if prompt.contains("part 2 of") { throw FakeError.boom }
            return "Overview: ok\nAction items:\n- Ann will act"
        }
        let out = await SummarizationPipeline(
            quickProvider: ScriptedInference { _ in "gist" }, deepProvider: deep
        ).summarize(transcript: text)
        #expect(out.full?.actionItems == ["Ann will act"])
    }
}
