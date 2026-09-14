//
//  MiniLiveEvalTests.swift
//  M1K3ChatTests
//
//  Mini (Apple Foundation Models) through the eval fixtures from a plain test
//  process — the same fixtures, scorer and JSON document the SelfTest CHATEVAL
//  stage writes. OFF unless `M1K3_AFM_EVAL=1`, and never in CI (no Apple
//  Intelligence there).
//
//  Why this exists: on macOS 27.0 (2026-09-14) an unsandboxed, re-signed copy
//  of the app bundle — the only way a shell can read a SelfTest report since
//  app-data privacy closed the container — reads `SystemLanguageModel` as
//  unavailable, while a plain process on the same Mac reads it available. So the
//  app-bundle harness can no longer run Mini headlessly; this can.
//
//  Kinds: bare-generate kinds (security, refusal, …) call the provider directly,
//  like the harness's closed-book arm. `open-chat` runs the LIVE path — the real
//  AgentRAGResponder over the stub tool palette, so the ReAct floor, the RULES and
//  the persona-carrying check all run — with the hashing embedder over an empty
//  in-memory store (the harness's closed book; retrieval finds nothing either way).
//
//      M1K3_AFM_EVAL=1 M1K3_AFM_EVAL_PERSONA=trimmed|full M1K3_AFM_EVAL_REPEATS=3 \
//      M1K3_AFM_EVAL_KINDS=security,open-chat M1K3_AFM_EVAL_OUT=/path/run.json \
//      swift test --filter MiniLiveEvalTests
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 (the fixtures, scorer
//  and document are the harness's own; the live path differs from the app's only
//  in the embedder, which an empty store never consults for a hit). Prior: Unknown
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
@testable import M1K3Eval
import M1K3Inference
import M1K3Knowledge
import Testing

private let evalEnvironment = ProcessInfo.processInfo.environment

/// A stand-in tool: records nothing, returns the fixture palette's canned
/// observation — the harness's `StubTool`, rebuilt here because that one is
/// private to the app target.
private struct StubTool: AgentTool {
    let spec: ChatEvalStubSpec
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
        let value = spec.parameter.flatMap { input[$0.name] } ?? input.values.first ?? ""
        return ToolResult(output: spec.output(for: value, hard: false))
    }
}

@Suite(.enabled(if: evalEnvironment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct MiniLiveEvalTests {
    private static var fullPersona: Bool {
        evalEnvironment["M1K3_AFM_EVAL_PERSONA"] == "full"
    }

    private static var repeats: Int {
        max(1, evalEnvironment["M1K3_AFM_EVAL_REPEATS"].flatMap(Int.init) ?? 1)
    }

    /// Pause between fixtures: back-to-back AFM turns rate-collapse the daemon
    /// into empty answers, and an empty answer can't leak — it would flatter
    /// the security score (memory: afm-daemon-falls-over-under-rapid-turns).
    private static var paceMS: Int {
        max(0, evalEnvironment["M1K3_AFM_EVAL_PACE_MS"].flatMap(Int.init) ?? 2500)
    }

    private static var kinds: Set<TaskKind> {
        let raw = evalEnvironment["M1K3_AFM_EVAL_KINDS"] ?? "security,open-chat"
        return Set(raw.split(separator: ",").compactMap { TaskKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    @Test("Mini through the eval fixtures, one arm per run")
    func run() async throws {
        let provider = Self.fullPersona
            ? AppleFoundationModelsProvider(instructions: { M1K3Persona.systemPrompt })
            : AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
        let tools: [any AgentTool] = ChatEvalStubPalette.specs.map { StubTool(spec: $0) }
        var scores: [ChatEvalScore] = []
        for trial in 0 ..< Self.repeats {
            for fixture in ChatEvalFixtures.all where Self.kinds.contains(fixture.kind) {
                let score = await Self.runFixture(fixture, provider: provider, tools: tools)
                scores.append(score.withRepeatIndex(trial))
                print("[trial \(trial + 1)/\(Self.repeats)] " + score.rendered)
                try await Task.sleep(for: .milliseconds(Self.paceMS))
            }
        }
        let run = ChatEvalReport.BrainRun(brainID: "mini", scores: scores)
        print(ChatEvalReport.matrix([run]))
        if let out = evalEnvironment["M1K3_AFM_EVAL_OUT"] {
            let document = ChatEvalDocument(provenance: Self.provenance(), runs: [run])
            try ChatEvalReport.json(document).write(to: URL(fileURLWithPath: out))
        }
    }

    private static func runFixture(
        _ fixture: ChatEvalFixture, provider: AppleFoundationModelsProvider, tools: [any AgentTool]
    ) async -> ChatEvalScore {
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Int {
            let parts = (clock.now - start).components
            return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let raw: String
            if fixture.kind == .openChat {
                let responder = try AgentRAGResponder(
                    store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
                    tools: tools, maxIterations: 3
                )
                var text = ""
                for await piece in try await responder.answerStreaming(fixture.prompt).stream {
                    text += piece
                }
                raw = text
            } else {
                raw = try await provider.generate(prompt: fixture.prompt)
            }
            return ChatEvalScorer.score(
                fixture: fixture, observation: EvalObservation(rawText: raw, latencyMS: elapsed()),
                latencyCeilingMS: 120_000
            )
        } catch {
            return ChatEvalScore(
                fixtureID: fixture.id, kind: fixture.kind,
                checks: [EvalCheck(name: "ran", outcome: .fail, detail: String(describing: error).prefix(70).description)],
                latencyMS: elapsed()
            )
        }
    }

    private static func provenance() -> EvalProvenance {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return EvalProvenance(
            date: ISO8601DateFormatter().string(from: Date()),
            hardware: evalEnvironment["M1K3_AFM_EVAL_HARDWARE"] ?? "unknown",
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)",
            appCommit: evalEnvironment["M1K3_AFM_EVAL_COMMIT"],
            mlxSwiftLMRevision: nil,
            powerMode: evalEnvironment["M1K3_AFM_EVAL_POWERMODE"].flatMap(Int.init),
            powerSource: evalEnvironment["M1K3_AFM_EVAL_POWER_SOURCE"],
            livePath: kinds.contains(.openChat),
            repeats: repeats,
            notes: (fullPersona ? "arm: full persona" : "arm: trimmed persona (miniSystemPrompt)")
                + " · plain test process (swift test), not the app bundle"
                + (evalEnvironment["M1K3_AFM_EVAL_NOTES"].map { " · " + $0 } ?? "")
        )
    }
}
