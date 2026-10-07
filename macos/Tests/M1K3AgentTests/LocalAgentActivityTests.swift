//
//  LocalAgentActivityTests.swift
//  M1K3AgentTests
//
//  One GenerationActivity hold spans a whole agent turn — every generation AND the tool
//  execution between them — so an MCP `ask_m1k3` overnight is one assertion with no unheld
//  gaps for macOS to throttle (PR #498 review). Nested provider-level holds share it.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Synchronization
import Testing

private final class ActivityLog: ActivityAsserting, Sendable {
    let entries = Mutex<[String]>([])
    func begin(reason: String) -> ActivityToken {
        entries.withLock { $0.append("begin:\(reason)") }
        return ActivityToken(NSObject())
    }

    func end(_: ActivityToken) {
        entries.withLock { $0.append("end") }
    }

    func note(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }

    var all: [String] {
        entries.withLock { $0 }
    }
}

/// Answers from a script and writes each generation into the activity log.
private final class ProbeProvider: InferenceProvider, @unchecked Sendable {
    let name = "probe"
    let isAvailable = true
    private let log: ActivityLog
    private let script = Mutex<[String]>([])

    init(_ log: ActivityLog, script: [String]) {
        self.log = log
        self.script.withLock { $0 = script }
    }

    func generate(prompt _: String) async throws -> String {
        log.note("generate")
        return script.withLock { $0.isEmpty ? "CONCLUSION: done" : $0.removeFirst() }
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

struct LocalAgentActivityTests {
    @Test("one hold spans the whole turn: every generation sits between one begin and one end")
    func oneHoldPerTurn() async throws {
        let log = ActivityLog()
        let activity = GenerationActivity(asserter: log)
        let provider = ProbeProvider(log, script: ["THOUGHT: think more", "CONCLUSION: done"])
        let agent = LocalAgent(inferenceProvider: provider, tools: [], maxIterations: 3, activity: activity)
        _ = try await agent.run(goal: "hello")
        let entries = log.all
        #expect(entries.first == "begin:M1K3 agent turn")
        #expect(entries.last == "end")
        #expect(entries.count(where: { $0.hasPrefix("begin") }) == 1)
        #expect(entries.contains("generate"))
    }

    @Test("a turn that throws still ends its hold")
    func endsOnThrow() async {
        struct Boom: Error {}
        final class Failing: InferenceProvider, @unchecked Sendable {
            let name = "failing"
            let isAvailable = true
            func generate(prompt _: String) async throws -> String {
                throw Boom()
            }

            func generateStreaming(prompt _: String) -> AsyncStream<String> {
                AsyncStream { $0.finish() }
            }
        }
        let log = ActivityLog()
        let agent = LocalAgent(inferenceProvider: Failing(), tools: [], activity: GenerationActivity(asserter: log))
        _ = try? await agent.run(goal: "hello")
        #expect(log.all == ["begin:M1K3 agent turn", "end"])
    }
}
