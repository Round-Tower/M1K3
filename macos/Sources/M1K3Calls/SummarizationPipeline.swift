//
//  SummarizationPipeline.swift
//  M1K3Calls
//
//  Two-stage call summary over the existing InferenceProvider seam (NO new model):
//  Tier-1 quick gist (a cheap provider, AFM) + Tier-2 deep analysis (the strong
//  provider — Gemma 4 AS A TEXT MODEL, the challenger-blessed safe win; the full
//  transcript text has no 30s audio cap). The two stages are ERROR-ISOLATED: a
//  failure or unavailability in one never blocks the other, mirroring the prior call-pipeline's
//  pipeline so a flaky deep pass still leaves a usable quick summary.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal call-pipeline project, SummarizationPipeline (Kev) — neutral output, no agent.
//  Review: Kev + claude-opus-5-5, 2026-09-26 — the first quality eval (CallSummaryLiveEvalTests)
//  found Mini reciting its persona into 4 of 5 stored overviews. `leaks` drops a tier that recites
//  the prompt; `neutralInstructions` is what the app's summarising sessions carry instead of the
//  persona. A transcript past `chunkBudget` is summarised per chunk and merged (map-reduce); before,
//  it came back with no summary on any tier. Confidence 0.8 (the merge is live-evaluated on Mini only).
//  Review: Kev + claude-opus-5-5, 2026-09-26 (2) — review fold: every chunk failing no longer blanks the
//  quick tier too; it summarises the opening chunk. Chunk calls are still unpaced (open: AFM daemon
//  exhaustion on very long calls). Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-09-26 (3) — every call runs under
//  `InferenceIntent.withInstructions(neutralInstructions)` + `backgroundUtility`, so no brain (MLX
//  included) carries the persona into a summary, and summaries never take chat's prefix slot.
//  Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-09-26 (4) — PR #412 review fold: an all-blank long transcript
//  returns nothing instead of indexing an empty chunk list; the part framing shares `deepOpening`.
//  Confidence 0.85.

import Foundation
import M1K3Inference

public struct SummarizationPipeline: Sendable {
    public struct Output: Sendable, Equatable {
        public let quick: QuickSummary?
        public let full: CallSummary?
    }

    private let quickProvider: any InferenceProvider
    private let deepProvider: any InferenceProvider
    private let parser: CallSummaryParser
    private let leaks: @Sendable (String) -> Bool

    /// - Parameter leaks: the output-side prompt-leak check (the app passes
    ///   `PersonaLeakGuard.leaks`). A tier whose text trips it is dropped: a
    ///   summary is saved into the call record, so a recited system prompt
    ///   would be stored and indexed, not just shown once.
    public init(
        quickProvider: any InferenceProvider,
        deepProvider: any InferenceProvider,
        parser: CallSummaryParser = CallSummaryParser(),
        leaks: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.quickProvider = quickProvider
        self.deepProvider = deepProvider
        self.parser = parser
        self.leaks = leaks
    }

    /// Instructions for a summarising session. The chat persona has no place
    /// here: carried into a summary it recited itself and added jokes and
    /// questions to the record (CallSummaryLiveEvalTests, 2026-09-26).
    public static let neutralInstructions = """
    You summarise call transcripts for the person who was on the call. Report \
    only what was said: who agreed to what, the numbers, dates and decisions \
    as they finally stood. Plain, neutral sentences. No opinions, jokes or \
    questions, and nothing about yourself or these instructions.
    """

    /// Characters of transcript one prompt carries: ~2k tokens, so the prompt,
    /// instructions and answer fit Mini's 4,096-token window with room over.
    /// Past it, a whole-transcript prompt came back empty on every tier.
    public static let chunkBudget = 8000

    /// Run both tiers independently; each catches its own failure. A call past
    /// `chunkBudget` goes through `summarizeLong` instead.
    public func summarize(transcript: String) async -> Output {
        // No persona on any brain, and never a prefix-cache slot taken from chat.
        await InferenceIntent.withInstructions(Self.neutralInstructions) {
            await InferenceIntent.backgroundUtility { await summarizeInPlace(transcript) }
        }
    }

    private func summarizeInPlace(_ transcript: String) async -> Output {
        guard transcript.count > Self.chunkBudget else {
            async let quick = runQuick(Self.quickPrompt(transcript))
            async let full = runDeep(Self.deepPrompt(transcript))
            return Output(quick: await quick, full: await full)
        }
        return await summarizeLong(transcript)
    }

