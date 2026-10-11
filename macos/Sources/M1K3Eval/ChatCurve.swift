//
//  ChatCurve.swift
//  M1K3Eval
//
//  The chat-curve instrument's pure half (GEMMA_1_1_PLAN.md, "Qwen3.5 cross-turn
//  checkpoint: measure a scripted chat's prefill curve FIRST"). A fixed script of eight
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
//

import Foundation

/// The fixed eight-message script. Short and varied so the history grows by a few dozen
/// tokens a turn: the curve then isolates what the CACHE does, not what the user typed.
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
    ]
}

public struct ChatCurveReuse: Sendable, Equatable, Codable {
    public let reused: Int
    public let total: Int

    public init(reused: Int, total: Int) {
        self.reused = reused
        self.total = total
    }
}

public struct ChatCurveGeneration: Sendable, Equatable, Codable {
    public let promptTokens: Int
    public let prefillMS: Int

    public init(promptTokens: Int, prefillMS: Int) {
        self.promptTokens = promptTokens
        self.prefillMS = prefillMS
    }
}

/// One turn's log lines folded to figures. Optionals stay nil when no line was seen.
public struct ChatCurveFolded: Sendable, Equatable {
    public let reuse: ChatCurveReuse?
    public let promptTokens: Int?
    public let prefillMS: Int?
    public let generations: Int
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
        entries.compactMap { entry in
            guard entry.date >= since else { return nil }
            if generation(in: entry.message) != nil, !entry.message.hasPrefix("\(label) [") { return nil }
            return entry.message
        }
    }

    /// `toolTurnSession reuse: 2301/2650 tok from cache, …`
    public static func reuse(in line: String) -> ChatCurveReuse? {
        guard let match = line.firstMatch(of: /toolTurnSession reuse: (\d+)\/(\d+) tok/),
              let reused = Int(match.1), let total = Int(match.2)
        else { return nil }
        return ChatCurveReuse(reused: reused, total: total)
    }

    /// `label [model]: prompt=349tok prefill=812ms decode=…`
    public static func generation(in line: String) -> ChatCurveGeneration? {
        guard let match = line.firstMatch(of: /prompt=(\d+)tok prefill=(\d+)ms/),
              let tokens = Int(match.1), let ms = Int(match.2)
        else { return nil }
        return ChatCurveGeneration(promptTokens: tokens, prefillMS: ms)
    }

    /// A message can run several generations (tool iterations): the LAST reuse line is the
    /// turn's final render; prompt tokens and prefill time are paid by every generation.
    public static func fold(_ lines: [String]) -> ChatCurveFolded {
        var reuse: ChatCurveReuse?
        var generations: [ChatCurveGeneration] = []
        for line in lines {
            if let found = Self.reuse(in: line) { reuse = found }
            if let found = generation(in: line) { generations.append(found) }
        }
        return ChatCurveFolded(
            reuse: reuse,
            promptTokens: generations.isEmpty ? nil : generations.map(\.promptTokens).reduce(0, +),
            prefillMS: generations.isEmpty ? nil : generations.map(\.prefillMS).reduce(0, +),
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

    public init(
        index: Int, question: String, renderedTokens: Int?, reusedTokens: Int?, promptTokens: Int?,
        prefillMS: Int?, generations: Int, peakRSSMB: Int, answerChars: Int
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
    }

    public var reuseFraction: Double? {
        guard let renderedTokens, let reusedTokens, renderedTokens > 0 else { return nil }
        return Double(reusedTokens) / Double(renderedTokens)
    }
}

public struct ChatCurveSummary: Sendable, Equatable, Codable {
    /// Least-squares slope of rendered prompt tokens per message (how fast the prompt grows).
    public let renderedTokensPerMessage: Double?
    /// Least-squares slope of prefill ms per message (what the growth costs; ~0 = cache holds).
    public let prefillMSPerMessage: Double?

    public init(samples: [ChatCurveSample]) {
        renderedTokensPerMessage = Self.slope(
            samples.compactMap { s in s.renderedTokens.map { (s.index, Double($0)) } }
        )
        prefillMSPerMessage = Self.slope(
            samples.compactMap { s in s.prefillMS.map { (s.index, Double($0)) } }
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
                + " gens=\(s.generations) rss=\(s.peakRSSMB)MB"
        }
        lines.append(
            "chatcurve slope [\(modelID)]: \(slope(summary.renderedTokensPerMessage)) rendered tok/msg,"
                + " \(slope(summary.prefillMSPerMessage)) prefill ms/msg"
        )
        return lines.joined(separator: "\n")
    }
}
