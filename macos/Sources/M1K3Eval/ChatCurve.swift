//
//  ChatCurve.swift
//  M1K3Eval
//
//  The chat-curve instrument's pure half (GEMMA_1_1_PLAN.md, "Qwen3.5 cross-turn
//  checkpoint: measure a scripted chat's prefill curve FIRST"). A fixed script of twenty
//  short messages is driven through the live responder with the history accumulating;
//  each message yields the rendered prompt length, how much of it the tool session
//  reused from its cache, the prefill the generation paid, and the process's peak RSS.
//  The slope per message says whether a cross-turn checkpoint is worth building.
//
//  The numbers are read off the app's own `.notice` log lines (the `reuse: X/Y` line and
//  the ttft `prompt=…tok prefill=…ms` line), so no inference code is touched. This file
//  is the script, the parsers, the curve summary and the JSON; ChatCurveStage (M1K3App)
//  is the glue that runs it.
//
//  DESIGN NOTE — nil beats zero: a turn that logged no metric line has no figure, and a
//  slope over fewer than two measured points is nil.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8 (TDD'd in ChatCurveTests;
//  the log-line formats are pinned there against MLXToolCalling.logPrefillReuse and
//  logGenerationInfo, so a reworded log line fails a test, not a run). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#530) — `turnLines` windows a turn by date and
//  provider label; the first Big run's columns were cumulative because the stage trusted
//  OSLogStore's position(date:) alone.
//  Review: Kev + claude-fable-5.1, 2026-10-25 — the curve could not see the prefill it was built to
//  measure: in checkpoint mode the generate's `prompt=` is ONE token (the 10-10 run read
//  "prefilled=21tok" against ~800–2,400 really prefilled a message) and `prefillExactly` was untimed.
//  The reuse line now carries `extend=…ms`, the sample sums it, the slope the decision reads is over
//  the TOTAL prefill, decode tokens + throughput fold per turn (for the scorecard's GenerationFigures),
//  MLX's own peak rides beside `ru_maxrss`, and the script runs to twenty messages so the
//  HistoryWindow cliff (16 turns) is on the curve. Confidence 0.85.
//

import Foundation

/// The fixed twenty-message script. Short and varied so the history grows by a few dozen
/// tokens a turn: the curve then isolates what the CACHE does, not what the user typed.
/// Twenty, not eight (2026-10-25): `HistoryWindow` keeps 16 turns (8 exchanges), so from about
/// message 10 the oldest line drops every turn and any shared prefix collapses to the persona.
/// The first eight are the 2026-10-10 script byte for byte, so the two curves still line up.
public enum ChatCurveScript {
    public static let messages: [String] = [
        "Hi! How's your day going?",
        "What's a good way to start learning the guitar?",
        "I only have twenty minutes a day. Is that enough?",
        "Which should I practise first, chords or scales?",
        "Funny, my neighbour plays the fiddle.",
        "Can you remind me what we said about practice time?",
        "Give me a tiny weekly plan in two lines.",
        "Thanks. Sum up our whole chat in one sentence.",
        "What's the easiest first song to learn?",
        "My fingertips hurt after ten minutes. Normal?",
        "Should I buy a tuner or use an app?",
        "What did I say my neighbour plays?",
        "Pick one chord for me to learn tonight.",
        "How do I know when I'm ready for a second chord?",
        "Is it bad to practise sitting on the bed?",
        "Earlier you gave me a weekly plan — repeat just the first line.",
        "What's a strum pattern a beginner can manage?",
        "Any tip for switching chords faster?",
        "How many minutes a day did I say I had?",
        "Last one: three words of encouragement.",
    ]
}

public struct ChatCurveReuse: Sendable, Equatable, Codable {
    public let reused: Int
    public let total: Int
    /// The checkpoint extend's prefill time (`extend=…ms`, 2026-10-25): in checkpoint mode the generate
    /// sees one token, so the ttft line's `prefill=` misses the transcript prefill `prefillExactly` paid.
    /// nil on a line written before the figure existed, or on a non-checkpoint send.
    public let extendMS: Int?

    public init(reused: Int, total: Int, extendMS: Int? = nil) {
        self.reused = reused
        self.total = total
        self.extendMS = extendMS
    }
}

public struct ChatCurveGeneration: Sendable, Equatable, Codable {
    public let promptTokens: Int
    public let prefillMS: Int
    public let decodeTokens: Int?
    public let tokensPerSecond: Int?