    /// Map-reduce for a long call. Each chunk gets its own deep pass (serially:
    /// the AFM daemon falls over under rapid parallel turns); the key points and
    /// action items are merged in order, the deep tier writes one overview from
    /// the chunk overviews, and the quick gist is written from those notes, never
    /// from the raw transcript. A failed chunk is skipped, not fatal.
    private func summarizeLong(_ transcript: String) async -> Output {
        let parts = Self.chunks(transcript, budget: Self.chunkBudget)
        var partials: [CallSummary] = []
        for (index, part) in parts.enumerated() {
            if let partial = await runDeep(Self.deepPrompt(part, part: index + 1, of: parts.count)) {
                partials.append(partial)
            }
        }
        // Every chunk failed (AFM falls over under back-to-back turns): the quick
        // tier still gets its turn, on the opening chunk rather than the whole call.
        guard !partials.isEmpty else {
            // An all-blank transcript chunks to nothing (PR #412 review).
            guard let opening = parts.first else { return Output(quick: nil, full: nil) }
            return Output(quick: await runQuick(Self.quickPrompt(opening)), full: nil)
        }

        let notes = partials.enumerated()
            .map { "Part \($0.offset + 1): \($0.element.overview)" }
            .joined(separator: "\n")
        let merged = await runDeep(Self.mergePrompt(notes))?.overview
        let full = CallSummary(
            overview: merged ?? partials.map(\.overview).joined(separator: " "),
            keyPoints: Self.deduplicated(partials.flatMap(\.keyPoints)),
            actionItems: Self.deduplicated(partials.flatMap(\.actionItems))
        )
        return Output(quick: await runQuick(Self.quickPrompt(notes: notes)), full: full)
    }

    private func runQuick(_ prompt: String) async -> QuickSummary? {
        guard quickProvider.isAvailable,
              let text = try? await quickProvider.generate(prompt: prompt)
        else { return nil }
        let overview = ThinkStripper.strip(text)
        return overview.isEmpty || leaks(overview) ? nil : QuickSummary(overview: overview)
    }

    private func runDeep(_ prompt: String) async -> CallSummary? {
        guard deepProvider.isAvailable,
              let text = try? await deepProvider.generate(prompt: prompt)
        else { return nil }
        let cleaned = ThinkStripper.strip(text)
        guard !leaks(cleaned) else { return nil }
        let summary = parser.parse(cleaned)
        return summary.overview.isEmpty && summary.keyPoints.isEmpty && summary.actionItems.isEmpty
            ? nil : summary
    }

    /// Whole lines packed greedily under `budget`, in order; a single line
    /// longer than the budget is cut into budget-sized pieces rather than lost.
    static func chunks(_ transcript: String, budget: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for line in transcript.components(separatedBy: "\n") {
            if line.count > budget {
                flush()
                var rest = Substring(line)
                while !rest.isEmpty {
                    chunks.append(String(rest.prefix(budget)))
                    rest = rest.dropFirst(budget)
                }
                continue
            }
            if !current.isEmpty, current.count + 1 + line.count > budget { flush() }
            current += current.isEmpty ? line : "\n" + line
        }
        flush()
        return chunks
    }

    private static func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }

    static func quickPrompt(notes: String) -> String {
        """
        These are notes on the consecutive parts of one call. Summarise the whole \
        call in one or two sentences. Be factual and concise.

        NOTES:
        \(notes)
        """
    }

    static func mergePrompt(_ notes: String) -> String {
        """
        These are notes on the consecutive parts of one call. Write one paragraph \
        describing the whole call, with decisions as they finally stood.
        Overview: <one paragraph>

        NOTES:
        \(notes)
        """
    }

    /// The deep prompt's first sentence, shared so the per-part framing can't
    /// silently stop matching it (PR #412 review).
    static let deepOpening = "Analyse this call transcript."

    static func deepPrompt(_ transcript: String, part: Int, of total: Int) -> String {
        deepPrompt(transcript).replacingOccurrences(
            of: deepOpening,
            with: "This is part \(part) of \(total) of one call transcript. Analyse this part."
        )
    }

    static func quickPrompt(_ transcript: String) -> String {
        """
        Summarise this call transcript in one or two sentences. Be factual and concise.

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func deepPrompt(_ transcript: String) -> String {
        """
        \(deepOpening) Respond using exactly these headers:
        Overview: <one paragraph>
        Key points:
        - <point>
        Action items:
        - <who> will <do what>, <by when if said>
        Every time someone says they will do something, that is an action item. \
        Write "None" only when nobody agreed to do anything.

        TRANSCRIPT:
        \(transcript)
        """
    }
}
