//
//  SelfTest.swift
//  M1K3App
//
//  Headless on-device proof. `swift test` can't run MLX (the metallib only
//  resolves inside an .app bundle), so this runs the real pipeline FROM WITHIN
//  the built app, gated on M1K3_SELFTEST=1, and STREAMS each stage to stderr as
//  it completes (so a slow/hung stage still shows the earlier results), then
//  exits:
//
//      M1K3_SELFTEST=1 M1K3.app/Contents/MacOS/M1K3 2>report.log
//
//  The generation stage uses a model id from M1K3_SELFTEST_MODEL (default a small
//  cached model) so it proves the MLXLLM path without a fresh download — the
//  product default (gemma-3-1b QAT) can be slow to fetch on first run.
//
//  Uses an in-memory store so it never touches the real container — except
//  the MEMSTAT arm, which reads (never writes) the real container stores by
//  design: measuring the live graph is its whole point (MemStatStage.swift).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import M1K3LanguageModel
import M1K3MLX
import MLXEmbedders

/// Resolves self-test configuration from the environment FIRST, then a JSON
/// override file in the app's container — so a run can be driven WITHOUT
/// `open --env`, which silently fails to inject on repeat LaunchServices
/// launches of the shared `app.m1k3` bundle id (it works once, then boots the
/// app idle). Drop `~/Library/Containers/app.m1k3/Data/.m1k3-selftest.json` — a
/// flat `{"M1K3_SELFTEST": "1", …}` map keyed by env-var name — launch the app
/// normally, and the selftest reads its config off disk. Env always wins when
/// both are set, so existing `open --env` / Xcode-scheme runs are unchanged.
///
/// Signed: Kev + claude-opus-4-8, 2026-06-15, Confidence 0.85 (file fallback
/// sidesteps the open --env flake end-to-end; env precedence preserves every
/// existing run path). Prior: Unknown
enum SelfTestEnv {
    /// The on-disk override map, loaded once. Keys are env-var names; values are
    /// coerced to strings (JSON bools → "1"/"0", numbers → their text) so the
    /// config reads the same as the environment it shadows.
    static let fileOverrides: [String: String] = {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".m1k3-selftest.json")
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        // One-shot: consume the trigger the moment it's read, so an ordinary
        // relaunch (or a crash mid-run) never leaves the app selftest-booting.
        // Drop the file again to run again. Read happens once (cached static),
        // so deleting now doesn't affect the in-memory config below.
        try? FileManager.default.removeItem(atPath: path)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return [:] }
        var resolved: [String: String] = [:]
        for (key, raw) in dictionary {
            switch raw {
            case let bool as Bool: resolved[key] = bool ? "1" : "0"
            case let string as String: resolved[key] = string
            default: resolved[key] = "\(raw)"
            }
        }
        return resolved
    }()

    /// The environment value if present, else the on-disk override, else nil.
    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? fileOverrides[key]
    }
}

