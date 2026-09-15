//
//  RemoteLiveEvalTests.swift
//  M1K3ChatTests
//
//  The frontier ceiling: hosted models through the SAME fixtures, scorer and
//  document the on-device columns use, via OpenRouter. OFF unless
//  `M1K3_REMOTE_EVAL=1`, never in CI (no key there, and the point is a column
//  on the brains page, not a gate).
//
//  Why it exists: a scoreboard of four local brains says nothing about how far
//  the ladder reaches. Putting Claude, GPT, Gemini, DeepSeek, Qwen and the
//  hosted Gemma beside Mini and Lil, under M1K3's own persona and ReAct floor,
//  turns "how good is a 4B model at this" into a distance, and it tells us
//  which failures are the fixture's or the scaffolding's (every model fails
//  them) and which are the model's.
//
//  Same arms as MiniLiveEvalTests: bare kinds call the provider directly; with
//  `M1K3_REMOTE_EVAL_LIVE=1` every kind (and tool-use) runs the live
//  AgentRAGResponder over the stub palette. Models run concurrently (each is a
//  network round-trip; latency is per call, unaffected), fixtures in order
//  within a model.
//
//      OPEN_ROUTER_API_KEY=… M1K3_REMOTE_EVAL=1 M1K3_REMOTE_EVAL_LIVE=1 \
//      M1K3_REMOTE_EVAL_MODELS=anthropic/claude-opus-5,google/gemini-3.8-flash \
//      M1K3_REMOTE_EVAL_KINDS=security,open-chat M1K3_REMOTE_EVAL_OUT=/path/run.json \
//      swift test --filter RemoteLiveEvalTests
//
//  What leaves the machine: the persona (public, in this repo), the synthetic
//  fixture prompts, and the stub palette's canned observations. Nothing from a
//  store, a memory or a user.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 (the fixtures,
//  scorer and document are the harness's own; the wire is pinned by
//  OpenRouterWireTests; the live path differs from the app's only in the
//  embedder, which an empty store never consults). Prior: Unknown
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
@testable import M1K3Eval
import M1K3Inference
import M1K3Knowledge
import Synchronization
import Testing

private let evalEnvironment = ProcessInfo.processInfo.environment

/// A live-path call that failed before any text — surfaced as the score's reason.
private struct RemoteCallFailed: Error, CustomStringConvertible {
    let description: String
}

/// The names of the tools one live turn called, in order.
private final class ToolRecorder: Sendable {
    private let names = Mutex<[String]>([])
    func record(_ name: String) {
        names.withLock { $0.append(name) }
    }

    var captured: [String] {
        names.withLock { $0 }
    }
}

/// The harness's stub tool, rebuilt here (the app's is private to its target).
private struct StubTool: AgentTool {
    let spec: ChatEvalStubSpec
    var recorder: ToolRecorder?
    var name: String {
        spec.name
    }

    var description: String {
        spec.description
    }

    var parameters: [ToolParameter] {
        spec.parameter.map { [ToolParameter(name: $0.name, description: $0.description)] } ?? []
    }

    func execute(input: [String: String]) async throws -> ToolResult {
        recorder?.record(spec.name)
        let value = spec.parameter.flatMap { input[$0.name] } ?? input.values.first ?? ""
        return ToolResult(output: spec.output(for: value, hard: false))
    }
}

@Suite(.enabled(if: evalEnvironment["M1K3_REMOTE_EVAL"] == "1"), .serialized)
struct RemoteLiveEvalTests {
    private static var liveAll: Bool {
        evalEnvironment["M1K3_REMOTE_EVAL_LIVE"] == "1"
    }

    private static var repeats: Int {
        max(1, evalEnvironment["M1K3_REMOTE_EVAL_REPEATS"].flatMap(Int.init) ?? 1)
    }

    /// A pause between calls to the same model, so a burst never reads as a rate
    /// limit on the transcript.
    private static var paceMS: Int {
        max(0, evalEnvironment["M1K3_REMOTE_EVAL_PACE_MS"].flatMap(Int.init) ?? 250)
    }

