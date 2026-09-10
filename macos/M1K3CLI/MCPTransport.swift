//
//  MCPTransport.swift
//  m1k3
//
//  The wire half of the CLI: one POST per call at the app's loopback MCP
//  server, with two pieces of etiquette that matter more than the plumbing.
//
//  1. NEVER open with `initialize`. LocalMCPHTTPServer sniffs initialize POSTs
//     and rebuilds the (Server, transport) pair — v1 serves one MCP client at a
//     time — and stamps the client's name onto the notch HUD. A CLI that shook
//     hands on every invocation would evict whichever coding agent is actually
//     connected and rename the face on screen. So we send the tools/call first
//     and only handshake if the server says it has no session yet.
//  2. If nothing is listening, open the app and wait rather than failing at
//     the user. `m1k3 status` from a cold Mac should just work.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.8 (frames and
//  reply-reading are unit-pinned in M1K3CLICore; this transport is
//  verify-by-run against the live app — the retry-after-launch window and the
//  refused-connection classification are the parts tests can't reach).
//  Prior: Unknown.
//

import Foundation
import M1K3CLICore

/// Why a call could not be completed.
enum CallFailure: Error {
    /// Nothing is answering on the loopback port, even after opening the app.
    case unreachable(String)
    /// The server answered, and the answer was a refusal.
    case tool(String)
}

struct MCPTransport {
    let port: UInt16
    let clientVersion: String
    private let session: URLSession

    /// How long to wait for the app to come up and start serving. The app has
    /// a brain to load; 20s is generous for the listener, which binds early.
    private static let launchWaitSeconds = 20.0
    private static let launchPollSeconds = 0.5

    init(port: UInt16, clientVersion: String) {
        self.port = port
        self.clientVersion = clientVersion
        let configuration = URLSessionConfiguration.ephemeral
        // A tool call can take a while (a long think returns a job id at the
        // ~8s grace, but speak-with-wait and a big search genuinely run on).
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    /// Built from the same string Settings shows, so the two can't drift.
    private func endpoint() throws -> URL {
        guard let url = URL(string: MCPEndpoint.url(port: port)) else {
            throw CallFailure.unreachable("couldn't build a loopback URL for port \(port)")
        }
        return url
    }

    // MARK: - Calls

    /// Call a tool, handling the two recoverable failures: a cold app, and a
    /// server with no session yet.
    func call(tool: String, arguments: [String: JSONValue]) async -> Result<String, CallFailure> {
        let body: Data
        do {
            body = try JSONRPC.toolsCall(name: tool, arguments: arguments)
        } catch {
            return .failure(.tool("couldn't build the request: \(error.localizedDescription)"))
        }

        var data: Data
        do {
            data = try await postOpeningAppIfNeeded(body)
        } catch let failure as CallFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }

        var reply = JSONRPC.Reply.parse(data)
        if case .notInitialized = reply {
            // The one time we're allowed to shake hands: nobody holds the
            // session, so claiming it evicts nothing.
            do {
                let handshake = try JSONRPC.initialize(clientVersion: clientVersion)
                _ = try await post(handshake)
                data = try await post(body)
                reply = JSONRPC.Reply.parse(data)
            } catch let failure as CallFailure {
                return .failure(failure)
            } catch {
                return .failure(.unreachable(error.localizedDescription))
            }
        }

        switch reply {
        case let .text(text): return .success(text)
        case let .error(_, message): return .failure(.tool(message))
        case .notInitialized: return .failure(.tool("M1K3's MCP server wouldn't start a session"))
        }
    }

    // MARK: - HTTP

    private func post(_ body: Data) async throws -> Data {
        var request = try URLRequest(url: endpoint())
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The SDK's stateless transport validates Accept and answers JSON only.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw CallFailure.tool("M1K3's MCP server answered HTTP \(http.statusCode). \(detail)")
            }
            return data
        } catch let error as URLError where Self.isRefused(error) {
            throw CallFailure.unreachable(error.localizedDescription)
        }
    }

    /// Post; if nothing is listening, open M1K3, wait for the port, post again.
    private func postOpeningAppIfNeeded(_ body: Data) async throws -> Data {
        do {
            return try await post(body)
        } catch let failure as CallFailure {
            guard case .unreachable = failure else { throw failure }
            guard openM1K3() else { throw Self.notRunning(port: port) }
            guard await waitForPort(body: body) else { throw Self.notRunning(port: port) }
            return try await post(body)
        }
    }

    /// Poll the port by simply retrying the real request — a successful POST
    /// is the only proof that matters (a bound socket with no MCP server
    /// behind it would still refuse).
    private func waitForPort(body: Data) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.launchWaitSeconds)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(Self.launchPollSeconds))
            if (try? await post(body)) != nil { return true }
        }
        return false
    }

    private func openM1K3() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "M1K3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // Sandboxed, or M1K3 isn't installed — either way we can't help.
            return false
        }
    }

    private static func isRefused(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            true
        default:
            false
        }
    }

    private static func notRunning(port: UInt16) -> CallFailure {
        .unreachable("""
        M1K3 isn't running (open it from Applications)
        — or its MCP server is off: M1K3 ▸ Settings ▸ Privacy ▸ MCP server (127.0.0.1:\(port)).
        """)
    }
}
