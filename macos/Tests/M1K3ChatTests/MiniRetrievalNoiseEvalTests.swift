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
//  Review: Kev + claude-opus-5.5, 2026-10-29 — #447 (1.3.0): memories are scored apart from excerpts
//  (`memoryMarkers`; the 7/10 was memory noise, which #430's markers never counted); an empty answer is
//  an error, never clean (an AFM outage would read as a fix); the weekend control drops "run" (it matched
//  "brunch"); a sourdough recall control joins; a `+weave` suffix renders the old memory header, so the
//  wording change is paired against its baseline in one run; `M1K3_AFM_EVAL_NOISE_PROBES` filters probes;
//  and `blind` (M1K3_AFM_EVAL_NOISE_BLIND=1) runs MemoryEvalFixtures' 22 recall and 11 leak pairs, markers
//  written before any run, once, on the final wording. Confidence 0.7.
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

    /// Phrases that mean a noise EXCERPT was worked into the answer.
    static let noiseMarkers = ["nefarious", "recording calls", "tok/s", "decode", "benchmark", "ioreg", "subprocess", "scrape", "legal"]

    /// Phrases that mean a noise MEMORY was worked into the answer (#447's 7/10).
    static let memoryMarkers = ["galway", "dough nut", "sourdough", "trail"]

    /// The memory header's old clause and the one #447 ships. `+weave` arms render the old one.
    static let shippedClause = "Mention a fact only when it helps answer what they asked; "
    static let weaveClause = "Weave facts in naturally; "

    static let probes: [Probe] = [
        Probe(id: "battery", question: "How's my battery doing right now?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "whats-up", question: "what's up?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "joke", question: "tell me a joke", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "egg", question: "how long do I boil an egg for?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        Probe(id: "sky", question: "why is the sky blue?", chunks: noiseChunks, memories: noiseMemories, useMarkers: []),
        // A memory that answers: the plain turn keeps memories, so this must still land.
        Probe(
            id: "control-memory", question: "any ideas what I should do this weekend?",
            chunks: noiseChunks, memories: noiseMemories, useMarkers: ["trail", "galway", "sourdough", "dough nut"]
        ),
        // Recall: the memory IS the answer, so the new clause must not hold it back.
        Probe(
            id: "control-recall", question: "what's my sourdough starter called?",
            chunks: noiseChunks, memories: noiseMemories, useMarkers: ["dough nut"]
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

    /// Probe ids to run (`M1K3_AFM_EVAL_NOISE_PROBES`), all when unset.
    private static var probeFilter: Set<String>? {
        noiseEvalEnvironment["M1K3_AFM_EVAL_NOISE_PROBES"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    private static var repeats: Int {
        max(1, noiseEvalEnvironment["M1K3_AFM_EVAL_REPEATS"].flatMap(Int.init) ?? 2)
    }

    private static var paceMS: Int {
        max(0, noiseEvalEnvironment["M1K3_AFM_EVAL_PACE_MS"].flatMap(Int.init) ?? 10000)
    }

    /// The plain-turn prompt for `arm`. A `+weave` suffix renders the memory header's pre-#447
    /// clause in place of the shipped one: the baseline, paired in the same run.
    static func prompt(question: String, chunks: [ChunkHit], memories: [ChunkHit], arm: String) -> String {
        let base = arm.replacingOccurrences(of: "+weave", with: "")
        let budget = HistoryBudgetPolicy.budget(
            for: .mini,
            reservedTokens: HistoryBudgetPolicy.liveReserveTokens,
            generationTokens: HistoryBudgetPolicy.liveGenerationReserveTokens
        )
        let rendered = AgentRAGResponder.plainTurnPrompt(
            question: question, contextPreamble: PromptContext.identity(brainName: "Mini"),
            chunks: base == "shipping" || base == "nomemories" ? chunks : [],
            memories: base == "shipping" || base == "nochunks" || base == "blind" ? memories : [],
            history: [], historyBudget: budget, ambient: nil, todos: nil
        )
        guard arm.hasSuffix("+weave"), rendered.contains("WHAT I KNOW ABOUT YOU") else { return rendered }
        precondition(rendered.contains(shippedClause), "the memory header moved: re-point shippedClause")
        return rendered.replacingOccurrences(of: shippedClause, with: weaveClause)
    }

    static func prompt(_ probe: Probe, arm: String) -> String {
        prompt(question: probe.question, chunks: probe.chunks, memories: probe.memories, arm: arm)
    }

    /// One paced AFM turn; nil when Mini answered nothing (an error, never a clean answer).
    private static func answer(
        _ prompt: String, provider: AppleFoundationModelsProvider, paced: inout Bool
    ) async throws -> String? {
        if paced { try await Task.sleep(for: .milliseconds(paceMS)) }
        paced = true
        var stream = PlainTurnStream()
        var text = ""
        for await chunk in provider.generateStreaming(prompt: prompt) {
            if let clean = stream.ingest(chunk) { text = clean }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @Test("irrelevant grounding per arm")
    func run() async throws {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
        let probes = Self.probes.filter { Self.probeFilter?.contains($0.id) ?? true }
        struct Row { var memory = 0, excerpt = 0, n = 0, empty = 0, used: [String: (Int, Int)] = [:] }
        var tally: [String: Row] = [:]
        var paced = false
        for trial in 0 ..< Self.repeats {
            for probe in probes {
                for arm in Self.arms {
                    // The seal's answer is an excerpt: meaningless where excerpts are off.
                    if probe.id == "control-seal", arm.hasPrefix("nochunks") || arm.hasPrefix("none") { continue }
                    var row = tally[arm, default: Row()]
                    let prompt = Self.prompt(probe, arm: arm)
                    guard let text = try await Self.answer(prompt, provider: provider, paced: &paced) else {
                        row.empty += 1
                        tally[arm] = row
                        print("[t\(trial + 1) \(probe.id) \(arm)] EMPTY (an error, not a clean answer)")
                        continue
                    }
                    let lower = text.lowercased()
                    let memory = Self.memoryMarkers.filter { lower.contains($0) }
                    let excerpt = Self.noiseMarkers.filter { lower.contains($0) }
                    let used = probe.useMarkers.contains { lower.contains($0) }
                    if probe.useMarkers.isEmpty {
                        row.n += 1
                        row.memory += memory.isEmpty ? 0 : 1
                        row.excerpt += excerpt.isEmpty ? 0 : 1
                    } else {
                        let (hits, n) = row.used[probe.id, default: (0, 0)]
                        row.used[probe.id] = (hits + (used ? 1 : 0), n + 1)
                    }
                    tally[arm] = row
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    let tag = "[t\(trial + 1) \(probe.id) \(arm)]"
                    print("\(tag) memory=\(memory) excerpt=\(excerpt) used=\(used) :: \(flat)")
                }
            }
        }
        for arm in Self.arms {
            let row = tally[arm, default: Row()]
            let controls = row.used.keys.sorted()
                .map { "\($0) \(row.used[$0]!.0)/\(row.used[$0]!.1)" }.joined(separator: " · ")
            print(
                "ARM \(arm): memory noise \(row.memory)/\(row.n) · excerpt noise \(row.excerpt)/\(row.n)"
                    + " · empty \(row.empty) · \(controls)"
            )
        }
    }

    // MARK: - Blind set (#447): run ONCE, on the final wording

    /// Markers written before any run, per pair: a positive must recall one; a negative must
    /// mention none. MemoryEvalFixtures was written on 06-12 for the retrieval floors and never
    /// used to tune wording.
    static let recallMarkers: [[String]] = [
        ["aoife"], ["metric"], ["cork"], ["collie"], ["dyslex"], ["grdb"], ["round tower"], ["vim"], ["black"],
        ["1987"], ["niamh"], ["macos", "mac first", "mac,"], ["thursday"], ["penicillin"], ["march"],
        ["british", "en-gb", "uk "], ["skoda", "octavia"], ["development"], ["ucc", "university college cork"],
        ["m1k3"], ["emoji"], ["september"],
    ]
    static let leakMarkers: [[String]] = [
        ["aoife", "sister"], ["metric"], ["coffee"], ["bran", "collie", "your dog"], ["football", "thursday"],
        ["1987"], ["skoda", "octavia"], ["penicillin", "allerg"], ["ucc", "computer science"],
        ["development", "project notes"], ["round tower"],
    ]

    @Test(
        "blind: recall holds and nothing new leaks",
        .enabled(if: noiseEvalEnvironment["M1K3_AFM_EVAL_NOISE_BLIND"] == "1")
    )
    func blind() async throws {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
        #expect(Self.recallMarkers.count == MemoryEvalFixtures.positives.count)
        #expect(Self.leakMarkers.count == MemoryEvalFixtures.negatives.count)
        let arms = ["blind", "blind+weave"]
        var recalled: [String: Int] = [:], leaked: [String: Int] = [:], empty: [String: Int] = [:]
        var paced = false
        let sets = [
            (MemoryEvalFixtures.positives, Self.recallMarkers, true),
            (MemoryEvalFixtures.negatives, Self.leakMarkers, false),
        ]
        for (pairs, markers, recall) in sets {
            for (index, pair) in pairs.enumerated() {
                let memory = [Self.chunk(pair.memory, pair.memory, kind: .memory)]
                for arm in arms {
                    let prompt = Self.prompt(question: pair.query, chunks: [], memories: memory, arm: arm)
                    guard let text = try await Self.answer(prompt, provider: provider, paced: &paced) else {
                        empty[arm, default: 0] += 1
                        print("[\(recall ? "recall" : "leak") \(index) \(arm)] EMPTY")
                        continue
                    }
                    let hit = markers[index].contains { text.lowercased().contains($0) }
                    if recall {
                        recalled[arm, default: 0] += hit ? 1 : 0
                    } else {
                        leaked[arm, default: 0] += hit ? 1 : 0
                    }
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    print("[\(recall ? "recall" : "leak") \(index) \(arm)] hit=\(hit) :: \(flat)")
                }
            }
        }
        for arm in arms {
            print(
                "BLIND \(arm): recalled \(recalled[arm, default: 0])/22 · leaked \(leaked[arm, default: 0])/11"
                    + " · empty \(empty[arm, default: 0])"
            )
        }
    }
}