    public init(promptTokens: Int, prefillMS: Int, decodeTokens: Int? = nil, tokensPerSecond: Int? = nil) {
        self.promptTokens = promptTokens
        self.prefillMS = prefillMS
        self.decodeTokens = decodeTokens
        self.tokensPerSecond = tokensPerSecond
    }
}

/// One turn's log lines folded to figures. Optionals stay nil when no line was seen.
public struct ChatCurveFolded: Sendable, Equatable {
    public let reuse: ChatCurveReuse?
    public let promptTokens: Int?
    public let prefillMS: Int?
    /// Checkpoint extend time summed over the turn's sends; nil when no send carried one.
    public let extendMS: Int?
    public let decodeTokens: Int?
    /// Total decode tokens over total decode time (a 2-token send at 60 tok/s must not pull a
    /// 200-token send at 30 up to 45); nil when no generation reported throughput.
    public let tokensPerSecond: Double?
    public let generations: Int

    /// The same figures in the scorecard's shape; nil when the turn logged nothing at all.
    public func figures(firstChunkMS: Int?) -> GenerationFigures? {
        guard generations > 0 || extendMS != nil else { return nil }
        return GenerationFigures(
            prefillTokens: promptTokens, prefillMS: prefillMS, extendMS: extendMS, decodeTokens: decodeTokens,
            tokensPerSecond: tokensPerSecond, generations: generations, firstChunkMS: firstChunkMS
        )
    }
}

/// One `.notice` entry as the stage reads it off OSLogStore: when it landed, and what it said.
public struct ChatCurveLogEntry: Sendable, Equatable {
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.date = date
        self.message = message
    }
}

public enum ChatCurveLogParser {
    /// The lines that belong to ONE turn: entries dated at or after `since` (the 2026-10-10
    /// run summed every generation since launch — 3071, 6294, 9891… — because the store's
    /// position was not honoured; the date is checked here, not trusted there), and
    /// generation lines only from the provider named `label` (a title or summary generation
    /// in the same window would otherwise count as this turn's prefill). Reuse lines carry no
    /// label and are kept as they come.
    public static func turnLines(_ entries: [ChatCurveLogEntry], since: Date, label: String) -> [String] {
        turnLines(entries, since: since, labels: [label, toolSessionLabel])
    }

    /// The same window over a SET of generation labels: the ttft line names the PATH, not the provider
    /// (`stream` / `generate` for a plain turn, `toolTurnSession` for an agent step, `caption` for an
    /// image), so a headless stage that owns the only brain passes `turnLabels` and keeps every path a
    /// chat turn can take while a caption or any other labelled utility still falls outside.
    public static func turnLines(_ entries: [ChatCurveLogEntry], since: Date, labels: Set<String>) -> [String] {
        entries.compactMap { entry in
            guard entry.date >= since else { return nil }
            let labelled = labels.contains { entry.message.hasPrefix("\($0) [") }
            if generation(in: entry.message) != nil, !labelled { return nil }
            return entry.message
        }
    }

    /// The tool session's generation lines carry this label, not the provider's (MLXToolCalling's
    /// `logGenerationInfo(label: "toolTurnSession")`); they are the turn's too (2026-10-25).
    static let toolSessionLabel = "toolTurnSession"

    /// Every ttft label a chat turn's generations can carry (MLXBrainProvider's plain paths, the seeded
    /// plain turn, the two tool paths). Not `caption`: an image caption is a utility, not the turn. Not
    /// `raw` either (`generateRawStreaming`: ChatSession and Brain at Home, never an eval or curve path).
    /// `generate` and `stream` are ALSO what a title or distiller generation on the same provider would
    /// log, so this set is for a headless stage that owns the only brain and runs no utilities — the
    /// per-provider-name filter it replaced never matched a generation line at all.
    public static let turnLabels: Set<String> = ["stream", "generate", "toolTurn", toolSessionLabel]

    /// `toolTurnSession reuse: 2301/2650 tok from cache, … seed=persona[ extend=812ms]`
    public static func reuse(in line: String) -> ChatCurveReuse? {
        guard let match = line.firstMatch(of: /toolTurnSession reuse: (\d+)\/(\d+) tok/),
              let reused = Int(match.1), let total = Int(match.2)
        else { return nil }
        let extend = line.firstMatch(of: /\ extend=(\d+)ms/).flatMap { Int($0.1) }
        return ChatCurveReuse(reused: reused, total: total, extendMS: extend)
    }

