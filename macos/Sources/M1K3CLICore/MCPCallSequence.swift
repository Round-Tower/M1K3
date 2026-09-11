//
//  MCPCallSequence.swift
//  M1K3CLICore
//
//  One tool call, start to finish, including the two things that go wrong:
//  nothing is listening yet, and the server has no session yet. The posting
//  itself is injected (URLSession lives in the executable), so the ORDER of
//  requests — the part with consequences — is unit-pinned.
//
//  Two rules are load-bearing here, both learned the hard way:
//
//  1. The tool body is posted at most ONCE per successful call. Polling a cold
//     app with the real body and then posting it again makes `remember` store
//     twice, `speak` speak twice, and `ask` collide with its own single-flight
//     lock. The poll uses `tools/list` — read-only, so a hundred polls change
//     nothing.
//  2. `initialize` is only ever sent in recovery. The app's LocalMCPHTTPServer
//     rebuilds its session on every initialize and re-stamps the notch HUD's
//     visitor name, so a speculative handshake evicts whichever coding agent
//     is actually connected.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (request order and
//  the cold-start count are pinned against a fake server; the real poster
//  behind the seam is verify-by-run). Prior: Unknown.
//

import Foundation

/// What an HTTP answer amounts to here: a status and a body. Both matter —
/// see `JSONRPC.Reply.parse(status:body:)` for why the status never wins on
/// its own.
public struct MCPHTTPAnswer: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Why a call could not be completed.
public enum CallFailure: Error, Equatable, Sendable {
    /// Nothing is answering on the loopback port, even after opening the app.
    case unreachable(String)
    /// The server answered, and the answer was a refusal.
    case tool(String)
}

public struct MCPCallSequence: Sendable {
    /// Posts a body and returns what came back. Throws
    /// `CallFailure.unreachable` when nothing is listening.
    public typealias Post = @Sendable (Data) async throws -> MCPHTTPAnswer
    /// Opens M1K3. `false` means we couldn't even try.
    public typealias Wake = @Sendable () -> Bool

    /// How patiently to wait for a cold app. The listener binds early — the
    /// brain loads afterwards — so 20s is generous.
    public struct Timing: Sendable {
        public let pollInterval: Duration
        public let attempts: Int

        public init(pollInterval: Duration, attempts: Int) {
            self.pollInterval = pollInterval
            self.attempts = attempts
        }

        public static let live = Timing(pollInterval: .milliseconds(500), attempts: 40)
    }

    private let port: UInt16
    private let clientVersion: String
    private let timing: Timing
    private let post: Post
    private let wake: Wake

    public init(
        port: UInt16,
        clientVersion: String,
        timing: Timing = .live,
        post: @escaping Post,
        wake: @escaping Wake
    ) {
        self.port = port
        self.clientVersion = clientVersion
        self.timing = timing
        self.post = post
        self.wake = wake
    }

    public func call(tool: String, arguments: [String: JSONValue]) async -> Result<String, CallFailure> {
        let body: Data
        do {
            body = try JSONRPC.toolsCall(name: tool, arguments: arguments)
        } catch {
            return .failure(.tool("couldn't build the request: \(error.localizedDescription)"))
        }

        do {
            let answer = try await postWakingIfNeeded(body)
            return await outcome(of: JSONRPC.Reply.parse(status: answer.status, body: answer.body), body: body)
        } catch let failure as CallFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    // MARK: - The two recoveries

    private func outcome(of reply: JSONRPC.Reply, body: Data) async -> Result<String, CallFailure> {
        switch reply {
        case let .text(text):
            return .success(text)
        case let .error(_, message):
            return .failure(.tool(message))
        case .notInitialized:
            // Nobody holds the session, so claiming it evicts nothing.
            do {
                _ = try await post(JSONRPC.initialize(clientVersion: clientVersion))
                let retry = try await post(body)
                switch JSONRPC.Reply.parse(status: retry.status, body: retry.body) {
                case let .text(text): return .success(text)
                case let .error(_, message): return .failure(.tool(message))
                case .notInitialized: return .failure(.tool("M1K3's MCP server wouldn't start a session"))
                }
            } catch let failure as CallFailure {
                return .failure(failure)
            } catch {
                return .failure(.unreachable(error.localizedDescription))
            }
        }
    }

    /// Post; if nothing is listening, open M1K3, wait until it answers a
    /// read-only probe, then post the real body — exactly once.
    private func postWakingIfNeeded(_ body: Data) async throws -> MCPHTTPAnswer {
        do {
            return try await post(body)
        } catch let failure as CallFailure {
            guard case .unreachable = failure else { throw failure }
            guard wake() else { throw notRunning }
            guard await waitUntilAnswering() else { throw notRunning }
            return try await post(body)
        }
    }

    /// ANY answer proves the server is up: a freshly-launched app answers
    /// `tools/list` with a 4xx "not initialized" envelope, and that is still
    /// an answer. Only a refused connection means "not yet".
    private func waitUntilAnswering() async -> Bool {
        guard let probe = try? JSONRPC.toolsList() else { return false }
        for _ in 0 ..< timing.attempts {
            try? await Task.sleep(for: timing.pollInterval)
            if (try? await post(probe)) != nil { return true }
        }
        return false
    }

    private var notRunning: CallFailure {
        .unreachable("""
        M1K3 isn't running (open it from Applications)
        — or its MCP server is off: M1K3 ▸ Settings ▸ Privacy ▸ MCP server (127.0.0.1:\(port)).
        """)
    }
}
