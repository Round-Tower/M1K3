//
//  MetricLogReader.swift
//  M1K3App
//
//  The app's own generation metrics, read back off OSLogStore for a headless stage: the tool
//  session's `reuse:` and `send N:` lines (category mlx-load) and every path's `ttft` line, windowed
//  to one turn by date and folded by ChatCurveLogParser. ChatCurveStage grew this for the prefill
//  curve (#522, #530); the chat eval reads the same lines per trial since 2026-10-25, so a scorecard
//  carries prefill, extend, decode and throughput beside wall-clock latency. No inference code is
//  touched: the figures are what the app already logs.
//
//  Entries land a beat after the call, so `foldTurn` polls until the generation count holds across
//  two polls, capped — a turn that logged nothing still folds to nils, never zeros.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-25, Confidence 0.75 (glue over TDD'd parsing; the OSLogStore
//  read is verify-by-launch, as ChatCurveStage's was). Prior: none (new file; lifted from ChatCurveStage).
//

import Foundation
import M1K3Eval
import OSLog

enum MetricLogReader {
    /// The metric entries since `date`, oldest first. The store's position is a hint only;
    /// `ChatCurveLogParser.turnLines` re-checks the date (the first Big curve read cumulative sums
    /// because the position was not honoured, #530).
    static func entries(since date: Date) -> [ChatCurveLogEntry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: date))
        else { return [] }
        return entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "app.m1k3" && ($0.category == "ttft" || $0.category == "mlx-load") }
            .map { ChatCurveLogEntry(date: $0.date, message: $0.composedMessage) }
    }

    /// One turn's figures: poll until its generation lines have landed (a tool turn logs one per
    /// iteration), stopping once the count has held across two polls; `polls` × 500 ms is the cap.
    static func foldTurn(
        since started: Date, labels: Set<String> = ChatCurveLogParser.turnLabels, polls: Int = 10
    ) async -> ChatCurveFolded {
        var folded = ChatCurveLogParser.fold([])
        for _ in 0 ..< polls {
            try? await Task.sleep(for: .milliseconds(500))
            let next = ChatCurveLogParser.fold(
                ChatCurveLogParser.turnLines(entries(since: started), since: started, labels: labels)
            )
            let stable = next.generations > 0 && next.generations == folded.generations
            folded = next
            if stable { break }
        }
        return folded
    }
}