    private static var models: [String] {
        (evalEnvironment["M1K3_REMOTE_EVAL_MODELS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static var kindNames: [String] {
        let raw = evalEnvironment["M1K3_REMOTE_EVAL_KINDS"] ?? "security,open-chat"
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static var kinds: Set<TaskKind> {
        Set(kindNames.compactMap(TaskKind.init(rawValue:)))
    }

    /// Same set the Mini runner mirrors, so the columns compare like for like.
    private static var supportedKinds: Set<TaskKind> {
        let bare: Set<TaskKind> = [
            .openChat, .security, .refusal, .reasoning, .codeGen, .worldKnowledge,
            .humour, .interview, .instructionFollowing, .document, .sycophancy,
        ]
        return liveAll ? bare.union([.toolUse]) : bare
    }

    @Test("hosted models through the eval fixtures, one column per model")
    func run() async throws {
        let key = try #require(evalEnvironment["OPEN_ROUTER_API_KEY"], "OPEN_ROUTER_API_KEY is not set")
        try #require(!key.isEmpty, "OPEN_ROUTER_API_KEY is empty — nine columns of 401s is not a run")
        // The persona goes to third parties: the standard composition is the one door a user
        // profile has, and a plain test process never sets one. Make that a promise.
        try #require(M1K3Persona.userProfile == nil, "a user profile is set in this process; nothing about the user leaves")
        try #require(!Self.models.isEmpty, "M1K3_REMOTE_EVAL_MODELS names no model")
        let unknown = Self.kindNames.filter { TaskKind(rawValue: $0) == nil }
        try #require(unknown.isEmpty, "unknown kinds: \(unknown)")
        try #require(!Self.kinds.isEmpty, "M1K3_REMOTE_EVAL_KINDS names no kind")
        let unsupported = Self.kinds.subtracting(Self.supportedKinds)
        try #require(unsupported.isEmpty, "not mirrored here: \(unsupported.map(\.rawValue).sorted())")

        let runs = await withTaskGroup(of: (Int, ChatEvalReport.BrainRun).self) { group in
            for (index, model) in Self.models.enumerated() {
                group.addTask {
                    let provider = OpenRouterProvider(model: model, key: key, system: M1K3Persona.systemPrompt)
                    let scores = await Self.column(provider: provider)
                    return (index, ChatEvalReport.BrainRun(brainID: provider.name, modelID: model, scores: scores))
                }
            }
            var collected: [(Int, ChatEvalReport.BrainRun)] = []
            for await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        print(ChatEvalReport.matrix(runs))
        if let out = evalEnvironment["M1K3_REMOTE_EVAL_OUT"] {
            let url = URL(fileURLWithPath: out)
            // Nine paid columns must not die on a missing folder at the last line.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let document = ChatEvalDocument(provenance: Self.provenance(), runs: runs)
            try ChatEvalReport.json(document).write(to: url)
        }
    }

    /// Every selected fixture, `repeats` times, through one model — printed as
    /// it lands, prefixed with the column so interleaved models still read.
    private static func column(provider: OpenRouterProvider) async -> [ChatEvalScore] {
        var scores: [ChatEvalScore] = []
        var paced = false
        for trial in 0 ..< repeats {
            for fixture in ChatEvalFixtures.all where kinds.contains(fixture.kind) {
                if paced { try? await Task.sleep(for: .milliseconds(paceMS)) }
                paced = true
                let score = await runFixture(fixture, provider: provider).withRepeatIndex(trial)
                scores.append(score)
                print("[\(provider.name) · trial \(trial + 1)/\(repeats)] " + score.rendered)
            }
        }
        return scores
    }

    private static func runFixture(_ fixture: ChatEvalFixture, provider: OpenRouterProvider) async -> ChatEvalScore {
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Int {
            let parts = (clock.now - start).components
            return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let raw: String
            var toolCalls: [String] = []
            if fixture.kind == .openChat || liveAll {
                let recorder = ToolRecorder()
                let tools: [any AgentTool] = ChatEvalStubPalette.specs.map {
                    StubTool(spec: $0, recorder: recorder)
                }
                let responder = try AgentRAGResponder(
                    store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
                    tools: tools, maxIterations: 3
                )
                var text = ""
                for await piece in try await responder.answerStreaming(fixture.prompt).stream {
                    text = StreamFold.fold(current: text, chunk: piece) // snapshot or delta, folded the same
                }
                toolCalls = recorder.captured
                if text.isEmpty, toolCalls.isEmpty, let failure = provider.streamFailure.take() {
                    throw RemoteCallFailed(description: failure) // "ran — …", not "0 chars"
                }
                raw = text.isEmpty && !toolCalls.isEmpty ? "tools used: \(toolCalls.joined(separator: ","))" : text
            } else {
                raw = try await provider.generate(prompt: fixture.prompt)
            }
            let observation = EvalObservation(rawText: raw, toolCalls: toolCalls, latencyMS: elapsed())
            return ChatEvalScorer.score(fixture: fixture, observation: observation, latencyCeilingMS: 120_000)
        } catch {
            return ChatEvalScore(
                fixtureID: fixture.id, kind: fixture.kind,
                checks: [EvalCheck(
                    name: "ran", outcome: .fail, detail: String(describing: error).prefix(70).description
                )],
                latencyMS: elapsed()
            )
        }
    }

    private static func provenance() -> EvalProvenance {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return EvalProvenance(
            date: ISO8601DateFormatter().string(from: Date()),
            hardware: "hosted via OpenRouter (client: " + (evalEnvironment["M1K3_REMOTE_EVAL_HARDWARE"] ?? "unknown") + ")",
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion) (client)",
            appCommit: evalEnvironment["M1K3_REMOTE_EVAL_COMMIT"],
            mlxSwiftLMRevision: nil,
            powerMode: nil,
            powerSource: nil,
            // The stamp names the ARM, not one kind: without LIVE=1 only open-chat runs the
            // responder, and a run stamped live over bare cells would mislead the page.
            livePath: liveAll,
            repeats: repeats,
            notes: "arm: full persona as the system message"
                + (liveAll ? " · every kind on the live responder" : " · bare generate; open-chat alone on the live responder")
                + " · remote models, latency is a network round-trip not a decode · models: "
                + models.joined(separator: ", ")
                + (evalEnvironment["M1K3_REMOTE_EVAL_NOTES"].map { " · " + $0 } ?? "")
        )
    }
}