    /// `label [model]: prompt=349tok prefill=812ms decode=64tok @31tok/s`
    public static func generation(in line: String) -> ChatCurveGeneration? {
        guard let match = line.firstMatch(of: /prompt=(\d+)tok prefill=(\d+)ms/),
              let tokens = Int(match.1), let ms = Int(match.2)
        else { return nil }
        let decode = line.firstMatch(of: /\ decode=(\d+)tok @(\d+)tok\/s/)
        return ChatCurveGeneration(
            promptTokens: tokens, prefillMS: ms,
            decodeTokens: decode.flatMap { Int($0.1) }, tokensPerSecond: decode.flatMap { Int($0.2) }
        )
    }

    /// A message can run several generations (tool iterations): the LAST reuse line is the
    /// turn's final render; prompt tokens, prefill and extend time are paid by every send.
    public static func fold(_ lines: [String]) -> ChatCurveFolded {
        var reuse: ChatCurveReuse?
        var extends: [Int] = []
        var generations: [ChatCurveGeneration] = []
        for line in lines {
            if let found = Self.reuse(in: line) {
                reuse = found
                if let extend = found.extendMS { extends.append(extend) }
            }
            if let found = generation(in: line) { generations.append(found) }
        }
        let decoded = generations.compactMap(\.decodeTokens)
        // The rate is total tokens over total seconds, both summed over the SAME lines: a line whose
        // logged rate is 0 (the line's tok/s is integer-truncated, so a slow decode rounds to 0) has no
        // seconds to give and must not lend its tokens to the numerator either (review fold, 2026-10-25).
        // The truncation itself leaves up to ~1/rate of error in every aggregate (3% at 30 tok/s).
        let timed = generations.compactMap { generation -> (tokens: Int, seconds: Double)? in
            guard let tokens = generation.decodeTokens, let rate = generation.tokensPerSecond, rate > 0 else {
                return nil
            }
            return (tokens, Double(tokens) / Double(rate))
        }
        let timedTokens = timed.reduce(0) { $0 + $1.tokens }
        let timedSeconds = timed.reduce(0.0) { $0 + $1.seconds }
        return ChatCurveFolded(
            reuse: reuse,
            promptTokens: generations.isEmpty ? nil : generations.map(\.promptTokens).reduce(0, +),
            prefillMS: generations.isEmpty ? nil : generations.map(\.prefillMS).reduce(0, +),
            extendMS: extends.isEmpty ? nil : extends.reduce(0, +),
            decodeTokens: decoded.isEmpty ? nil : decoded.reduce(0, +),
            tokensPerSecond: timedSeconds > 0 ? Double(timedTokens) / timedSeconds : nil,
            generations: generations.count
        )
    }
}

public struct ChatCurveSample: Sendable, Equatable, Codable {
    public let index: Int
    public let question: String
    /// The rendered prompt length (the `reuse` line's total).
    public let renderedTokens: Int?
    public let reusedTokens: Int?
    /// Tokens actually prefilled, summed over the turn's generations.
    public let promptTokens: Int?
    public let prefillMS: Int?
    public let generations: Int
    public let peakRSSMB: Int
    public let answerChars: Int
    /// Checkpoint extend time summed over the message's sends (2026-10-25); nil before the figure existed.
    public let extendMS: Int?
    /// MLX's peak memory so far in MB (`MLXMemoryBudget.peakMB`, the counter Lil's 5 GB own-peak cap is
    /// read against — `ru_maxrss` is the process, weights and all); nil on older curves.
    public let mlxPeakMB: Int?

    public init(
        index: Int, question: String, renderedTokens: Int?, reusedTokens: Int?, promptTokens: Int?,
        prefillMS: Int?, generations: Int, peakRSSMB: Int, answerChars: Int,
        extendMS: Int? = nil, mlxPeakMB: Int? = nil
    ) {
        self.index = index
        self.question = question
        self.renderedTokens = renderedTokens
        self.reusedTokens = reusedTokens
        self.promptTokens = promptTokens
        self.prefillMS = prefillMS
        self.generations = generations
        self.peakRSSMB = peakRSSMB
        self.answerChars = answerChars
        self.extendMS = extendMS
        self.mlxPeakMB = mlxPeakMB
    }

