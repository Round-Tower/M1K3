//
//  MiniRetrievalNoiseEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL_NOISE=1`, app quit): does Mini's plain turn work irrelevant
//  retrieval into its answer? 375 over MCP (2026-09-27, #430): "How's my battery doing right
//  now?" came back with a stored note about calls recorded "nefariously", an old decode
//  benchmark and an unrequested Python script. Retrieval returns the least-bad match for any
//  question; the KNOWLEDGE head says "may be irrelevant — ignore the rest" and Mini works it
//  in anyway.
//
//  Each probe runs the shipping plain-turn prompt (`plainTurnPrompt`) with noise excerpts and
//  noise memories that don't answer it; one control carries an excerpt that does, so a fix
//  that kills real grounding shows up. Arms (`M1K3_AFM_EVAL_NOISE_ARMS`):
//    shipping      chunks + memories, as today
//    nochunks      memories only (the router sends document questions to search_knowledge)
//    nomemories    chunks only
//    none          no grounding at all
//
//  Pace ≥ 10 s: the AFM daemon falls over under back-to-back turns.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.7 (marker scoring over a small
//  probe set; every hit is read by hand). Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

private let noiseEvalEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: noiseEvalEnvironment["M1K3_AFM_EVAL_NOISE"] == "1"), .serialized)
struct MiniRetrievalNoiseEvalTests {
    struct Probe {
        let id: String
        let question: String
        let chunks: [ChunkHit]
        let memories: [ChunkHit]
        /// Words only the relevant excerpt could supply (the control); empty for noise probes.
        let useMarkers: [String]
    }

    static func chunk(_ title: String, _ content: String, kind: KnowledgeKind = .document) -> ChunkHit {
        ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: title, kind: kind, heading: nil, content: content)
    }

    /// The 375 case's shape: a call note, a benchmark, a script. None answers anything below.
    static let noiseChunks = [
        chunk("Call notes, 12 September", "People are recording calls and claiming it's 'nefariously' done; ask legal about consent banners.", kind: .note),
        chunk("MLX decode benchmark", "Qwen3-4B DWQ decode 41.2 tok/s on M1 Max, prefill 812 tok/s; gemma-12B 14.8 tok/s."),
        chunk("scrape.py", "import subprocess\nout = subprocess.run(['ioreg', '-rn', 'AppleSmartBattery'], capture_output=True)\nprint(out.stdout)"),
    ]

    static let noiseMemories = [
        chunk("About the user", "The user is into trail running and did the Galway half in 2025.", kind: .memory),
        chunk("About the user", "The user keeps sourdough starter called Dough Nut.", kind: .memory),
    ]

    /// Phrases that mean a noise item was worked into the answer.
    static let noiseMarkers = ["nefarious", "recording calls", "tok/s", "decode", "benchmark", "ioreg", "subprocess", "scrape", "legal"]

    static let probes: [Probe] = [
        Probe(id: "battery", question: "How's my battery doing right now?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "whats-up", question: "what's up?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "joke", question: "tell me a joke", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "egg", question: "how long do I boil an egg for?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "sky", question: "why is the sky blue?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        // A memory that answers: the plain turn keeps memories, so this must still land.
        Probe(
            id: "control-memory", question: "any ideas what I should do this weekend?",
            chunks: noiseChunks, memories: noiseMemories, useMarkers: ["run", "trail", "sourdough", "dough nut"]
        ),
        Probe(
            id: "control-seal",
            question: "what did I write down about the conveyor seal?",
            chunks: [chunk("Plant notes", "The conveyor's hydraulic seal failed under load at 180 bar; replace with the Viton part.")]
                + noiseChunks.prefix(1),
            memories: noiseMemories, useMarkers: ["180", "viton", "hydraulic"]
        ),
    ]

    private static var arms: [String] {
        (noiseEvalEnvironment["M1K3_AFM_EVAL_NOISE_ARMS"] ?? "shipping,nochunks,none")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static var repeats: Int {
        max(1, noiseEvalEnvironment["M1K3_AFM_EVAL_REPEATS"].flatMap(Int.init) ?? 2)
    }

    private static var paceMS: Int {
        max(0, noiseEvalEnvironment["M1K3_AFM_EVAL_PACE_MS"].flatMap(Int.init) ?? 10000)
    }

    static func prompt(_ probe: Probe, arm: String) -> String {
        let budget = HistoryBudgetPolicy.budget(
            for: .mini,
            reservedTokens: HistoryBudgetPolicy.liveReserveTokens,
            generationTokens: HistoryBudgetPolicy.liveGenerationReserveTokens
        )
        return AgentRAGResponder.plainTurnPrompt(
            question: probe.question, contextPreamble: PromptContext.identity(brainName: "Mini"),
            chunks: arm == "shipping" || arm == "nomemories" ? probe.chunks : [],
            memories: arm == "shipping" || arm == "nochunks" ? probe.memories : [],
            history: [], historyBudget: budget, ambient: nil, todos: nil
        )
    }

    @Test("irrelevant grounding per arm")
    func run() async throws {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
        var tally: [String: (noise: Int, n: Int, used: Int, nControl: Int)] = [:]
        var paced = false
        for trial in 0 ..< Self.repeats {
            for probe in Self.probes {
                for arm in Self.arms {
                    if paced { try await Task.sleep(for: .milliseconds(Self.paceMS)) }
                    paced = true
                    var answer = PlainTurnStream()
                    var text = ""
                    for await chunk in provider.generateStreaming(prompt: Self.prompt(probe, arm: arm)) {
                        if let clean = answer.ingest(chunk) { text = clean }
                    }
                    let lower = text.lowercased()
                    let control = !probe.useMarkers.isEmpty
                    let noise = Self.noiseMarkers.filter { lower.contains($0) }
                    let used = probe.useMarkers.contains { lower.contains($0) }
                    var row = tally[arm, default: (0, 0, 0, 0)]
                    if control {
                        row.nControl += 1
                        row.used += used ? 1 : 0
                    } else {
                        row.n += 1
                        row.noise += noise.isEmpty ? 0 : 1
                    }
                    tally[arm] = row
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    print("[t\(trial + 1) \(probe.id) \(arm)] noise=\(noise) used=\(used) :: \(flat)")
                }
            }
        }
        for arm in Self.arms {
            let row = tally[arm, default: (0, 0, 0, 0)]
            print("ARM \(arm): noise in \(row.noise)/\(row.n) · control grounded \(row.used)/\(row.nControl)")
        }
    }
}
