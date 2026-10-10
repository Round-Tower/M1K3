//
//  ChatEvalStage.swift
//  M1K3App
//
//  The model-running half of the evals enclave (Phase 14). The PURE scoring
//  lives in M1K3Eval (fixtures, ChatEvalScorer, ChatEvalReport — all unit-
//  tested off-device); this stage runs each fixture against each real brain
//  from INSIDE the .app bundle (MLX needs the bundle's metallib, AFM needs the
//  entitlements — bare `swift test` can't), captures what the brain actually
//  produced, and feeds it to the pure scorer. Same harness as MEMEVAL/ABSEP.
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_CHATEVAL=1 M1K3.app/Contents/MacOS/M1K3
//      # narrow: M1K3_SELFTEST_CHATEVAL_BRAINS=mini,lil  M1K3_SELFTEST_CHATEVAL_KINDS=tool-use
//
//  Output: the cross-brain matrix (passed/total ⌀latency per task-kind) plus
//  per-fixture detail, written line-by-line to M1K3_SELFTEST_OUT so an
//  interrupted run keeps what it measured. The matrix is the evidence the
//  EscalationLadder policy cites — the AFM-vs-floor gap, in numbers.
//
//  Tool-use is scored through the REAL agent path each brain uses in
//  production: LocalAgent gives AFM (mini) the prompt-ReAct floor and MLX
//  brains their native dialect, and AgentResult.toolsUsed reads the same either
//  way — so mini's tool-calling shows up, it isn't skipped.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.82 (the runner is
//  verify-by-launch — its logic cores are the unit-tested M1K3Eval scorer and
//  the proven RAGResponder/LocalAgent seams; the wiring itself can only be
//  confirmed on-device). Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.8 — the stub palette
//  moved to M1K3Eval's ChatEvalStubPalette (pure, tested, pinned against the
//  fixtures) and gained fetch_page with a `url` parameter (#233); stubs now
//  advertise the parameter the production tool declares (datetime's ignored
//  `query`, lookup_fact's `topic`, fetch_page's `url`), and the AFM arm
//  builds a tool per argument shape. `document` + `sycophancy` kinds run on
//  the bare-generate arm. Verify-by-launch: one tool-use SelfTest per arm.
//  Review: Kev + claude-fable-5.1, 2026-09-10 — `EvalWindowArguments` + `AFMRecordingWindowTool`: the `window`
//  parameter shape for the recent_activity stub (afmArmCanExpressEveryParameter pins the name).
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 — M1K3_SELFTEST_CHATEVAL_MINI_PERSONA=full runs
//  Mini on the untrimmed prompt, so the 09-12 trim's gate (security x3, open-chat) is an A/B on one build.
//  Review: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 — the fixture loop is `evalProvider` (one loop for
//  every column); `M1K3_SELFTEST_CHATEVAL_PCC=1` adds Apple's Private Cloud Compute as a column behind the
//  entitlement (the adapter lives in M1K3Agent, `PrivateCloudInferenceAdapter`, where `swift test` reaches it);
//  the document rides stdout fenced when `M1K3_SELFTEST_OUT=-`; an empty live stream from a provider that
//  can name its failure scores as "ran — <reason>". Verify-by-launch: one PCC run (233/273, the same day).
//  Review: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 — the tool-router A/B on any brain, on the
//  live path: `M1K3_SELFTEST_CHATEVAL_TOOLS=none` empties the palette, `M1K3_SELFTEST_CHATEVAL_ROUTER=1`
//  fronts the turn with ToolNeedRouter's plain-chat route without the app's Mini-only gate (does Lil/Big gain?).
//  Review: same day — the switches are typed explicitly: the ternary closure crashed the type checker in
//  the app build ("failed to produce diagnostic"), which `swift test` never compiles.
//  Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.75 — `_ROUTER=dispatch` runs the app's own
//  route (ToolRouterWiring) with every tier and dispatch on, `_ROUTER_HEAD=1` adds the group head,
//  `_ROUTER_CHAIN=1` two-tool chains:
//  the arm `toolRouterAllTiers` owes before it defaults on. Verify-by-launch owed (the app build).
//  Review: Kev + claude-fable-5.1, 2026-09-29, Confidence 0.8 — an MLX override naming an imported
//  audition loads from its folder (AuditionStore), so `--model lil=<org/repo>` A/Bs anything imported.
//  Review: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.75 — the `vision` arm (GEMMA_1_1_PLAN Stream A):
//  the fixture's bundled PNGs ride the production `answerStreaming(_:images:…)` path; a provider that
//  can't take images scores n/a. Verify-by-launch owed: one run on mini + big (does AFM's agent path
//  keep the attachment? the blind markers will say).
//  Review: same day (critical pass) — `EvalThinkingPlan`: every arm thinks the way the app's tier does
//  (`M1K3_SELFTEST_CHATEVAL_THINKING=tier|always|fast`, default tier) and MLX brains get the tier's own
//  generation cap, not a flat 2048. The shootout had let Qwen3.5 think on every bare turn. Confidence 0.8.
//  Review: same day — the bake-off record: peak MLX memory per brain (`BrainRun.peakMemoryMB`, the RAM
//  gate) and `M1K3_SELFTEST_CHATEVAL_FULL_ANSWERS=1` for whole answers. Confidence 0.8.
//  Review: same day (#497 review fold) — `imageGap` says why it reads `BrainTier.mini` for AFM. The
//  own-peak number still charges the lazily-loaded embedder to the first brain of a multi-brain launch:
//  the bake-off runs one brain per launch.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#486) — the responder gets the Mac's age and egress clauses
//  (web on, PCC offered), so chat-what-leaves scores against what ships. The Lil/Big re-run is owed.
//  Review: Kev + claude-opus-5-5, 2026-10-10 — with a router mode set, tool-use takes the live path (it never
//  reached the router before: the 10-09 arm's tool-use column ran LocalAgent in every cell); `ROUTER=off` is that
//  path with no route; the turn records its tools (onActivity) and its pick stage. Confidence 0.75 (verify-by-
//  launch: the arm).
//  Review: Kev + claude-fable-5.1, 2026-10-10 — the think phase measured: `ThinkPhaseClock` on the live
//  stream (thinkMS), `thinkChars` on every score, and the `M1K3_SELFTEST_CHATEVAL_THINK_STEER` arm
//  (terse / emoji / softcap) as the responder's style clause.
//

