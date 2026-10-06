//
//  ChatEvalReport.swift
//  M1K3Eval
//
//  The money artifact: a cross-brain scorecard you can read at a glance. Rows
//  are task-kinds, columns are brains; each cell is "passed/total ⌀latency",
//  with an overall row underneath. This is what turns "AFM feels weaker at
//  chat" into a number, and what the EscalationLadder policy cites as evidence.
//
//  Pure formatting over [ChatEvalScore] — the same scores the unit tests feed
//  in. No model, no I/O.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.88. Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.85 — n/a scores (vision on a blind
//  brain) leave totals, pass counts and latency; a kind that is all n/a shows "n/a", not "—".

import Foundation

public enum ChatEvalReport {
    /// One brain's run: its id and every fixture score, in fixture order.
    public struct BrainRun: Sendable, Equatable, Codable {
        public let brainID: String
        /// The model that actually ran under this tier's name (hub id or local
        /// path) — nil for tiers with no swappable model (Mini). Without it an
        /// A/B override leaves no trace in the transcript, and a matrix column
        /// labelled "big" can be any model at all.
        public let modelID: String?
        public let scores: [ChatEvalScore]
        /// MLX's peak memory over this brain's run (MB), reset before it loads —
        /// the bake-off's RAM gate. Includes whatever MLX holds resident beside it,
        /// and the embedder loads lazily INSIDE the first brain's run (later brains
        /// see it as resident) — so compare `ownPeakMemoryMB` from one-brain-per-
        /// launch runs. nil for non-MLX columns and runs recorded before 2026-10-06.
        public let peakMemoryMB: Int?
        /// MLX memory already resident when this brain started (MB) — an earlier
        /// brain in the same launch, the embedder. A multi-brain launch on
        /// 2026-10-06 put Big at 13.5 GB against its 7.4 GB alone; this is the
        /// part that wasn't Big's.
        public let residentMemoryMBAtStart: Int?

        public init(
            brainID: String, modelID: String? = nil, scores: [ChatEvalScore],
            peakMemoryMB: Int? = nil, residentMemoryMBAtStart: Int? = nil
        ) {
            self.brainID = brainID
            self.modelID = modelID
            self.scores = scores
            self.peakMemoryMB = peakMemoryMB
            self.residentMemoryMBAtStart = residentMemoryMBAtStart
        }

        /// What the brain itself added over what was resident — the RAM gate's
        /// number. nil unless both halves were recorded, and nil when peak sits
        /// below resident (a brain that never loaded, or a predecessor released
        /// mid-run): no number beats a negative or a wrong one.
        public var ownPeakMemoryMB: Int? {
            guard let peakMemoryMB, let residentMemoryMBAtStart, peakMemoryMB >= residentMemoryMBAtStart else {
                return nil
            }
            return peakMemoryMB - residentMemoryMBAtStart
        }

        /// `big [mlx-community/…]` when the model is known, else the bare tier.
        var label: String {
            modelID.map { "\(brainID) [\($0)]" } ?? brainID
        }

        /// The scores that count: everything but n/a (a vision turn put to a
        /// brain that can't see). Totals, pass counts and latency read these.
        var applicable: [ChatEvalScore] {
            scores.filter(\.isApplicable)
        }

        public var passedCount: Int {
            applicable.filter(\.passed).count
        }

        public var total: Int {
            applicable.count
        }

        public var notApplicableCount: Int {
            scores.count - applicable.count
        }

        /// Median turn latency across this brain's fixtures (0 if none).
        public var medianLatencyMS: Int {
            medianOf(applicable.map(\.latencyMS))
        }

        func scores(for kind: TaskKind) -> [ChatEvalScore] {
            applicable.filter { $0.kind == kind }
        }

        func hasOnlyNotApplicable(_ kind: TaskKind) -> Bool {
            scores(for: kind).isEmpty && scores.contains { $0.kind == kind && !$0.isApplicable }
        }
    }

    /// The per-fixture detail blocks — verbose, for eyeballing why a cell is
    /// what it is (P1 "side-by-side" reading).
    public static func verbose(_ runs: [BrainRun]) -> String {
        var lines: [String] = []
        for run in runs {
            lines.append("--- \(run.label): \(run.passedCount)/\(run.total) "
                + "(median \(run.medianLatencyMS)ms) ---")
            for score in run.scores {
                lines.append(score.rendered)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The headline matrix: task-kind rows × brain columns, each cell
    /// "passed/total ⌀Lms", plus an overall row. Columns follow `runs` order.
    public static func matrix(_ runs: [BrainRun]) -> String {
        guard !runs.isEmpty else { return "chateval: no runs" }

        let firstCol = "task-kind"
        let brainCols = runs.map(\.brainID)
        // Width each column to its widest cell so the table lines up.
        let rowLabelWidth = max(
            firstCol.count,
            TaskKind.allCases.map { $0.label.count }.max() ?? 0,
            "overall".count
        )

        func cell(passed: Int, total: Int, latency: Int) -> String {
            total == 0 ? "—" : "\(passed)/\(total) \(latency)ms"
        }

        // Pre-compute every cell so columns can be width-matched.
        var rows: [(label: String, cells: [String])] = []
        for kind in TaskKind.allCases {
            let cells = runs.map { run -> String in
                if run.hasOnlyNotApplicable(kind) { return "n/a" }
                let kindScores = run.scores(for: kind)
                let passed = kindScores.filter(\.passed).count
                let latency = medianOf(kindScores.map(\.latencyMS))
                return cell(passed: passed, total: kindScores.count, latency: latency)
            }
            rows.append((kind.label, cells))
        }
        let overallCells = runs.map { run in
            cell(passed: run.passedCount, total: run.total, latency: run.medianLatencyMS)
        }
        rows.append(("overall", overallCells))

        let colWidths = brainCols.indices.map { col -> Int in
            max(brainCols[col].count, rows.map { $0.cells[col].count }.max() ?? 0)
        }

        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        var out = ["=== CHATEVAL MATRIX (passed/total ⌀latency) ==="]
        let header = pad(firstCol, rowLabelWidth) + " | "
            + brainCols.indices.map { pad(brainCols[$0], colWidths[$0]) }.joined(separator: " | ")
        out.append(header)
        out.append(String(repeating: "-", count: header.count))
        for row in rows {
            if row.label == "overall" {
                out.append(String(repeating: "-", count: header.count))
            }
            let line = pad(row.label, rowLabelWidth) + " | "
                + row.cells.indices.map { pad(row.cells[$0], colWidths[$0]) }.joined(separator: " | ")
            out.append(line)
        }
        // Legend: which model stood behind each column. Columns stay the short
        // tier name so the table keeps its width; the legend keeps it honest.
        let legend = runs.compactMap { run in run.modelID.map { "\(run.brainID) = \($0)" } }
        if !legend.isEmpty {
            out.append(String(repeating: "-", count: header.count))
            out.append(contentsOf: legend)
        }
        return out.joined(separator: "\n")
    }

    /// Whole report: the matrix headline followed by the verbose per-fixture
    /// detail — what the self-test stage writes to M1K3_SELFTEST_OUT.
    public static func full(_ runs: [BrainRun]) -> String {
        matrix(runs) + "\n\n" + verbose(runs)
    }
}

/// Median of an int list (lower-middle on even counts); 0 when empty. Shared by
/// BrainRun and the matrix cells.
func medianOf(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[(sorted.count - 1) / 2]
}
