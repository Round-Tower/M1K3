//
//  MCPCallSequenceTests.swift
//  M1K3CLICoreTests
//
//  The call orchestration — the part with teeth. Two bugs live here if nobody
//  writes them down: a cold start that runs the tool TWICE (poll with the real
//  body, then post it again — `remember` stores twice, `speak` speaks twice),
//  and a `.notInitialized` recovery that never fires because the SDK answers
//  protocol errors with a 4xx and a status-first reading throws before the
//  envelope is ever read.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (both failures are
//  pinned by counting what the server was actually handed; the real URLSession
//  poster behind this seam stays verify-by-run). Prior: Unknown.
//

import Foundation
@testable import M1K3CLICore
import Testing

/// Records every request the server was actually HANDED (a refused post never
/// reached it), so a test can count how many times a tool really ran.
private actor FakeServer {
    private(set) var delivered: [Data] = []
    private var refusalsLeft: Int
    private var answers: [MCPHTTPAnswer]

    init(refusals: Int = 0, answers: [MCPHTTPAnswer]) {
        refusalsLeft = refusals
        self.answers = answers
    }

    func post(_ body: Data) async throws -> MCPHTTPAnswer {
        if refusalsLeft > 0 {
            refusalsLeft -= 1
            throw CallFailure.unreachable("connection refused")
        }
        delivered.append(body)
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }

    /// `method` of each delivered request, in order.
    func methods() -> [String] {
        delivered.compactMap {
            ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["method"] as? String
        }
    }

    func toolNames() -> [String] {
        delivered.compactMap {
            let root = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            return (root?["params"] as? [String: Any])?["name"] as? String
        }
    }
}

private func answer(_ status: Int, _ json: String) -> MCPHTTPAnswer {
    MCPHTTPAnswer(status: status, body: Data(json.utf8))
}

private let okText = answer(200, #"{"result":{"content":[{"type":"text","text":"ok"}]}}"#)

struct MCPCallSequenceTests {
    private let brisk = MCPCallSequence.Timing(pollInterval: .milliseconds(1), attempts: 5)

    private func sequence(
        _ server: FakeServer,
        timing: MCPCallSequence.Timing,
        wake: @escaping @Sendable () -> Bool = { true }
    ) -> MCPCallSequence {
        MCPCallSequence(
            port: 4242,
            clientVersion: "1.0.0",
            timing: timing,
            post: { try await server.post($0) },
            wake: wake
        )
    }

    @Test("the happy path is one post and no handshake — the live session keeps its identity")
    func warmCall() async throws {
        let server = FakeServer(answers: [okText])
        let result = await sequence(server, timing: brisk).call(tool: "get_status", arguments: [:])
        #expect(try result.get() == "ok")
        #expect(await server.methods() == ["tools/call"])
    }

    @Test("★ a cold start runs the tool ONCE — the poll uses a read-only probe, not the real body")
    func coldStartRunsTheToolOnce() async throws {
        // Refused twice: the first real attempt, then the first poll.
        let server = FakeServer(refusals: 2, answers: [okText])
        let result = await sequence(server, timing: brisk)
            .call(tool: "remember", arguments: ["text": .string("once, please")])
        #expect(try result.get() == "ok")
        #expect(await server.methods() == ["tools/list", "tools/call"])
        #expect(await server.toolNames() == ["remember"])
    }

    @Test("★ a 4xx that carries a JSON-RPC envelope is read as the envelope, so the handshake fires")
    func fourHundredNotInitializedRecovers() async throws {
        let server = FakeServer(answers: [
            answer(400, #"{"error":{"code":-32600,"message":"Invalid Request: Server is not initialized"}}"#),
            answer(200, #"{"result":{"protocolVersion":"2025-06-18"}}"#),
            okText,
        ])
        let result = await sequence(server, timing: brisk).call(tool: "get_status", arguments: [:])
        #expect(try result.get() == "ok")
        #expect(await server.methods() == ["tools/call", "initialize", "tools/call"])
    }

    @Test("a server that never comes back names the port instead of hanging")
    func neverAnswers() async {
        let server = FakeServer(refusals: .max, answers: [okText])
        let result = await sequence(server, timing: brisk).call(tool: "get_status", arguments: [:])
        guard case let .failure(.unreachable(message)) = result else {
            Issue.record("expected unreachable, got \(result)")
            return
        }
        #expect(message.contains("4242"))
        #expect(message.contains("isn't running"))
    }

    @Test("if the app can't be opened at all, give up at once rather than poll for twenty seconds")
    func wakeRefused() async {
        let server = FakeServer(refusals: .max, answers: [okText])
        let result = await sequence(server, timing: brisk, wake: { false })
            .call(tool: "get_status", arguments: [:])
        guard case .failure(.unreachable) = result else {
            Issue.record("expected unreachable, got \(result)")
            return
        }
        #expect(await server.methods().isEmpty)
    }

    @Test("a tool that failed is a tool error, not an unreachable one")
    func toolError() async {
        let server = FakeServer(answers: [
            answer(200, #"{"result":{"isError":true,"content":[{"type":"text","text":"Unknown tool: yodel"}]}}"#),
        ])
        let result = await sequence(server, timing: brisk).call(tool: "yodel", arguments: [:])
        #expect(result == .failure(.tool("Unknown tool: yodel")))
    }
}