import Foundation

// Weak-linked — see AppleFoundationModelsProvider for the full rationale: this
// stage's `@Generable EvalToolArguments` strong-references FoundationModels
// symbols an older OS seed than our SDK may not export, which would abort the
// archived app's launch on a skewed CI VM. Weak-linking lets it load; the AFM
// fixtures only run where the model is actually available.
@_weakLinked import FoundationModels
import M1K3Agent
import M1K3AgentTools
import M1K3Chat
import M1K3Eval
import M1K3Inference
import M1K3Knowledge
import M1K3LanguageModel
import M1K3LogCore
import M1K3MLX
import Synchronization

/// The free-text argument the query-taking eval tools take. `@Generable` gives
/// AFM the schema it needs to populate a native tool call.
@Generable
private struct EvalToolArguments {
    @Guide(description: "The query or input for the tool.")
    var query: String
}

/// The argument the page-reading stub takes (#233): a URL, not a query.
@Generable
private struct EvalURLArguments {
    @Guide(description: "The page URL, or a bare domain.")
    var url: String
}

/// The argument the fact-lookup stub takes: production WikipediaTool names it `topic`.
@Generable
private struct EvalTopicArguments {
    @Guide(description: "The topic or fact to look up.")
    var topic: String
}

/// The argument the recent_activity stub takes: production RecentActivityTool names it `window`.
@Generable
private struct EvalWindowArguments {
    @Guide(description: "The window to review: today, yesterday, N days, or week.")
    var window: String
}

/// Thread-safe record of which tools a brain actually invoked during one turn —
/// shared across the tool instances handed to a single AFM session.
private final class ToolCallRecorder: Sendable {
    private let names = Mutex<[String]>([])
    func record(_ name: String) {
        names.withLock { $0.append(name) }
    }

    var captured: [String] {
        names.withLock { $0 }
    }
}

/// An AFM-NATIVE tool (FoundationModels.Tool) whose `call` just records that the
/// model selected it and returns a canned observation — the eval measures tool
/// SELECTION, not execution. This is the path AFM uses when given real tools via
/// `LanguageModelSession(tools:)`, as opposed to the prompt-ReAct floor.
private struct AFMRecordingTool: FoundationModels.Tool {
    typealias Arguments = EvalToolArguments
    typealias Output = String

    let name: String
    let description: String
    let spec: ChatEvalStubSpec
    let hard: Bool
    let recorder: ToolCallRecorder

    func call(arguments: EvalToolArguments) async throws -> String {
        recorder.record(name)
        // Echo the query so the canned output reads as relevant to THIS request —
        // a fixed mismatched answer makes AFM auto-loop the tool until its context
        // window overflows (a 7-minute thrash). A query-aware, terminal result
        // lets the model conclude after one call.
        return spec.output(for: arguments.query, hard: hard)
    }
}

private struct AFMRecordingURLTool: FoundationModels.Tool {
    typealias Arguments = EvalURLArguments
    typealias Output = String

    let name: String
    let description: String
    let spec: ChatEvalStubSpec
    let hard: Bool
    let recorder: ToolCallRecorder

    func call(arguments: EvalURLArguments) async throws -> String {
        recorder.record(name)
        return spec.output(for: arguments.url, hard: hard)
    }
}

private struct AFMRecordingTopicTool: FoundationModels.Tool {
    typealias Arguments = EvalTopicArguments
    typealias Output = String

    let name: String
    let description: String
    let spec: ChatEvalStubSpec
    let hard: Bool
    let recorder: ToolCallRecorder

    func call(arguments: EvalTopicArguments) async throws -> String {
        recorder.record(name)
        return spec.output(for: arguments.topic, hard: hard)
    }
}

private struct AFMRecordingWindowTool: FoundationModels.Tool {
    typealias Arguments = EvalWindowArguments
    typealias Output = String

    let name: String
    let description: String
    let spec: ChatEvalStubSpec
    let hard: Bool
    let recorder: ToolCallRecorder

    func call(arguments: EvalWindowArguments) async throws -> String {
        recorder.record(name)
        return spec.output(for: arguments.window, hard: hard)
    }
}

/// One AFM tool per stub spec, in the argument shape the spec declares. The
/// set of names is pinned by `afmArmCanExpressEveryParameter` in M1K3EvalTests
/// — a new parameter name must add a shape here AND there.
private func afmTool(for spec: ChatEvalStubSpec, hard: Bool, recorder: ToolCallRecorder) -> any FoundationModels.Tool {
    switch spec.parameter?.name {
    case "url":
        AFMRecordingURLTool(name: spec.name, description: spec.description, spec: spec, hard: hard, recorder: recorder)
    case "topic":
        AFMRecordingTopicTool(name: spec.name, description: spec.description, spec: spec, hard: hard, recorder: recorder)
    case "window":
        AFMRecordingWindowTool(name: spec.name, description: spec.description, spec: spec, hard: hard, recorder: recorder)
    default:
        AFMRecordingTool(name: spec.name, description: spec.description, spec: spec, hard: hard, recorder: recorder)
    }
}