enum SelfTest {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST") == "1"
    }

    /// Where the streamed report goes. A bundled GUI .app sends stdio to the
    /// unified log, not an inherited fd — so we write to a file we can read back.
    private static var outputPath: String {
        SelfTestEnv.value("M1K3_SELFTEST_OUT") ?? "/tmp/m1k3_selftest.log"
    }

    private static func truncateOutput() {
        try? Data().write(to: URL(fileURLWithPath: outputPath))
    }

    /// Whole milliseconds in a Duration, for the TTFT probe lines.
    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Raw OS thermal + low-power reads, folded through the SAME
    /// `CoolHeadPolicy.target` the live app calls — so a memloop reading
    /// `.serious` reports "would cap to .eased" rather than a bare enum name
    /// the reader has to translate themselves.
    private static func thermalSnapshotDescription(label: String) -> String {
        let info = ProcessInfo.processInfo
        let level = CoolHeadPolicy.target(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
        return "\(label) thermal: state=\(info.thermalState) lowPower=\(info.isLowPowerModeEnabled) "
            + "coolHeadTarget=\(level)"
    }

    /// Append a line to the report file immediately so progress survives an
    /// interrupted run.
    private static func emit(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: outputPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    /// Run every backend end-to-end, emitting each result as it lands. Each stage
    /// is independently guarded so one failure (or stall) still reports the rest.
    static func run() async {
        truncateOutput()
        emit("=== M1K3 SELF-TEST (inside .app bundle) ===")

        // 1. Store + ingest + Hashing embed + AFM RAG.
        do {
            let store = try KnowledgeStore() // in-memory
            let hashing = HashingEmbeddingService()
            let ingester = DocumentIngester(store: store, embedder: hashing)
            try await ingester.ingest(
                title: "Plant Notes",
                text: "3.2 Seals\nThe hydraulic seal on the conveyor failed under load."
            )
            try emit("✓ store+ingest: \(store.chunkCount()) chunk, \(store.embeddingCount()) embedding(s)")

            let afm = AppleFoundationModelsProvider()
            emit("• AFM available: \(afm.isAvailable)")
            if afm.isAvailable {
                let rag = RAGResponder(store: store, embedder: hashing, provider: afm)
                let r = try await rag.answer("What failed on the conveyor?")
                emit("✓ AFM RAG answer: \(r.answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))")
                emit("  grounded in \(r.sources.count) source(s)")
            }
        } catch {
            emit("✗ store/AFM stage: \(error)")
        }

        // 2. MLX Qwen3-Embedding (Metal). The first embed on a fresh service is
        //    the COLD path (container load + kernel warm) — the exact tax
        //    warmEmbedderOnLaunch removes from the first chat turn's critical
        //    path (every turn embeds the query BEFORE retrieval + generation).
        //    cold − warm = the measured first-turn TTFT win (ledger 113-4).
        emit("• loading MLX Qwen3-Embedding (downloads on first use)…")
        do {
            let mlx = MLXEmbeddingService()
            let clock = ContinuousClock()
            let coldStart = clock.now
            let v = try await mlx.embed("hydraulic seal conveyor")
            let cold = clock.now - coldStart
            let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            emit("✓ MLX Qwen3-Embedding embed: dim=\(v.count) ‖v‖=\(String(format: "%.3f", norm))")
            // Warm cost: best of three, so one GC/thermal hiccup can't skew it.
            var warmBest: Duration?
            for _ in 1 ... 3 {
                let warmStart = clock.now
                _ = try await mlx.embed("hydraulic seal conveyor")
                let sample = clock.now - warmStart
                if warmBest.map({ sample < $0 }) ?? true { warmBest = sample }
            }
            let warm = warmBest ?? .zero
            emit("embedwarm: cold=\(milliseconds(cold))ms warm=\(milliseconds(warm))ms "
                + "delta=\(milliseconds(cold - warm))ms (delta = first-turn TTFT tax without the launch warm)")
        } catch {
            emit("✗ MLX embed stage: \(error)")
        }

        // 3. MLX generation (Metal). Uses a (likely cached) small model so the
        //    path is proven without a slow QAT download.
        let modelID = SelfTestEnv.value("M1K3_SELFTEST_MODEL")
            ?? "mlx-community/Llama-3.2-1B-Instruct-4bit"
        emit("• loading MLX generation model \(modelID)…")
        do {
            let llm = MLXGemmaProvider(modelID: modelID, maxTokens: 48)

            // 3-pre. Optional persona-prefix warm A/B (M1K3_SELFTEST_PREFIXWARM=1).
            // MUST run before ANY generation on this provider — turn A's whole
            // value is the COLD PersonaPrefixCache build. prepare() loads the
            // weights first so turn A isolates the prefix prefill from the
            // weights load (the app's model gate already absorbs the load, and
            // a launch prefix-warm would run post-load too). Same question both
            // turns, so delta(first token) is purely the prefix build cost —
            // the number the parked persona-prefix-warm decision needs.
            // Mode "2" is the bare-key API proof: warm FIRST through the
            // public warmPersonaPrefix entry (bare persona — the key the plain
            // generateStreaming path asks for), then the "cold" arm below must
            // land near the warm arm. Cold≈warm under mode 2 IS the pass.
            // Mode "3" is the TOOL-PATH proof — the path the production launch
            // warm actually targets: warm with tools passed deliberately OUT of
            // alphabetical order, then time the first native tool-turn send
            // (which derives its prefix through the same canonical-order choke
            // point). first-send ≈ second-send proves the warmed KV is the one
            // the live agent turn reuses, ordering included.
            let prefixMode = SelfTestEnv.value("M1K3_SELFTEST_PREFIXWARM")
            if prefixMode == "3" {
                try await llm.prepare(progress: { _ in })
                let toolsOutOfOrder = [
                    ToolDefinition(
                        name: "zeta_probe", description: "Report the zeta reading.",
                        parameters: [ToolParameterDefinition(name: "arg", description: "the arg")]
                    ),
                    ToolDefinition(
                        name: "alpha_probe", description: "Report the alpha reading.",
                        parameters: [ToolParameterDefinition(name: "arg", description: "the arg")]
                    ),
                ]
                await llm.warmPersonaPrefix(tools: toolsOutOfOrder)
                emit("prefixwarm: warmed via public API with out-of-order tools (mode 3)")
                for label in ["first-send", "second-send"] {
                    let session = try await llm.makeToolTurnSession(
                        tools: toolsOutOfOrder,
                        options: ToolTurnOptions(thinkingEnabled: false)
                    )
                    let clock = ContinuousClock()
                    let start = clock.now
                    // Safe: MLXToolTurnSession invokes onToken serially from
                    // inside container.perform, and `send` is awaited to
                    // completion before this var is read.
                    nonisolated(unsafe) var firstToken: Duration?
                    _ = try await session.send(
                        [.user("In one short sentence, what is a hydraulic seal?")]
                    ) { chunk in
                        if firstToken == nil, !chunk.isEmpty, chunk != "<think>" {
                            firstToken = clock.now - start
                        }
                    }
                    await session.finish()
                    let ms = firstToken.map { milliseconds($0) } ?? -1
                    emit("prefixwarm tool-path \(label): first=\(ms)ms")
                }
            }
            if prefixMode == "1" || prefixMode == "2" {
                try await llm.prepare(progress: { _ in })
                if prefixMode == "2" {
                    await llm.warmPersonaPrefix(tools: [])
                    emit("prefixwarm: warmed via public API before the A/B (mode 2)")
                }
                let question = "In one short sentence, what is a hydraulic seal?"
                var firsts: [Int] = []
                for label in ["cold", "warm"] {
                    let clock = ContinuousClock()
                    let start = clock.now
                    var firstToken: Duration?
                    for await chunk in llm.generateStreaming(prompt: question) {
                        if firstToken == nil, !chunk.isEmpty, chunk != "<think>" {
                            firstToken = clock.now - start
                        }
                    }
                    let ms = firstToken.map { milliseconds($0) } ?? -1
                    firsts.append(ms)
                    emit("prefixwarm \(label): first=\(ms)ms")
                }
                if firsts.count == 2, firsts.allSatisfy({ $0 >= 0 }) {
                    emit("prefixwarm delta=\(firsts[0] - firsts[1])ms "
                        + "(what a post-load persona-prefix warm buys the first turn)")
                }
            }

            let answer = try await llm.generate(prompt: "In one short sentence, what is a hydraulic seal?")
            emit("✓ MLX generate: \(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))")

            // Raw-output diagnostics (M1K3_SELFTEST_DEBUG=1): when an answer
            // comes back empty, show what the model ACTUALLY returned and how
            // the chat template rendered — distinguishes "model emitted EOS
            // immediately" from "detokenizer produced nothing".
            if SelfTestEnv.value("M1K3_SELFTEST_DEBUG") == "1" {
                emit("debug raw answer: count=\(answer.count) [\(answer.prefix(300))]")
                let debug = await llm.templateDebugDescription(
                    prompt: "In one short sentence, what is a hydraulic seal?"
                )
                emit("debug template: \(debug)")
            }

            // 3b. Optional memory loop (M1K3_SELFTEST_MEMLOOP=N): N more
            // generations with a footprint snapshot after each. An agent turn
            // runs generations back-to-back, so a growing footprint here is
            // exactly the unbounded-Metal-cache pathology; a flat one means the
            // budget holds.
            //
            // Also emits ProcessInfo.thermalState/isLowPowerModeEnabled per
            // iteration (2026-07-14, the gemma-4-12B-as-Big candidacy): the
            // reactive safety net (CoolHeadPolicy, live in
            // AppEnvironment+ChatHistory.swift) is model-agnostic, but nobody
            // has measured whether a bigger model's sustained decode actually
            // pushes THIS Mac into .serious/.critical faster than e4b did —
            // set M1K3_SELFTEST_MODEL to the candidate and a loop count long
            // enough to see a real thermal trajectory, not just RAM.
            if let loops = SelfTestEnv.value("M1K3_SELFTEST_MEMLOOP")
                .flatMap(Int.init), loops > 0
            {
                emit(MLXMemoryBudget.snapshotDescription(label: "memloop start"))
                emit(thermalSnapshotDescription(label: "memloop start"))
                for index in 1 ... loops {
                    _ = try await llm.generate(
                        prompt: "In two sentences, explain fact #\(index) about industrial conveyor maintenance."
                    )
                    emit(MLXMemoryBudget.snapshotDescription(label: "memloop gen \(index)"))
                    emit(thermalSnapshotDescription(label: "memloop gen \(index)"))
                }
            }

            // 3c. Optional TTFT probe (M1K3_SELFTEST_TTFT=1): wall-clock time
            // to first streamed token for a short prompt and a grounded-size
            // prompt — the A/B harness for prefill-cost changes. (Per-stage
            // prefill/decode metrics also land in the unified log, category
            // "ttft".)
            if SelfTestEnv.value("M1K3_SELFTEST_TTFT") == "1" {
                let grounded = String(
                    repeating: "KNOWLEDGE: conveyor belts run on rollers; hydraulic seals retain fluid under pressure; "
                        + "maintenance intervals follow load cycles. ",
                    count: 40
                ) + "\nIn one short sentence, what is a hydraulic seal?"
                let probes: [(String, String)] = [
                    ("short", "In one short sentence, what is a hydraulic seal?"),
                    ("grounded", grounded),
                ]
                for (label, prompt) in probes {
                    let clock = ContinuousClock()
                    let start = clock.now
                    var firstToken: Duration?
                    var characters = 0
                    for await chunk in llm.generateStreaming(prompt: prompt) {
                        // The synthetic <think> opener is emitted before any
                        // real generation — don't let it fake the first token.
                        if firstToken == nil, !chunk.isEmpty, chunk != "<think>" {
                            firstToken = clock.now - start
                        }
                        characters += chunk.count
                    }
                    let total = clock.now - start
                    let firstMS = firstToken.map { milliseconds($0) } ?? -1
                    emit("ttft \(label): first=\(firstMS)ms total=\(milliseconds(total))ms chars=\(characters)")
                }
            }

            await runKVPersistProbeIfRequested(llm: llm)

            // 3e. Optional persona-prefix invariant (M1K3_SELFTEST_PREFIX=1):
            // assert [cached system block] + [delta] == [full render] for this
            // model, and report the prefill tokens the cache saves. The safety
            // net for the Qwen two-probe boundary slice — and gemma's prefix too.
            if SelfTestEnv.value("M1K3_SELFTEST_PREFIX") == "1" {
                emit(await llm.personaPrefixInvariantProbe())
            }
        } catch {
            emit("✗ MLX generate stage: \(error)")
        }

        await runEvalSuiteIfRequested()

        // 5. Optional memory-threshold eval (M1K3_SELFTEST_MEMEVAL=1): embed
        //    the fixture pairs with the REAL BGE embedder and report the
        //    query→short-fact cosine distributions — the data that sets
        //    GroundingGate.memoryThreshold (the chunk bar was tuned on a
        //    different distribution; short facts sit lower in the cone).
        if SelfTestEnv.value("M1K3_SELFTEST_MEMEVAL") == "1" {
            await runMemoryThresholdEval()
        }

        // 6. Optional A/B separation eval (M1K3_SELFTEST_ABSEP=1): embed the
        //    in/off-domain fixtures with BOTH the old bge-small and the new
        //    qwen3-embed-512 and report which separates the classes wider.
        //    This is what justifies the embedder swap — measured, not trusted —
        //    and feeds the GroundingGate threshold re-tune.
        if SelfTestEnv.value("M1K3_SELFTEST_ABSEP") == "1" {
            await runSeparationEval()
        }

        // 6b. Optional query-style eval (M1K3_SELFTEST_KEYEVAL=1): the
        //    keyword-query gap instrument. Embeds the probe targets exactly as
        //    production stores them, then scores keyword and question queries
        //    in TWO arms — bare (today's behaviour) vs instructed
        //    (EmbeddingText.forQuery, Qwen3-Embedding's official asymmetric
        //    convention) — plus keyword-register noise, in one run. The data
        //    that decides whether the instruction ships and where the
        //    GroundingGate floors move (challenger doctrine: floors are
        //    re-DERIVED from the prefixed distributions, not assumed stable).
        if SelfTestEnv.value("M1K3_SELFTEST_KEYEVAL") == "1" {
            await runQueryStyleEval()
        }

        // 7. Optional chat-quality eval (M1K3_SELFTEST_CHATEVAL=1): run the
        //    task-kind fixtures against each brain through the REAL providers
        //    and score them with the pure M1K3Eval scorer — the cross-brain
        //    matrix that turns "AFM feels weaker at chat" into a number and
        //    becomes the EscalationLadder policy's evidence.
        if ChatEvalStage.isRequested {
            await ChatEvalStage.run(emit: emit)
        }

        // 8. Optional memory-graph integration eval (M1K3_SELFTEST_MEMGRAPH=1):
        //    drive the temporal memory store through the life-graph scenario
        //    against the REAL MLX embedder, including the `semantic` probes that
        //    only a real embedder can satisfy (paraphrase recall + discrimination)
        //    — the proof that recall works on MEANING, not just keyword overlap.
        if MemGraphEvalStage.isRequested {
            await MemGraphEvalStage.run(emit: emit)
        }

        // 8b. Optional dream-cycle Tier-0 census (M1K3_SELFTEST_MEMSTAT=1):
        //     read-only stats over the REAL container stores (live/kind/
        //     superseded counts, pairwise cosine histogram, corpus divergence)
        //     plus the contradiction/compatible/restatement probe pairs and
        //     the end-to-end eaten-correction ingest probe. The measurement
        //     that gates every dream-cycle tier — see scratch/dream-cycle/
        //     SPEC.md and MemStatStage.swift.
        if MemStatStage.isRequested {
            await MemStatStage.run(emit: emit)
        }

        // 8c. Optional dated-memory-block probe (M1K3_SELFTEST_MEMBLOCK=1):
        //     the Tier-1 dream-cycle verify — a seeded dated contradiction
        //     through the REAL responder on each brain; the recency prefix is
        //     the only signal separating the stale fact from the fresh one.
        //     See MemBlockProbeStage.swift.
        if MemBlockProbeStage.isRequested {
            await MemBlockProbeStage.run(emit: emit)
        }

        // 9. Optional Gemma-4 vision spike (M1K3_SELFTEST_VISION=1 +
        //    M1K3_SELFTEST_VISION_IMAGE=<path>): loads gemma-4-e4b through
        //    MLXVLM — NOT the production MLXLLM path MLXGemmaProvider uses,
        //    which strips vision weights at load — and reports whether it can
        //    actually see an image, the measured per-image token cost, and RAM
        //    with the vision tower resident. See GemmaVisionSpike.swift.
        if SelfTestEnv.value("M1K3_SELFTEST_VISION") == "1" {
            await runGemmaVisionSpike()
        }

        // 10. Optional MTP speculative-decoding spike (M1K3_SELFTEST_MTP=1):
        //     loads gemma-4-12B through MLXVLM (the only Gemma4 that emits
        //     drafter state) + the 238MB paired MTP drafter, then runs a
        //     greedy exact-match A/B (baseline vs speculative) across three
        //     sliding-window regimes. See GemmaMTPSpike.swift for the
        //     pre-registered questions (alias registration, accept rate /
        //     speedup, and the wrapped-window pollution probe).
        if SelfTestEnv.value("M1K3_SELFTEST_MTP") == "1" {
            await runGemmaMTPSpike()
        }

        // 11. Optional vision-chat probe (M1K3_SELFTEST_VISIONCHAT=1 +
        //     M1K3_SELFTEST_VISIONCHAT_IMAGE=<path>): an image through the
        //     REAL live path — AgentRAGResponder → LocalAgent native loop →
        //     MLXToolTurnSession → VLM-loaded Big — i.e. exactly what the
        //     composer's attach button sends. Proves the whole image seam
        //     (ToolMessage images → chat mapping → processor pixels) end to
        //     end, not just the spike-level ChatSession path.
        if SelfTestEnv.value("M1K3_SELFTEST_VISIONCHAT") == "1" {
            await runVisionChatProbe()
        }

        // 12. Optional prompt-size instrument (M1K3_SELFTEST_PROMPTSIZE=1):
        //     intercepts the REAL assembled prompt at the provider seam and
        //     counts it with the model's OWN tokenizer, broken down by section
        //     (history / knowledge / memories / rules / template). Closes the
        //     [SPIKE] named in HistoryBudgetPolicy — every context guarantee
        //     today rests on a char≈token estimate (3.5 there, 4 in
        //     DocumentChunker) that has never been checked, while the grounding
        //     block is interpolated verbatim against a "~1100" token reserve.
        //     See PromptSizeStage.swift.
        if PromptSizeStage.isRequested {
            await PromptSizeStage.run(emit: emit)
        }

        emit("=== END SELF-TEST ===")
    }

    /// The GemmaVisionSpike probe: two turns on one MLXVLM-loaded container
    /// (baseline text-only, then the same-shape question with an image
    /// attached), reporting the measured per-image prompt-token delta and a
    /// RAM snapshot with the vision tower resident (MLXLLM's load strips it —
    /// see docs/MODEL_CHOICES.md's 7.4GB figure, which was measured stripped).
    private static func runGemmaVisionSpike() async {
        guard let imagePath = SelfTestEnv.value("M1K3_SELFTEST_VISION_IMAGE") else {
            emit("✗ vision spike: M1K3_SELFTEST_VISION_IMAGE not set (path to a local image file)")
            return
        }
        let imageURL = URL(fileURLWithPath: imagePath)
        let modelID = SelfTestEnv.value("M1K3_SELFTEST_VISION_MODEL") ?? GemmaVisionSpike.defaultModelID
        emit("• vision spike: loading \(modelID) via MLXVLM (image: \(imageURL.lastPathComponent))…")
        do {
            let result = try await GemmaVisionSpike.run(imageURL: imageURL, modelID: modelID)
            emit("✓ vision spike baseline (\(result.baselinePromptTokens) prompt tokens): "
                + "\(result.baselineAnswer.prefix(180))")
            emit("✓ vision spike WITH IMAGE (\(result.visionPromptTokens) prompt tokens): "
                + "\(result.visionAnswer.prefix(180))")
            emit("vision spike: measured image token cost = \(result.imageTokenCost) tokens")
            emit(result.ramSnapshot)
        } catch {
            emit("✗ vision spike: \(error)")
        }
    }

    /// The vision-chat probe: one image + question through the production
    /// responder stack on Big. Empty in-memory store (closed book), the
    /// canned tool palette — the live-path CHATEVAL shape, plus an image.
    private static func runVisionChatProbe() async {
        guard let imagePath = SelfTestEnv.value("M1K3_SELFTEST_VISIONCHAT_IMAGE") else {
            emit("✗ visionchat: M1K3_SELFTEST_VISIONCHAT_IMAGE not set")
            return
        }
        let modelID = SelfTestEnv.value("M1K3_SELFTEST_VISIONCHAT_MODEL")
            ?? BrainTier.big.mlxModelID ?? ""
        emit("• visionchat: \(modelID) + \(imagePath) through AgentRAGResponder…")
        do {
            let provider = MLXGemmaProvider(modelID: modelID, name: "visionchat")
            let store = try KnowledgeStore()
            let responder = AgentRAGResponder(
                store: store, embedder: MLXEmbeddingService(), provider: provider,
                toolsProvider: { [] }, maxIterations: 3
            )
            let attachment = ImageAttachment(url: URL(fileURLWithPath: imagePath))
            let clock = ContinuousClock()
            let start = clock.now
            let (_, stream) = try await responder.answerStreaming(
                "In one or two short sentences, describe what you see in this image.",
                images: [attachment],
                history: [],
                onActivity: { _ in }
            )
            var answer = ""
            for await piece in stream {
                answer += piece
            }
            let ms = milliseconds(clock.now - start)
            let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(cleaned.isEmpty
                ? "✗ visionchat: EMPTY answer (\(ms)ms)"
                : "✓ visionchat (\(ms)ms): \(cleaned.prefix(300))")
        } catch {
            emit("✗ visionchat: \(error)")
        }
    }

    /// The GemmaMTPSpike probe: target + drafter through MLXVLM, three
    /// fixtures × two greedy legs each, reporting decode tok/s, draft
    /// accept rate, passthrough reason, the exact-match divergence index
    /// (speculative greedy MUST reproduce baseline greedy — divergence on
    /// the wrapped fixtures is the rejected-token pollution signal), and a
    /// RAM snapshot with both models resident.
    private static func runGemmaMTPSpike() async {
        let targetID = SelfTestEnv.value("M1K3_SELFTEST_MTP_MODEL") ?? GemmaMTPSpike.defaultTargetID
        let drafterID = SelfTestEnv.value("M1K3_SELFTEST_MTP_DRAFTER") ?? GemmaMTPSpike.defaultDrafterID
        emit("• mtp spike: target \(targetID) + drafter \(drafterID) via MLXVLM…")
        do {
            let result = try await GemmaMTPSpike.run(targetID: targetID, drafterID: drafterID)
            for f in result.fixtures {
                let accept = f.acceptRate.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
                let diverge = f.firstDivergenceIndex.map { "DIVERGES@\($0)" } ?? "exact-match"
                emit("✓ mtp \(f.label): prompt \(f.promptTokens)tok · "
                    + "baseline \(String(format: "%.1f", f.baselineTokensPerSecond))tok/s "
                    + "(\(f.baselineTokens)tok) vs mtp \(String(format: "%.1f", f.mtpTokensPerSecond))tok/s "
                    + "(\(f.mtpTokens)tok) = \(String(format: "%.2f", f.speedup))x · "
                    + "accept \(accept) (\(f.acceptedDraftTokens ?? 0)/\(f.proposedDraftTokens ?? 0)) · "
                    + "\(diverge)"
                    + (f.passthroughReason.map { " · passthrough: \($0)" } ?? ""))
                emit("  mtp \(f.label) baseline: \(f.baselineAnswer.prefix(160))")
                emit("  mtp \(f.label) mtp:      \(f.mtpAnswer.prefix(160))")
            }
            emit(result.ramSnapshot)
        } catch {
            emit("✗ mtp spike: \(error)")
        }
    }

    /// 4. Optional per-model eval suite (M1K3_SELFTEST_EVAL=1): the same
    /// behavioral checklist against every brain — or any ad-hoc list via
    /// M1K3_SELFTEST_EVAL_MODELS=id,id. Promotion gate for new models.
    private static func runEvalSuiteIfRequested() async {
        guard SelfTestEnv.value("M1K3_SELFTEST_EVAL") == "1" else { return }
        let models = SelfTestEnv.value("M1K3_SELFTEST_EVAL_MODELS")
            .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            ?? BrainTier.allCases.compactMap(\.mlxModelID)
        for modelID in models {
            emit("• eval \(modelID)…")
            let report = await evalModel(modelID)
            emit(report.rendered)
        }
    }

    /// 5. The MEMEVAL pass: one cosine per fixture pair, positives then
    /// negatives, then the distribution summary + suggested threshold. Each
    /// line lands in the OUT file as it's measured (interrupt-safe).
    private static func runMemoryThresholdEval() async {
        emit("• memeval: embedding \(MemoryEvalFixtures.positives.count) positive + "
            + "\(MemoryEvalFixtures.negatives.count) negative pairs…")
        do {
            let embedder = MLXEmbeddingService()
            let positiveScores = try await score(
                pairs: MemoryEvalFixtures.positives, label: "pos", embedder: embedder
            )
            let negativeScores = try await score(
                pairs: MemoryEvalFixtures.negatives, label: "neg", embedder: embedder
            )
            emit(MemoryEvalReport.render(positives: positiveScores, negatives: negativeScores))
        } catch {
            emit("✗ memeval: \(error)")
        }
    }

    /// Cosine per pair, emitted as measured so a crash mid-run loses nothing.
    private static func score(
        pairs: [MemoryEvalFixtures.Pair], label: String, embedder: MLXEmbeddingService
    ) async throws -> [Float] {
        let memoryVectors = try await embedder.embedBatch(pairs.map(\.memory))
        let queryVectors = try await embedder.embedBatch(pairs.map(\.query))
        var scores: [Float] = []
        for (index, pair) in pairs.enumerated() {
            let cosine = VectorMath.cosineSimilarity(queryVectors[index], memoryVectors[index])
            scores.append(cosine)
            let preview = String(pair.memory.prefix(40))
            emit(String(format: "memeval %@: %.3f [%@]", label, cosine, preview))
        }
        return scores
    }

    /// 6. The ABSEP pass: in/off-domain query→document cosines for the OLD
    /// (bge-small-384) and NEW (qwen3-embed-512) embedder, then the
    /// head-to-head margin verdict. The candidate must separate the classes at
    /// least as wide as bge, else the swap isn't justified (the ABSEP gate).
    private static func runSeparationEval() async {
        emit("• absep: \(SeparationEvalFixtures.inDomain.count) in-domain + "
            + "\(SeparationEvalFixtures.offDomain.count) off-domain pairs, bge-small-384 vs qwen3-embed-512…")
        do {
            // Old embedder stood up explicitly beside the new default — the init
            // params survived the default change precisely for this.
            let bge = MLXEmbeddingService(configuration: EmbedderRegistry.bge_small, dimension: 384)
            let candidate = MLXEmbeddingService() // new default = qwen3-embed-512

            let bgeIn = try await scoreSeparation(pairs: SeparationEvalFixtures.inDomain, label: "bge in", embedder: bge)
            let bgeOff = try await scoreSeparation(pairs: SeparationEvalFixtures.offDomain, label: "bge off", embedder: bge)
            let candIn = try await scoreSeparation(pairs: SeparationEvalFixtures.inDomain, label: "qwen3 in", embedder: candidate)
            let candOff = try await scoreSeparation(pairs: SeparationEvalFixtures.offDomain, label: "qwen3 off", embedder: candidate)

            let bgeResult = SeparationEvalReport.Result(label: "bge-small-384", inDomain: bgeIn, offDomain: bgeOff)
            let candidateResult = SeparationEvalReport.Result(label: "qwen3-embed-512", inDomain: candIn, offDomain: candOff)
            // candidate second → the head-to-head verdict describes it vs bge.
            emit(SeparationEvalReport.render([bgeResult, candidateResult]))
        } catch {
            emit("✗ absep: \(error)")
        }
    }

    /// Cosine per (query, document) pair, emitted as measured so a crash
    /// mid-run loses nothing.
    private static func scoreSeparation(
        pairs: [SeparationEvalFixtures.Pair], label: String, embedder: MLXEmbeddingService
    ) async throws -> [Float] {
        let queryVectors = try await embedder.embedBatch(pairs.map(\.query))
        let docVectors = try await embedder.embedBatch(pairs.map(\.document))
        var scores: [Float] = []
        for (index, pair) in pairs.enumerated() {
            let cosine = VectorMath.cosineSimilarity(queryVectors[index], docVectors[index])
            scores.append(cosine)
            emit(String(format: "absep %@: %.3f [%@]", label, cosine, String(pair.query.prefix(40))))
        }
        return scores
    }

    /// 6b. The KEYEVAL pass: every probe target embedded once (production
    /// composition via EmbeddingText.forChunk), then keyword / question /
    /// noise queries scored per arm — arm A bare, arm B through
    /// EmbeddingText.forQuery (the SAME composer a production embedQuery
    /// override would call; an inlined template here would measure a phantom).
    private static func runQueryStyleEval() async {
        emit("• keyeval: \(QueryStyleEvalFixtures.probes.count) probes + "
            + "\(QueryStyleEvalFixtures.noise.count) noise pairs, bare vs instructed query arms…")
        do {
            let embedder = MLXEmbeddingService()
            let targetVectors = try await embedder.embedBatch(QueryStyleEvalFixtures.probes.map {
                EmbeddingText.forChunk(title: $0.title, content: $0.content)
            })
            let noiseTargetVectors = try await embedder.embedBatch(QueryStyleEvalFixtures.noise.map {
                EmbeddingText.forChunk(title: $0.title, content: $0.content)
            })

            var arms: [QueryStyleEvalReport.Arm] = []
            // Arm A composes bare; arm B composes through EmbeddingText.forQuery
            // — the SAME composer MLXEmbeddingService.embedQuery calls (the
            // production query path since the 07-09 adoption), so the harness
            // measures the live seam's composition, with the before-arm kept
            // for the ongoing A/B.
            let armSpecs: [(label: String, compose: (String) -> String)] = [
                ("bare", { $0 }),
                ("instructed", EmbeddingText.forQuery),
            ]
            for spec in armSpecs {
                let keywordVectors = try await embedder.embedBatch(
                    QueryStyleEvalFixtures.probes.map { spec.compose($0.keyword) }
                )
                let questionVectors = try await embedder.embedBatch(
                    QueryStyleEvalFixtures.probes.map { spec.compose($0.question) }
                )
                let noiseVectors = try await embedder.embedBatch(
                    QueryStyleEvalFixtures.noise.map { spec.compose($0.keyword) }
                )
                var keyword: [Float] = []
                var question: [Float] = []
                var noise: [Float] = []
                for (index, probe) in QueryStyleEvalFixtures.probes.enumerated() {
                    let k = VectorMath.cosineSimilarity(keywordVectors[index], targetVectors[index])
                    let q = VectorMath.cosineSimilarity(questionVectors[index], targetVectors[index])
                    keyword.append(k)
                    question.append(q)
                    emit(String(
                        format: "keyeval %@ kw %.3f / q %.3f [%@]",
                        spec.label, k, q, String(probe.keyword.prefix(40))
                    ))
                }
                for (index, pair) in QueryStyleEvalFixtures.noise.enumerated() {
                    let n = VectorMath.cosineSimilarity(noiseVectors[index], noiseTargetVectors[index])
                    noise.append(n)
                    emit(String(
                        format: "keyeval %@ noise %.3f [%@]",
                        spec.label, n, String(pair.keyword.prefix(40))
                    ))
                }
                arms.append(.init(label: spec.label, keyword: keyword, question: question, noise: noise))
            }
            emit(QueryStyleEvalReport.render(
                arms,
                floors: [GroundingGate.memoryThreshold, GroundingGate.chunkThreshold]
            ))

            // Per-floor re-derivation data: the SAME fixture sets that
            // originally tuned each floor, re-scored with instructed queries.
            // memoryThreshold came from MEMEVAL (query→short-fact) and
            // chunkThreshold from ABSEP (query→chunk) — a floor move must cite
            // its own register's instructed distribution, not the mixed probes.
            for spec in armSpecs {
                let posQ = try await embedder.embedBatch(
                    MemoryEvalFixtures.positives.map { spec.compose($0.query) }
                )
                let posM = try await embedder.embedBatch(MemoryEvalFixtures.positives.map(\.memory))
                let negQ = try await embedder.embedBatch(
                    MemoryEvalFixtures.negatives.map { spec.compose($0.query) }
                )
                let negM = try await embedder.embedBatch(MemoryEvalFixtures.negatives.map(\.memory))
                let pos = zip(posQ, posM).map { VectorMath.cosineSimilarity($0, $1) }
                let neg = zip(negQ, negM).map { VectorMath.cosineSimilarity($0, $1) }
                emit("keyeval memeval[\(spec.label)]:")
                emit(MemoryEvalReport.render(positives: pos, negatives: neg))
            }
            var chunkArms: [SeparationEvalReport.Result] = []
            for spec in armSpecs {
                let inQ = try await embedder.embedBatch(
                    SeparationEvalFixtures.inDomain.map { spec.compose($0.query) }
                )
                let inD = try await embedder.embedBatch(SeparationEvalFixtures.inDomain.map(\.document))
                let offQ = try await embedder.embedBatch(
                    SeparationEvalFixtures.offDomain.map { spec.compose($0.query) }
                )
                let offD = try await embedder.embedBatch(SeparationEvalFixtures.offDomain.map(\.document))
                chunkArms.append(.init(
                    label: "chunks-\(spec.label)",
                    inDomain: zip(inQ, inD).map { VectorMath.cosineSimilarity($0, $1) },
                    offDomain: zip(offQ, offD).map { VectorMath.cosineSimilarity($0, $1) }
                ))
            }
            emit("keyeval absep arms:")
            emit(SeparationEvalReport.render(chunkArms))
        } catch {
            emit("✗ keyeval: \(error)")
        }
    }

    /// 3d. Optional prompt-cache persistence probe (M1K3_SELFTEST_KVPERSIST=1):
    /// persona-prefix KV → disk → reload → generate from the reloaded cache.
    /// The prototype gate for persisting PersonaPrefixCache across launches.
    private static func runKVPersistProbeIfRequested(llm: MLXGemmaProvider) async {
        guard SelfTestEnv.value("M1K3_SELFTEST_KVPERSIST") == "1" else { return }
        emit(await llm.promptCacheRoundTripProbe(
            directory: FileManager.default.temporaryDirectory
        ))
    }

    /// One model through the behavioral checklist. Self-contained on purpose:
    /// the reasoning-family detection reads the output itself (the provider's
    /// synthetic <think> opener IS the contract being checked), so a new model
    /// needs no eval-side configuration at all.
    private static func evalModel(_ modelID: String) async -> ModelEvalReport {
        var records: [ModelEvalRecord] = []
        // 2048, not the chat default: a reasoning model can spend 200–800
        // tokens inside <think> before the one-word answer the think-contract
        // check wants — 1024 risked false truncation FAILs on verbose models.
        let provider = MLXGemmaProvider(modelID: modelID, maxTokens: 2048)

        // Check 1+2: generates a usable answer; reasoning families emit a
        // well-formed think pair (the Qwen3.5 lone-close bug class).
        do {
            let raw = try await provider.generate(
                prompt: "Reply with exactly the word OK and nothing else."
            )
            let answer = ModelEvalReport.strippingThink(raw)
            let generated = answer.localizedCaseInsensitiveContains("ok")
            records.append(ModelEvalRecord(
                check: "generates",
                outcome: generated ? .pass : .fail,
                detail: generated ? "\(raw.count) chars" : "answer: \(answer.prefix(60))"
            ))
            if raw.hasPrefix("<think>") {
                let verdict = ThinkContract.verdict(raw: raw)
                records.append(ModelEvalRecord(
                    check: "think contract",
                    outcome: verdict.outcome,
                    detail: verdict.detail
                ))
            } else {
                records.append(ModelEvalRecord(
                    check: "think contract", outcome: .skip, detail: "not a reasoning family"
                ))
            }
        } catch {
            records.append(ModelEvalRecord(
                check: "generates", outcome: .fail, detail: String(describing: error).prefix(80) + ""
            ))
            return ModelEvalReport(modelID: modelID, records: records)
        }

        // Check 3: the native tool-call dialect actually round-trips — the
        // model SEES the tool (template renders it) and the library PARSES the
        // call (the Gemma-3n silent-drop + missing-parser bug class).
        if provider.supportsToolCalls {
            do {
                let datetime = ToolDefinition(
                    name: "datetime",
                    description: "Get the current date and time on this Mac.",
                    parameters: []
                )
                let turn = try await provider.continueToolTurn(
                    messages: [
                        .system(M1K3Persona.systemPrompt),
                        .user("What time is it right now? Use the datetime tool to find out."),
                    ],
                    tools: [datetime]
                )
                switch turn {
                case let .toolCalls(calls) where calls.contains(where: { $0.name == "datetime" }):
                    records.append(ModelEvalRecord(
                        check: "native tool call", outcome: .pass, detail: "datetime called"
                    ))
                case let .toolCalls(calls):
                    records.append(ModelEvalRecord(
                        check: "native tool call", outcome: .fail,
                        detail: "called \(calls.map(\.name).joined(separator: ",")) instead"
                    ))
                case let .text(text):
                    records.append(ModelEvalRecord(
                        check: "native tool call", outcome: .fail,
                        detail: "no call — answered: \(ModelEvalReport.strippingThink(text).prefix(60))"
                    ))
                }
            } catch {
                records.append(ModelEvalRecord(
                    check: "native tool call", outcome: .fail,
                    detail: String(describing: error).prefix(80) + ""
                ))
            }
        } else {
            records.append(ModelEvalRecord(
                check: "native tool call", outcome: .skip,
                detail: "ReAct floor — no native dialect at this pin"
            ))
        }

        // Check 4: needle recall across a few-thousand-token prompt — the only
        // check that exercises a LONG KV cache (8-bit quantized on allow-listed
        // families, rotation backstop elsewhere). Short prompts cannot catch
        // cache-quality loss.
        records.append(await evalLongContextRecall(provider: provider))

        return ModelEvalReport(modelID: modelID, records: records)
    }

    private static func evalLongContextRecall(provider: MLXGemmaProvider) async -> ModelEvalRecord {
        do {
            let raw = try await provider.generate(prompt: LongContextRecall.prompt())
            let answer = ModelEvalReport.strippingThink(raw)
            let recalled = LongContextRecall.passes(answer)
            return ModelEvalRecord(
                check: "long-context recall",
                outcome: recalled ? .pass : .fail,
                detail: recalled ? "needle recalled" : "answer: \(answer.prefix(60))"
            )
        } catch {
            return ModelEvalRecord(
                check: "long-context recall", outcome: .fail,
                detail: String(describing: error).prefix(80) + ""
            )
        }
    }
}