    public var reuseFraction: Double? {
        guard let renderedTokens, let reusedTokens, renderedTokens > 0 else { return nil }
        return Double(reusedTokens) / Double(renderedTokens)
    }

    /// The prefill this message really paid: the generates' own plus the checkpoint extend. Before
    /// 2026-10-25 the curve read `prefillMS` alone, which in checkpoint mode is the one-token generate.
    public var totalPrefillMS: Int? {
        switch (prefillMS, extendMS) {
        case (nil, nil): nil
        case let (prefill, extend): (prefill ?? 0) + (extend ?? 0)
        }
    }
}

public struct ChatCurveSummary: Sendable, Equatable, Codable {
    /// Least-squares slope of rendered prompt tokens per message (how fast the prompt grows).
    public let renderedTokensPerMessage: Double?
    /// Least-squares slope of the generates' own prefill ms per message (the one-token generate in checkpoint mode).
    public let prefillMSPerMessage: Double?
    /// Least-squares slope of the TOTAL prefill ms per message (generate + extend): what the growth
    /// costs; ~0 = the cache holds. The figure the cross-turn reuse decision reads.
    public let totalPrefillMSPerMessage: Double?

    public init(samples: [ChatCurveSample]) {
        renderedTokensPerMessage = Self.slope(
            samples.compactMap { s in s.renderedTokens.map { (s.index, Double($0)) } }
        )
        prefillMSPerMessage = Self.slope(
            samples.compactMap { s in s.prefillMS.map { (s.index, Double($0)) } }
        )
        totalPrefillMSPerMessage = Self.slope(
            samples.compactMap { s in s.totalPrefillMS.map { (s.index, Double($0)) } }
        )
    }

    static func slope(_ points: [(Int, Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let sx = points.reduce(0.0) { $0 + Double($1.0) }
        let sy = points.reduce(0.0) { $0 + $1.1 }
        let sxy = points.reduce(0.0) { $0 + Double($1.0) * $1.1 }
        let sxx = points.reduce(0.0) { $0 + Double($1.0) * Double($1.0) }
        let denominator = n * sxx - sx * sx
        guard denominator != 0 else { return nil }
        return (n * sxy - sx * sy) / denominator
    }
}

public struct ChatCurveReport: Sendable, Equatable, Codable {
    public let modelID: String
    public let samples: [ChatCurveSample]
    public let summary: ChatCurveSummary

    public init(modelID: String, samples: [ChatCurveSample]) {
        self.modelID = modelID
        self.samples = samples
        summary = ChatCurveSummary(samples: samples)
    }

    public static func json(_ report: ChatCurveReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public static let fenceOpen = "-----BEGIN CHATCURVE JSON-----"
    public static let fenceClose = "-----END CHATCURVE JSON-----"

    /// The stdout-mode form (`M1K3_SELFTEST_OUT=-`): the document between markers, as ChatEval does.
    public static func fenced(_ json: Data) -> String {
        fenceOpen + "\n" + (String(bytes: json, encoding: .utf8) ?? "") + "\n" + fenceClose
    }

    /// The transcript form: one row per message and the slope line.
    public var rendered: String {
        func figure(_ value: Int?) -> String {
            value.map(String.init) ?? "–"
        }
        func slope(_ value: Double?) -> String {
            value.map { String(format: "%.1f", $0) } ?? "–"
        }
        var lines = samples.map { s in
            "chatcurve #\(s.index + 1) rendered=\(figure(s.renderedTokens))tok reuse=\(figure(s.reusedTokens))"
                + " prefilled=\(figure(s.promptTokens))tok prefill=\(figure(s.prefillMS))ms"
                + " extend=\(figure(s.extendMS))ms gens=\(s.generations) rss=\(s.peakRSSMB)MB"
                + " mlx=\(figure(s.mlxPeakMB))MB"
        }
        lines.append(
            "chatcurve slope [\(modelID)]: \(slope(summary.renderedTokensPerMessage)) rendered tok/msg,"
                + " \(slope(summary.prefillMSPerMessage)) prefill ms/msg,"
                + " \(slope(summary.totalPrefillMSPerMessage)) total prefill ms/msg"
        )
        return lines.joined(separator: "\n")
    }
}
