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
//  `M1K3_AFM_EVAL_LIVE=1` sends EVERY kind through the live responder, and admits
//  `tool-use` (the stub tools record what the loop called). That is the arm a
//  change to the ReAct prompt itself must pass: the bare arm never sees it.
//  Each line also prints the first streamed piece's time — what the user waits
//  for — beside the whole turn's.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 (the fixtures, scorer
//  and document are the harness's own; the live path differs from the app's only
//  in the embedder, which an empty store never consults for a hit). Prior: Unknown
//
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 — the live arm for every
//  kind (M1K3_AFM_EVAL_LIVE=1) + live tool-use + first-token timing, for the
//  stable-first ReAct prompt's gate. The app harness has only ever scored Mini's
//  tools through Apple's own tool loop or the bare agent, never the responder.
//  Review: Kev + claude-fable-5.1, 2026-09-15 — chunks fold (StreamFold) instead of
//  appending, and `livePath` stamps the arm, not the open-chat exception (local review).
//  Review: Kev + claude-opus-5-5, 2026-09-26 — `M1K3_AFM_EVAL_TOOLS=none` runs the live
//  turn with an empty palette: the tool-router A/B (scratch/laya-spike). Confidence 0.85.
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

/// A stand-in tool: returns the fixture palette's canned observation and, when
/// given a recorder, notes that it ran — the harness's `StubTool`, rebuilt here
/// because that one is private to the app target.
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

@Suite(.enabled(if: evalEnvironment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct MiniLiveEvalTests {
    private static var fullPersona: Bool {
        evalEnvironment["M1K3_AFM_EVAL_PERSONA"] == "full"
    }

    /// Every kind through the live responder (see the header).
    private static var liveAll: Bool {
        evalEnvironment["M1K3_AFM_EVAL_LIVE"] == "1"
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

    private static var kindNames: [String] {
        let raw = evalEnvironment["M1K3_AFM_EVAL_KINDS"] ?? "security,open-chat"
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static var kinds: Set<TaskKind> {
        Set(kindNames.compactMap(TaskKind.init(rawValue:)))
    }

    /// The kinds this runner mirrors the harness for. grounded-Q needs a seeded
    /// store, and tool-use a recorder only the live arm wires; asking for either
    /// where it can't run must fail, not silently run it as a bare generation.
    private static var supportedKinds: Set<TaskKind> {
        let bare: Set<TaskKind> = [
            .openChat, .security, .refusal, .reasoning, .codeGen, .worldKnowledge,
            .humour, .interview, .instructionFollowing, .document, .sycophancy,
        ]
        return liveAll ? bare.union([.toolUse]) : bare
    }

    @Test("Mini through the eval fixtures, one arm per run")
    func run() async throws {
        // A typo'd kind would otherwise vanish and leave an empty (or narrower) run.
        let unknown = Self.kindNames.filter { TaskKind(rawValue: $0) == nil }
        try #require(unknown.isEmpty, "unknown kinds: \(unknown)")
        try #require(!Self.kinds.isEmpty, "M1K3_AFM_EVAL_KINDS names no kind")
        let unsupported = Self.kinds.subtracting(Self.supportedKinds)
        try #require(unsupported.isEmpty, "not mirrored here: \(unsupported.map(\.rawValue).sorted())")
        let provider = Self.fullPersona
            ? AppleFoundationModelsProvider(instructions: { M1K3Persona.systemPrompt })
            : AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
        var scores: [ChatEvalScore] = []
        var firstPieces: [TaskKind: [Int]] = [:]
        var paced = false
        for trial in 0 ..< Self.repeats {
            for fixture in ChatEvalFixtures.all where Self.kinds.contains(fixture.kind) {
                // Pace BETWEEN turns only: no wait before the first or after the last.
                if paced { try await Task.sleep(for: .milliseconds(Self.paceMS)) }
                paced = true
                let (score, firstMS) = await Self.runFixture(fixture, provider: provider)
                scores.append(score.withRepeatIndex(trial))
                if let firstMS { firstPieces[fixture.kind, default: []].append(firstMS) }
                let first = firstMS.map { " · first \($0)ms" } ?? ""
                print("[trial \(trial + 1)/\(Self.repeats)] " + score.rendered + first)
            }
        }
        let run = ChatEvalReport.BrainRun(brainID: "mini", scores: scores)
        print(ChatEvalReport.matrix([run]))
        for (kind, times) in firstPieces.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sorted = times.sorted()
            print("first piece \(kind.rawValue): median \(sorted[sorted.count / 2])ms n=\(sorted.count) all=\(sorted)")
        }
        if let out = evalEnvironment["M1K3_AFM_EVAL_OUT"] {
            let document = ChatEvalDocument(provenance: Self.provenance(), runs: [run])
            try ChatEvalReport.json(document).write(to: URL(fileURLWithPath: out))
        }
    }

    /// One fixture, scored, plus the first streamed piece's time on the live arm
    /// (nil on the bare arm, which does not stream).
    private static func runFixture(
        _ fixture: ChatEvalFixture, provider: AppleFoundationModelsProvider
    ) async -> (ChatEvalScore, Int?) {
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Int {
            let parts = (clock.now - start).components
            return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let raw: String
            var toolCalls: [String] = []
            var firstMS: Int?
            if fixture.kind == .openChat || liveAll {
                let recorder = ToolRecorder()
                // `M1K3_AFM_EVAL_TOOLS=none`: the same live turn with nothing on offer,
                // what a tool router's "no tools" verdict would hand Mini.
                let tools: [any AgentTool] = evalEnvironment["M1K3_AFM_EVAL_TOOLS"] == "none"
                    ? []
                    : ChatEvalStubPalette.specs.map { StubTool(spec: $0, recorder: recorder) }
                let responder = try AgentRAGResponder(
                    store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
                    tools: tools
                )
                var text = ""
                for await piece in try await responder.answerStreaming(fixture.prompt).stream {
                    if firstMS == nil, !piece.isEmpty { firstMS = elapsed() }
                    text = StreamFold.fold(current: text, chunk: piece) // AFM yields snapshots; fold, don't append
                }
                toolCalls = recorder.captured
                // A tool turn that concluded with nothing still made its call — the
                // harness's rendering, so the scorer reads the same shape.
                raw = text.isEmpty && !toolCalls.isEmpty ? "tools used: \(toolCalls.joined(separator: ","))" : text
            } else {
                raw = try await provider.generate(prompt: fixture.prompt)
            }
            let observation = EvalObservation(rawText: raw, toolCalls: toolCalls, latencyMS: elapsed())
            return (ChatEvalScorer.score(fixture: fixture, observation: observation, latencyCeilingMS: 120_000), firstMS)
        } catch {
            let score = ChatEvalScore(
                fixtureID: fixture.id, kind: fixture.kind,
                checks: [EvalCheck(
                    name: "ran", outcome: .fail, detail: String(describing: error).prefix(70).description
                )],
                latencyMS: elapsed()
            )
            return (score, nil)
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
            livePath: liveAll, // the ARM; open-chat alone on the responder is named in the notes
            repeats: repeats,
            notes: (fullPersona ? "arm: full persona" : "arm: trimmed persona (miniSystemPrompt)")
                + (liveAll ? " · every kind on the live responder" : " · bare generate; open-chat alone on the live responder")
                + " · plain test process (swift test), not the app bundle"
                + (evalEnvironment["M1K3_AFM_EVAL_NOTES"].map { " · " + $0 } ?? "")
        )
    }
}
