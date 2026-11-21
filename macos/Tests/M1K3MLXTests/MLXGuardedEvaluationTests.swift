import Foundation
import M1K3Inference
import M1K3LogCore
@testable import M1K3MLX
import MLX
import Testing

/// #858: iOS refuses GPU work in the background, and an MLX error with no handler in scope is a `fatalError`.
/// MLX cannot run under `swift test` (the metallib wall), so the translation is tested pure and the placement of
/// the guard is pinned on the source. The refusal itself is verify-by-launch on a phone.
struct MLXGuardedEvaluationTests {
    @Test("a refused GPU submit while the turn is being stopped reads as a stop")
    func refusalDuringAStopIsACancellation() {
        let refused = MLXError.caught("[METAL] Command buffer execution failed: Insufficient Permission")
        #expect(MLXGuardedEvaluation.translate(refused, cancelled: true) is CancellationError)
    }

    @Test("any other MLX failure is a generation failure the turn already knows how to end on")
    func otherFailureIsGenerationFailed() throws {
        let failed = MLXGuardedEvaluation.translate(MLXError.caught("boom"), cancelled: false)
        let error = try #require(failed as? InferenceError)
        #expect(error == .generationFailed("MLX: boom"))
    }

    @Test("an error that is not MLX's passes through untouched")
    func foreignErrorsPass() {
        let passed = MLXGuardedEvaluation.translate(InferenceError.providerUnavailable("x"), cancelled: true)
        #expect(passed as? InferenceError == .providerUnavailable("x"))
    }

    @Test("a body that succeeds returns its value, and a body's own throw is not rewritten")
    func runIsTransparent() async throws {
        let value = try await MLXGuardedEvaluation.run { 42 }
        #expect(value == 42)
        await #expect(throws: InferenceError.self) {
            try await MLXGuardedEvaluation.run { throw InferenceError.generationFailed("own") }
        }
    }

    // MARK: In flight (#862)

    @Test("an evaluation counts as in flight from the scope's start to its end, and nests")
    func countsWhileRunning() async throws {
        let counter = MLXEvaluationCounter()
        #expect(!counter.any)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (started, began) = AsyncStream<Void>.makeStream()
        let outer = Task {
            try await MLXGuardedEvaluation.run(counting: counter) {
                try await MLXGuardedEvaluation.run(counting: counter) {
                    began.yield()
                    for await _ in gate {
                        break
                    }
                }
            }
        }
        for await _ in started {
            break
        }
        #expect(counter.any)
        #expect(counter.current == 2)
        open.yield()
        try await outer.value
        #expect(!counter.any)
    }

    @Test("a throwing body still ends its count")
    func countEndsOnThrow() async {
        let counter = MLXEvaluationCounter()
        await #expect(throws: InferenceError.self) {
            try await MLXGuardedEvaluation.run(counting: counter) { throw InferenceError.generationFailed("own") }
        }
        #expect(!counter.any)
    }

    // MARK: Placement (source scan)

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/M1K3MLX")

    private func text(_ name: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// Probes and benches drive MLX from the selftest harness, not from a turn.
    private func brainFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("MLXBrainProvider") || $0.lastPathComponent == "MLXToolCalling.swift" }
            .filter { !$0.lastPathComponent.contains("Probe") }
    }

    @Test("every file that drives a generation or a load runs it inside the MLX error scope")
    func everyDriverIsGuarded() throws {
        let drivers = ["MLXLMCommon.generate(", ".streamDetails(", ".loadContainer("]
        var checked = 0
        for file in try brainFiles() where file.lastPathComponent != "MLXBrainProvider+SeededPlainTurn.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            guard code.contains(where: { line in drivers.contains { line.contains($0) } }) else { continue }
            checked += 1
            #expect(source.contains("MLXGuardedEvaluation."), "\(file.lastPathComponent) drives MLX with no guard")
        }
        #expect(checked >= 6, "the scan found the brain files")
    }

    @Test("the seeded plain turn has no guard of its own: its two callers are the guarded entries")
    func seededTurnIsOnlyCalledFromGuardedEntries() throws {
        let brain = try text("MLXBrainProvider.swift")
        let calls = brain.split(separator: "\n").filter { $0.contains("try await runSeededPlainTurn(") }
        #expect(calls.count == 2, "generate and generateStreaming; a new caller must bring its own scope")
        #expect(brain.contains("MLXGuardedEvaluation.during(\"M1K3 generate\")"))
    }

    @Test("the streaming doors, the persona prefill and the weights load sit inside the scope")
    func namedEntries() throws {
        let brain = try text("MLXBrainProvider.swift")
        #expect(brain.contains("try await MLXGuardedEvaluation.run { try await container.perform { context in"))
        #expect(brain.components(separatedBy: "do { try await MLXGuardedEvaluation.run {").count == 3,
                "generateStreaming and generateRawStreaming")
        #expect(brain.components(separatedBy: "try await MLXGuardedEvaluation.run {\n").count >= 3, "both load paths")
        #expect(try text("MLXBrainProvider+RawChat.swift").contains("do { try await MLXGuardedEvaluation.run {"))
        let tools = try text("MLXToolCalling.swift")
        #expect(tools.contains("MLXGuardedEvaluation.during(\"M1K3 tool turn\")"))
        #expect(tools.contains("MLXGuardedEvaluation.during(\"M1K3 agent step\")"))
    }

    // MARK: The ledger (2026-11-21: 15 iPhone crash logs, none with MLX's message)

    private func tempLedger() -> MLXFailureLedger {
        MLXFailureLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-ledger-\(UUID().uuidString)").appendingPathComponent("l.json"))
    }

    @Test("an MLX error the scope catches is written to the ledger, so the next report can say what failed")
    func caughtErrorIsRecorded() async {
        let ledger = tempLedger()
        await #expect(throws: InferenceError.self) {
            try await MLXGuardedEvaluation.run(recording: ledger) { throw MLXError.caught("[metal::malloc] boom") }
        }
        let lines = ledger.lines()
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("[metal::malloc] boom") == true)
    }

    @Test("the body's own throw is not an MLX failure and stays out of the ledger")
    func ownThrowIsNotRecorded() async {
        let ledger = tempLedger()
        await #expect(throws: InferenceError.self) {
            try await MLXGuardedEvaluation.run(recording: ledger) { throw InferenceError.generationFailed("own") }
        }
        #expect(ledger.lines().isEmpty)
    }

    @Test("a stopped turn's MLX error is the stop's own fallout and stays out of the ledger")
    func cancelledErrorIsNotRecorded() async {
        let ledger = tempLedger()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (started, began) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await MLXGuardedEvaluation.run(recording: ledger) {
                began.yield()
                for await _ in gate {
                    break
                }
                throw MLXError.caught("[METAL] Insufficient Permission (to submit GPU work from background)")
            }
        }
        for await _ in started {
            break
        }
        task.cancel()
        open.yield()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ledger.lines().isEmpty)
    }

    @Test("the forced-failure drills exist only in a Debug build")
    func drillsAreDebugOnly() throws {
        let source = try text("MLXGuardedEvaluation.swift")
        // The code that reads the flags, not the header that names them.
        let drill = try #require(source.range(of: "forKey: \"forceMLXError\""))
        let debug = try #require(source.range(of: "#if DEBUG\n    /// Debug-only drills"))
        #expect(debug.lowerBound < drill.lowerBound)
        #expect(source.contains("forKey: \"forceMLXCrash\""))
        #expect(source.contains("#if DEBUG\n                    try MLXFailureDrill.failIfAsked()"), "the scope's call is Debug-only too")
    }
}