enum ChatEvalStage {
    /// Fixture boundaries, so time spent OUTSIDE a turn is attributable.
    /// See M1K3Log.Category.eval for the 177-second silence that motivated it.
    private static let evalLog = M1K3Log.logger(.eval)

    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL") == "1"
    }

    /// Stand-in tools the tool-use fixtures probe for. The eval measures whether
    /// the brain SELECTS the right tool — not what the tool returns — so execute
    /// is a no-op that hands back a plausible canned observation (enough for the
    /// agent to conclude and stop). Descriptions are faithful so selection is
    /// realistic: search_knowledge = personal store, lookup_fact = encyclopedic,
    /// web_search = live web.
    private struct StubTool: AgentTool {
        let name: String
        let description: String
        let parameters: [ToolParameter]
        let spec: ChatEvalStubSpec
        let hard: Bool

        init(spec: ChatEvalStubSpec, hard: Bool) {
            name = spec.name
            description = spec.description
            parameters = spec.parameter.map { [ToolParameter(name: $0.name, description: $0.description)] } ?? []
            self.spec = spec
            self.hard = hard
        }

        func execute(input: [String: String]) async throws -> ToolResult {
            let value = spec.parameter.flatMap { input[$0.name] } ?? input.values.first ?? ""
            return ToolResult(output: spec.output(for: value, hard: hard))
        }
    }

    // The palette itself is pure data in M1K3Eval (`ChatEvalStubPalette`) so
    // the fixtures are pinned against it — a fixture naming a tool no stub
    // offers is unpassable for every brain (#233, tool-read-site for two months).

    /// When set, tool stubs return NON-RESOLVING outputs (see `hardCanned`) — the
    /// Phase-15 hard case. Independent of the path flag so the Apple-driven loop
    /// can be run on hard stubs too (to capture its melt for contrast).
    private static var hardStubs: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_HARD_STUBS") == "1"
    }

    /// THE SPIKE (Phase 15): route AFM tool-use through LocalAgent's native loop
    /// over our structured @Generable `continueToolTurn`, under LocalAgent's cap.
    private static var afmNativeTools: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_AFM_NATIVE_TOOLS") == "1"
    }

    /// Force AFM onto the prompt-ReAct floor (A/B against the other two paths).
    private static var forceReActFloor: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_AFM_REACT") == "1"
    }

    /// The Mini persona A/B (M1K3_SELFTEST_CHATEVAL_MINI_PERSONA=full): Mini
    /// runs on the untrimmed standard prompt, FOLLOW-UPS included, the shape it
    /// shipped before the 2026-09-12 trim. Unset runs the provider's default,
    /// the trimmed `miniSystemPrompt`. One build measures both arms, so the
    /// trim's gate is same-session and same-power.
    private static var miniFullPersona: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_MINI_PERSONA") == "full"
    }

    /// ReAct-floor / native-dialect palette (LocalAgent path — AFM ReAct + MLX).
    /// Internal (not private): PromptSizeStage reuses this SAME palette so its
    /// measured prompt carries the real production tool spec, not an empty one.
    static var toolPalette: [any AgentTool] {
        ChatEvalStubPalette.specs.map { StubTool(spec: $0, hard: hardStubs) }
    }

    /// LIVE-PATH arm (M1K3_SELFTEST_CHATEVAL_LIVE_PATH=1): open-chat and
    /// code-gen fixtures run through AgentRAGResponder — the SAME prompt stack
    /// the chat UI assembles every turn (retrieve-first grounding head + RULES
    /// incl. the generative carve-out + the agent loop with tools) — instead of
    /// bare `provider.generate`. The bare arm isolates the persona; this arm
    /// measures what a user actually gets. Motivated 2026-07-15: the bare
    /// code-gen arm scored green while live chat was reported deflecting
    /// code asks — the gap between the two arms IS the scaffolding's cost.
    /// Tools are the deterministic canned stubs (same palette as tool-use), so
    /// a run never touches the network; the store is fresh in-memory and empty
    /// (closed book, same as the bare arm).
    private static var livePathRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_LIVE_PATH") == "1"
    }

    private static func livePathObservation(
        _ fixture: ChatEvalFixture, images: [ImageAttachment] = [], provider: any InferenceProvider,
        thinking: EvalThinkingPlan, start: ContinuousClock.Instant, clock: ContinuousClock
    ) async throws -> EvalObservation {
        // path: nil → in-memory GRDB, fresh per fixture (the groundedObservation
        // pattern). Empty on purpose: retrieval finds nothing, so the prompt
        // carries the live "No stored knowledge was injected" head — the exact
        // shape a closed-book code ask meets in production.
        let store = try KnowledgeStore()
        // The tool-router A/B on any brain (2026-09-26): `_TOOLS=none` empties the
        // palette; `_ROUTER=1` puts the shipping router and its plain-chat route in
        // front WITHOUT the app's Mini-only gate, to measure what Lil/Big would get.
        // `_ROUTER=dispatch` (2026-10-07) is the app's own route with every tier on and
        // dispatch on: a tool turn is picked (Apple's model) and run by the app, so a
        // Lil/Big cell measures `toolRouterAllTiers`. `_ROUTER_HEAD=1` puts the group
        // head in front of the pick (`toolGroupRouter`); `_ROUTER_CHAIN=1` lets a pick run
        // two read-only tools (`toolChain`).
        let palette: [any AgentTool] = SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_TOOLS") == "none" ? [] : toolPalette
        var plainRoute: (@Sendable () -> PlainTurnRoute?)?
        switch SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_ROUTER") {
        case "off":
            // The router arm's baseline (2026-10-10): this same live path with no route, which is
            // how Lil and Big ship with the router flags off. Before, the arm's "off" cell ran
            // tool-use through LocalAgent, a different path from the cells it was compared with.
            break
        case "1":
            let embedder = NLSentenceEmbedder()
            let route = PlainTurnRoute(decide: { ToolNeedRouter.decide(for: $0, embed: embedder.vector) }, instructions: nil)
            plainRoute = { route }
        case "dispatch":
            let route = ToolRouterWiring.route(
                provider: provider, enabled: true, dispatch: true,
                groupRouter: SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_ROUTER_HEAD") == "1", allTiers: true,
                chain: SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_ROUTER_CHAIN") == "1"
            )
            plainRoute = { route }
        default:
            break
        }
        // The think-steer arm (2026-10-10): one rules clause on HOW to reason, nothing else.
        let steer = ThinkSteer(envValue: SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_THINK_STEER"))
        let responder = AgentRAGResponder(
            store: store, embedder: MLXEmbeddingService(), provider: provider,
            toolsProvider: { palette }, maxIterations: 3,
            thinkingModeProvider: { Self.thinkingMode(thinking) },
            fastThinkingProvider: { thinking.liveFastByDefault },
            // The Mac's clauses (#482, mirrors MiniLiveEvalTests): no declared age band, web
            // search on (the default), PCC offered (its switch on — the fuller clause, so the
            // answer has to name both exits). chat-what-leaves is scored against what ships.
            ageClauseProvider: { AgeAppropriateness.policy(for: .undeclared).promptClause },
            egressClauseProvider: {
                EgressDisclosure.clause(
                    EgressFacts(webSearch: true, privateCloudOffered: true), device: HostPlatform.thisDevice
                )
            },
            styleClauseProvider: { steer.clause },
            plainRouteProvider: plainRoute
        )
        // The tools the turn ran and the stage that picked them (2026-10-10): the 10-09 arm could
        // see neither. The recorder is a task-local, so the turn runs inside its scope.
        let tools = EvalToolLog()
        let stages = PickStageRecorder()
        let (raw, thinkMS) = try await ToolRouterWiring.$pickRecorder.withValue(stages) {
            let (_, stream) = try await responder.answerStreaming(
                fixture.prompt, images: images, history: [], onActivity: { activity in
                    if case let .usingTool(name, _) = activity { tools.append(name) }
                }
            )
            var raw = ""
            var thinkClock = ThinkPhaseClock()
            for await piece in stream {
                // The responder's fallback passes provider chunks through raw, and a
                // cumulative provider (AFM, PCC) yields snapshots — `+=` would score
                // "HHeHel…". Same fold the app's consumer applies (ChatSession).
                raw = StreamFold.fold(current: raw, chunk: piece)
                // The think phase on the clock: first token → first answer token.
                thinkClock.feed(piece, at: clock.now - start)
            }
            return (raw, thinkClock.thinkMS)
        }
        // An empty stream from a provider that can name its failure is a failed
        // call, scored as "ran — <reason>", never as "0 chars".
        if raw.isEmpty, let reason = (provider as? StreamFailureReporting)?.takeStreamFailure() {
            throw InferenceError.generationFailed(reason)
        }
        return EvalObservation(
            rawText: raw,
            toolCalls: tools.names,
            latencyMS: milliseconds(clock.now - start),
            routeStages: stages.stages.map(\.rawValue),
            thinkMS: thinkMS
        )
    }

    /// The router arm asked for a route mode (`off`, `1`, `dispatch`): tool-use fixtures then take
    /// the live path, the only one the router is wired into. Without one they keep LocalAgent's
    /// native loop, so every other tool-use cell measures what it always did (2026-10-10: the 10-09
    /// arm's tool-use column never reached the router, in any cell).
    private static var routerArmRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_ROUTER") != nil
    }

    /// Run the requested brains across the requested fixtures, emit per-fixture
    /// detail live, then the headline matrix.
    static func run(emit: @escaping (String) -> Void) async {
        let kinds = selectedKinds()
        let fixtureCount = ChatEvalFixtures.all.count(where: { kinds?.contains($0.kind) ?? true })
        emit("• chateval: \(fixtureCount) fixture(s) × \(selectedBrains().count + (pccRequested ? 1 : 0)) brain(s)"
            + (kinds.map { " [kinds: \($0.map(\.label).sorted().joined(separator: ","))]" } ?? "")
            + (livePathRequested ? " [LIVE PATH: AgentRAGResponder]" : "") + "…")
        var runs: [ChatEvalReport.BrainRun] = []
        let brains = selectedBrains()
        let mlxTiers = brains.filter { if case .mlx = $0.backing { true } else { false } }.map(\.rawValue)
        for tier in brains {
            // The A/B override is resolved PER TIER: a bare id with two MLX
            // brains selected used to run one model twice under two column
            // names — refuse loudly instead (ChatEvalModelOverride).
            let override = ChatEvalModelOverride.resolve(
                raw: SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_MLX_MODEL"),
                tier: tier.rawValue, mlxTiersSelected: mlxTiers
            )
            let modelID: String?
            switch (tier.backing, override) {
            case (.appleFoundationModels, _): modelID = nil
            case let (.mlx, .refused(reason)):
                emit("  – \(tier.rawValue): override refused — \(reason) (skipped)")
                continue
            case let (.mlx(stock), .stock): modelID = stock
            case let (.mlx, .override(id)): modelID = id
            }
            emit("• chateval brain \(tier.rawValue) (\(tier.displayName))"
                + (modelID.map { " → \($0)" } ?? "") + "…")
            // The RAM gate: MLX's peak over THIS brain's run (reset before it loads).
            let isMLX = modelID != nil
            let residentMB = isMLX ? MLXMemoryBudget.activeMB() : nil
            if isMLX { MLXMemoryBudget.resetPeak() }
            guard let scores = await evalBrain(tier, modelID: modelID, emit: emit) else {
                emit("  – \(tier.rawValue): unavailable (skipped)")
                continue
            }
            let peakMB = isMLX ? MLXMemoryBudget.peakMB() : nil
            if let peakMB, let residentMB {
                emit("  peak MLX memory: \(peakMB) MB (\(residentMB) MB already resident → \(peakMB - residentMB) MB this brain)")
            }
            runs.append(ChatEvalReport.BrainRun(
                brainID: tier.rawValue, modelID: modelID, scores: scores,
                peakMemoryMB: peakMB, residentMemoryMBAtStart: residentMB
            ))
        }
        if pccRequested, let scores = await evalPrivateCloud(emit: emit) {
            runs.append(ChatEvalReport.BrainRun(
                brainID: PrivateCloudInferenceAdapter.brainID, modelID: PrivateCloudInferenceAdapter.modelID, scores: scores
            ))
        }
        emit("")
        let provenance = currentProvenance()
        emit(provenance.rendered)
        emit("")
        emit(ChatEvalReport.matrix(runs))
        // The machine-readable primary artifact, beside the text transcript
        // (<OUT>.json) — or fenced on the same stream in stdout mode, where there
        // is no file a shell could open. Sorted keys, so two runs diff line by line.
        let document = ChatEvalDocument(provenance: provenance, runs: runs)
        do {
            let json = try ChatEvalReport.json(document)
            if SelfTest.writesToStandardOutput {
                emit(ChatEvalReport.fenced(json))
                emit("• chateval json → stdout (fenced)")
            } else {
                let jsonURL = URL(fileURLWithPath: SelfTest.outputPath + ".json")
                try json.write(to: jsonURL)
                emit("• chateval json → \(jsonURL.lastPathComponent)")
            }
        } catch {
            emit("  – chateval json NOT written: \(String(describing: error).prefix(80))")
        }
    }

    /// `M1K3_SELFTEST_CHATEVAL_PCC=1` — Apple's server model (Private Cloud
    /// Compute) through the same fixtures, as a fifth column. Only a process that
    /// holds the entitlement on macOS 27 has a backend; every other build skips
    /// with the reason on the transcript.
    private static var pccRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_PCC") == "1"
    }

    private static func evalPrivateCloud(emit: @escaping (String) -> Void) async -> [ChatEvalScore]? {
        emit("• chateval brain pcc (Private Cloud Compute) → \(PrivateCloudInferenceAdapter.modelID)…")
        guard let backend = PrivateCloudBackends.live() else {
            emit("  – pcc: no backend in this process — needs macOS 27+ and the "
                + "private-cloud-compute entitlement (skipped)")
            return nil
        }
        let status = await backend.status()
        guard status.available else {
            emit("  – pcc: backend reports unavailable (skipped)")
            return nil
        }
        // The column sends the STANDARD persona (the arm the local tiers get), and that
        // composition is the one door a user profile has (M1K3Persona.compose). A SelfTest
        // launch never builds AppEnvironment, so the profile is nil here by construction —
        // this guard makes that a promise rather than a coincidence: nothing about the
        // user reaches Apple's server from an eval.
        guard M1K3Persona.userProfile == nil else {
            emit("  – pcc: a user profile is set in this process; the standard persona would carry it (skipped)")
            return nil
        }
        emit("  pcc quota: \(status.quota)")
        // Big's plan reproduces the pre-plan behaviour; PCC has no thinking toggle anyway.
        return await evalProvider(
            PrivateCloudInferenceAdapter(backend: backend),
            thinking: EvalThinkingPlan(tier: .big, mode: thinkingMode), emit: emit
        )
    }

    /// Pause between fixtures (ms), `M1K3_SELFTEST_CHATEVAL_PACE_MS`; default 0 so the local
    /// tiers measure exactly as before. Apple's daemons rate-collapse under rapid turns
    /// (memory: pkill-poisons-afm-daemon) — set it for the Mini and PCC columns.
    private static var paceMS: Int {
        max(0, SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_PACE_MS").flatMap(Int.init) ?? 0)
    }

    /// Trials per fixture (M1K3_SELFTEST_CHATEVAL_REPEATS=N, default 1). A
    /// single-run cell has no error bars — security swung 2/7→5/7 across
    /// identical runs — so n is a first-class knob and shows in passed/total.
    static var repeats: Int {
        max(1, SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_REPEATS").flatMap(Int.init) ?? 1)
    }

    /// What the harness can read off THIS machine, plus what the caller states.
    /// Nothing inferred: the app commit and the mlx-swift-lm revision come from
    /// the environment (`M1K3_SELFTEST_APP_COMMIT`, `M1K3_SELFTEST_MLX_REVISION`)
    /// because a bundle cannot know its own pin; unset → nil, never a guess.
    static func currentProvenance() -> EvalProvenance {
        let info = ProcessInfo.processInfo
        let gb = Int((Double(info.physicalMemory) / 1_073_741_824).rounded())
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        let chipName = String(cString: chip).trimmingCharacters(in: .whitespacesAndNewlines)
        let v = info.operatingSystemVersion
        return EvalProvenance(
            date: ISO8601DateFormatter().string(from: Date()),
            hardware: "\(chipName.isEmpty ? "unknown chip" : chipName) · \(gb) GB",
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
            appCommit: SelfTestEnv.value("M1K3_SELFTEST_APP_COMMIT")
                ?? (Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String),
            mlxSwiftLMRevision: SelfTestEnv.value("M1K3_SELFTEST_MLX_REVISION"),
            // The harness sees only Low Power Mode; High Power (pmset powermode 2) is the operator's to state.
            powerMode: SelfTestEnv.value("M1K3_SELFTEST_POWERMODE").flatMap(Int.init) ?? (info.isLowPowerModeEnabled ? 1 : 0),
            powerSource: Self.currentPowerSource(),
            livePath: livePathRequested,
            repeats: repeats,
            notes: SelfTestEnv.value("M1K3_SELFTEST_NOTES")
        )
    }

    /// "ac" / "battery" / "ups" off the tested `SystemStatusProviding` seam (#217); nil when it
    /// cannot tell. The one field that would have caught 2026-09-05's battery-measured day
    /// (see EvalProvenance.powerSource).
    private static func currentPowerSource() -> String? {
        LiveSystemStatusProvider().providingPowerSource()?.rawValue
    }

    /// Brains to run: M1K3_SELFTEST_CHATEVAL_BRAINS=mini,lil narrows it (a full
    /// three-brain run loads ~11.5GB of weights); default is the whole catalogue.
    private static func selectedBrains() -> [BrainTier] {
        guard let raw = SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_BRAINS") else {
            return BrainTier.allCases
        }
        return raw.split(separator: ",")
            .compactMap { BrainTier(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// Turn-latency ceiling (ms) above which a CORRECT answer still fails the
    /// "responsive" check — catches AFM's context-overflow auto-loop that
    /// "passes" only after minutes. Tunable via M1K3_SELFTEST_CHATEVAL_LATENCY_MS;
    /// default 120s is generous enough not to fail a legitimately slow large
    /// model, tight enough to flag the multi-minute melts.
    private static var latencyCeilingMS: Int {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_LATENCY_MS").flatMap(Int.init) ?? 120_000
    }

    /// Optional task-kind filter (M1K3_SELFTEST_CHATEVAL_KINDS=tool-use,reasoning)
    /// — nil means every kind. Lets a focused tool-calling run skip the slow
    /// open-chat/reasoning turns.
    private static func selectedKinds() -> Set<TaskKind>? {
        guard let raw = SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_KINDS") else {
            return nil
        }
        let kinds = raw.split(separator: ",")
            .compactMap { TaskKind(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        return kinds.isEmpty ? nil : Set(kinds)
    }

    /// - Parameter modelID: the MLX model to run under this tier's name — the
    ///   stock id or the resolved A/B override (a local fused dir from
    ///   `mlx_lm.fuse`, or a challenger hub id). nil for Mini.
    private static func evalBrain(
        _ tier: BrainTier, modelID: String?, emit: @escaping (String) -> Void
    ) async -> [ChatEvalScore]? {
        let plan = EvalThinkingPlan(tier: tier, mode: thinkingMode)
        let steer = ThinkSteer(envValue: SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_THINK_STEER"))
        emit("  think steer: \(steer.rawValue)")
        emit("  thinking: \(thinkingMode.rawValue) (bare \(plan.bareThinks ? "on" : "off"), "
            + "live \(plan.liveForced.map { $0 ? "always" : "fast" } ?? "auto, \(plan.liveFastByDefault ? "speed-tier" : "full") policy"))")
        let provider: any InferenceProvider
        switch tier.backing {
        case .appleFoundationModels:
            // Spike mode (Phase 15): opt the provider INTO native tool-calling so
            // LocalAgent routes AFM through runNative + our structured @Generable
            // continueToolTurn (third path), not the prompt-ReAct floor. Off ⇒
            // supportsToolCalls stays false ⇒ ReAct floor / Apple-driven, unchanged.
            let afm = miniFullPersona
                ? AppleFoundationModelsProvider(
                    instructions: { M1K3Persona.systemPrompt }, nativeToolCalling: afmNativeTools
                )
                : AppleFoundationModelsProvider(nativeToolCalling: afmNativeTools)
            guard afm.isAvailable else { return nil }
            emit("  mini persona: " + (miniFullPersona ? "full (with FOLLOW-UPS)" : "trimmed (miniSystemPrompt)"))
            provider = afm
        case let .mlx(stockID):
            // 2048 like the per-model eval: a reasoning brain can spend hundreds
            // of tokens inside <think> before a one-word answer.
            // The tier's own cap (HistoryBudgetPolicy, what the app builds this slot
            // with) and its construction-time thinking — no longer a flat 2048 with
            // thinking on, which let a thinking brain spend the whole budget inside
            // <think> and score empty (the 2026-10-06 shootout).
            provider = AppEnvironment.evalMLXBrain(
                modelID: modelID ?? stockID,
                maxTokens: HistoryBudgetPolicy.generationTokenCap(for: tier, defaultCap: MLXBrainProvider.defaultMaxTokens),
                thinkingEnabled: plan.bareThinks
            )
        }
        return await evalProvider(provider, thinking: plan, emit: emit)
    }

    /// Every selected fixture, `repeats` times, through ONE provider — the loop
    /// the tiers and the PCC arm share, so a new column can never run a
    /// different loop from the columns beside it.
    private static func evalProvider(
        _ provider: any InferenceProvider, thinking: EvalThinkingPlan, emit: @escaping (String) -> Void
    ) async -> [ChatEvalScore] {
        let kinds = selectedKinds()
        var scores: [ChatEvalScore] = []
        let trials = repeats
        var paced = false
        for trial in 0 ..< trials {
            for fixture in ChatEvalFixtures.all where kinds?.contains(fixture.kind) ?? true {
                // Between turns only — never before the first or after the last.
                if paced, paceMS > 0 { try? await Task.sleep(for: .milliseconds(paceMS)) }
                paced = true
                // Bracket every fixture. The gap between one `fixture done` and the
                // next `fixture start` is time the harness spends OUTSIDE the turn,
                // and on 2026-08-10 that gap was 177s before `chat-capabilities`
                // with nothing in the log to explain it. Whatever it is, it is now
                // bounded by two timestamps instead of inferred from silence.
                Self.evalLog.notice("fixture start: \(fixture.id, privacy: .public)")
                let score = await runFixture(fixture, provider: provider, thinking: thinking).withRepeatIndex(trial)
                Self.evalLog.notice(
                    "fixture done: \(fixture.id, privacy: .public) \(score.latencyMS, privacy: .public)ms"
                )
                emit(trials > 1 ? "  [trial \(trial + 1)/\(trials)] " + score.rendered : score.rendered)
                scores.append(score)
            }
        }
        return scores
    }

    private static func runFixture(
        _ fixture: ChatEvalFixture, provider: any InferenceProvider, thinking: EvalThinkingPlan
    ) async -> ChatEvalScore {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            switch fixture.kind {
            case .vision:
                if let gap = Self.imageGap(provider) {
                    return .notApplicable(fixture, reason: gap)
                }
                let images = try fixture.images.map { name in
                    guard let url = VisionFixtureAssets.url(for: name) else {
                        throw InferenceError.generationFailed("vision asset \(name) missing from the bundle")
                    }
                    return ImageAttachment(url: url)
                }
                let observation = try await livePathObservation(
                    fixture, images: images, provider: provider, thinking: thinking, start: start, clock: clock
                )
                return ChatEvalScorer.score(
                    fixture: fixture, observation: observation, latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit
                )
            case .groundedQ:
                let observation = try await groundedObservation(fixture, provider: provider, start: start, clock: clock)
                return ChatEvalScorer.score(fixture: fixture, observation: observation, latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit)
            case .toolUse where routerArmRequested:
                let observation = try await livePathObservation(
                    fixture, provider: provider, thinking: thinking, start: start, clock: clock
                )
                return ChatEvalScorer.score(
                    fixture: fixture, observation: observation,
                    latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit
                )
            case .toolUse:
                // Three AFM tool paths, selected by env (MLX always goes through
                // LocalAgent's native dialect):
                //   • default            → afmNativeToolScore: Apple drives the loop
                //                          via LanguageModelSession(tools:) — the
                //                          path that melts (337s) on a non-resolving
                //                          result, no iteration cap we can inject.
                //   • AFM_REACT=1        → toolObservationScore on the ReAct floor
                //                          (supportsToolCalls is false).
                //   • AFM_NATIVE_TOOLS=1 → THE SPIKE: toolObservationScore, but the
                //                          provider opted into native tool-calling,
                //                          so LocalAgent runs our structured
                //                          @Generable continueToolTurn under ITS cap.
                if provider is AppleFoundationModelsProvider, !afmNativeTools, !forceReActFloor {
                    return try await afmNativeToolScore(fixture, start: start, clock: clock)
                }
                return try await toolObservationScore(
                    fixture, provider: provider, thinking: thinking, start: start, clock: clock
                )
            // NB: `where` binds per-pattern, so it must be repeated — a single
            // trailing `where` would leave .openChat matching unconditionally.
            case .openChat where livePathRequested, .codeGen where livePathRequested,
                 .worldKnowledge where livePathRequested, .humour where livePathRequested,
                 .interview where livePathRequested,
                 .instructionFollowing where livePathRequested:
                // The live-path arm: the production AgentRAGResponder stack
                // (grounding head + RULES + agent loop) instead of bare generate.
                let observation = try await livePathObservation(
                    fixture, provider: provider, thinking: thinking, start: start, clock: clock
                )
                return ChatEvalScorer.score(
                    fixture: fixture, observation: observation, latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit
                )
            case .openChat, .reasoning, .codeGen, .refusal, .security, .worldKnowledge,
                 .humour, .interview, .instructionFollowing, .document, .sycophancy:
                // codeGen is closed-book like the others: plain generate, then the
                // scorer checks artifact markers + must-comply (no tools, no seed).
                //
                // worldKnowledge deliberately DEFAULTS to this bare-generate arm:
                // the question it answers is "what does this MODEL know", so the
                // fair comparison isolates the weights from our persona and
                // grounding scaffolding. Run it with LIVE_PATH=1 (the arm above)
                // to ask the different question — whether M1K3-as-shipped answers
                // a plain factual question or deflects it into "not in your
                // documents", which is what its mustComply expectation hunts.
                let raw = try await provider.generate(prompt: fixture.prompt)
                let ms = milliseconds(clock.now - start)
                return ChatEvalScorer.score(
                    fixture: fixture, observation: EvalObservation(rawText: raw, latencyMS: ms),
                    latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit
                )
            }
        } catch {
            return ChatEvalScore(
                fixtureID: fixture.id, kind: fixture.kind,
                checks: [EvalCheck(
                    name: "ran", outcome: .fail,
                    detail: String(describing: error).prefix(70).description
                )],
                latencyMS: milliseconds(clock.now - start)
            )
        }
    }

    /// Grounded-Q: seed the doc into a throwaway store, answer through the real
    /// RAGResponder (which retrieves, then strips hallucinated citations), and
    /// read the validated-citation count straight off the response.
    private static func groundedObservation(
        _ fixture: ChatEvalFixture, provider: any InferenceProvider,
        start: ContinuousClock.Instant, clock: ContinuousClock
    ) async throws -> EvalObservation {
        // path: nil → GRDB in-memory DatabaseQueue, fresh per fixture. Intentional:
        // keeps grounded-Q fixtures isolated and writes nothing to the app container.
        let store = try KnowledgeStore()
        let embedder = MLXEmbeddingService()
        let ingester = DocumentIngester(store: store, embedder: embedder)
        if let doc = fixture.seedDoc {
            _ = try await ingester.ingest(title: "Notes", text: doc)
        }
        let responder = RAGResponder(store: store, embedder: embedder, provider: provider)
        let response = try await responder.answer(fixture.prompt)
        return EvalObservation(
            rawText: response.answer,
            validCitationCount: response.citations.count,
            latencyMS: milliseconds(clock.now - start)
        )
    }

    /// Tool-use: run the REAL agent loop. LocalAgent routes AFM through the
    /// prompt-ReAct floor and MLX through its native dialect; AgentResult
    /// .toolsUsed reads the same either way, so mini's tool-calling is measured,
    /// not skipped. maxIterations 3 = pick a tool, observe, conclude.
    private static func toolObservationScore(
        _ fixture: ChatEvalFixture, provider: any InferenceProvider, thinking: EvalThinkingPlan,
        start: ContinuousClock.Instant, clock: ContinuousClock
    ) async throws -> ChatEvalScore {
        let agent = LocalAgent(inferenceProvider: provider, tools: toolPalette, maxIterations: 3)
        let result = try await agent.run(goal: fixture.prompt, thinkingEnabled: thinking.bareThinks)
        let toolsUsed = result.toolsUsed
        let rawText = result.conclusion.isEmpty
            ? "tools used: \(toolsUsed.joined(separator: ","))"
            : result.conclusion
        let observation = EvalObservation(
            rawText: rawText,
            toolCalls: toolsUsed,
            latencyMS: milliseconds(clock.now - start)
        )
        return ChatEvalScorer.score(fixture: fixture, observation: observation, latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit)
    }

    /// Tool-use via AFM's NATIVE FoundationModels tools. The model is handed real
    /// `Tool` instances through `LanguageModelSession(tools:)`; the framework
    /// drives the call loop itself and our tools record which were selected. This
    /// is the apples-to-apples answer to "can mini call tools when given a proper
    /// native dialect?" — versus the prompt-ReAct floor it falls back to today.
    private static func afmNativeToolScore(
        _ fixture: ChatEvalFixture,
        start: ContinuousClock.Instant, clock: ContinuousClock
    ) async throws -> ChatEvalScore {
        let recorder = ToolCallRecorder()
        let tools: [any FoundationModels.Tool] = ChatEvalStubPalette.specs.map {
            afmTool(for: $0, hard: hardStubs, recorder: recorder)
        }
        let session = LanguageModelSession(tools: tools, instructions: M1K3Persona.systemPrompt)
        // Score on what the model SELECTED even if the session then errors. AFM
        // auto-loops the tool call internally, and a stub output that doesn't
        // resolve the query makes it retry until the context window overflows —
        // but the tool WAS chosen (the recorder caught it). Dropping that to a
        // blanket "ran: error" would misreport correct selection as a miss, so
        // we keep the captured calls and tag the failure mode in the text.
        let answer: String
        do {
            answer = try await session.respond(to: fixture.prompt).content
        } catch {
            let toolsUsed = recorder.captured
            guard !toolsUsed.isEmpty else { throw error } // genuine failure, no call made
            answer = "tools used: \(toolsUsed.joined(separator: ",")) "
                + "(session error after selection: \(String(describing: error).prefix(40)))"
        }
        let toolsUsed = recorder.captured
        let observation = EvalObservation(
            rawText: answer.isEmpty ? "tools used: \(toolsUsed.joined(separator: ","))" : answer,
            toolCalls: toolsUsed,
            latencyMS: milliseconds(clock.now - start)
        )
        return ChatEvalScorer.score(fixture: fixture, observation: observation, latencyCeilingMS: latencyCeilingMS, previewLimit: previewLimit)
    }

    /// `M1K3_SELFTEST_CHATEVAL_FULL_ANSWERS=1` keeps every answer whole in the
    /// document (bake-offs: a fail must be re-adjudicable later); default is the
    /// 240-char excerpt that keeps committed transcripts readable.
    private static var previewLimit: Int {
        SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_FULL_ANSWERS") == "1" ? .max : ChatEvalScore.answerPreviewLimit
    }

    /// `M1K3_SELFTEST_CHATEVAL_THINKING=tier|always|fast` — how every arm thinks
    /// (`EvalThinkingPlan`); unset or unknown is `tier`, production's shape.
    private static var thinkingMode: EvalThinkingMode {
        EvalThinkingMode(envValue: SelfTestEnv.value("M1K3_SELFTEST_CHATEVAL_THINKING"))
    }

    /// The live responder's mode for a plan: production Auto unless forced.
    private static func thinkingMode(_ plan: EvalThinkingPlan) -> ThinkingMode {
        switch plan.liveForced {
        case nil: .auto
        case true?: .always
        case false?: .fast
        }
    }

    /// Why this provider can't take an image turn here, or nil when it can —
    /// the chat UI's answer (`BrainTier.supportsImageInput` for Mini, the VLM
    /// load path for an MLX brain) PLUS the path the turn will really take:
    /// this stage's Mini defaults to the ReAct floor, which drops images
    /// silently (LocalAgent.run), while the app's Mini is native. Scoring that
    /// would measure a lost attachment, not Mini. The AFM arm reads the Mini
    /// TIER's flag, not the provider's: AFM backs only Mini today — a second
    /// AFM-backed tier must route through its own tier here (#497 review).
    static func imageGap(_ provider: any InferenceProvider) -> String? {
        if let mlx = provider as? MLXBrainProvider {
            return mlx.supportsImageInput ? nil : "text-only load path"
        }
        if let afm = provider as? AppleFoundationModelsProvider {
            guard BrainTier.mini.supportsImageInput else { return "Mini sees images on macOS 27+" }
            return afm.supportsToolCalls ? nil : "ReAct floor drops images — set _AFM_NATIVE_TOOLS=1 (the app's path)"
        }
        return "this provider takes no images"
    }

    /// Whole milliseconds in a Duration (matches SelfTest's TTFT helper).
    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
