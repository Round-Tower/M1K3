//
//  MCPTransport.swift
//  m1k3
//
//  The wire half of the CLI, and nothing else: one URLSession POST, plus the
//  ability to open M1K3 when nothing is listening. Everything with an ORDER to
//  it — post the tool body once, probe read-only while waiting, handshake only
//  in recovery — lives in M1K3CLICore's MCPCallSequence, where a fake server
//  pins it.
//
//  The status code is NOT judged here. The MCP SDK answers protocol errors
//  with a 4xx carrying a proper JSON-RPC error object, so throwing on non-2xx
//  would hide the one refusal that is recoverable ("Server is not
//  initialized"). `JSONRPC.Reply.parse(status:body:)` does the reading.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.8 (verify-by-run
//  against the live app — URLError classification and the app launch are the
//  parts a unit test can't reach). Prior: Unknown.
//  Review: Kev + claude-opus-5, 2026-09-11 — the sequencing moved into
//  MCPCallSequence after a code-quality pass found a cold start posting the
//  real body TWICE (poll, then post) and a status-first read that made the
//  .notInitialized recovery unreachable. Confidence now 0.85.
//

import Foundation
import M1K3CLICore

enum MCPTransport {
    /// Build the call sequence the runner uses. The poster and the app launch
    /// are the effects; the sequencing is the tested part.
    static func sequence(port: UInt16, clientVersion: String) -> MCPCallSequence {
        let session = makeSession()
        return MCPCallSequence(
            port: port,
            clientVersion: clientVersion,
            post: { body in try await post(body, port: port, session: session) },
            wake: { openM1K3() }
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // A tool call can take a while (a long think hands back a job id at the
        // ~8s grace, but speak-with-wait and a big search genuinely run on).
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    private static func post(_ body: Data, port: UInt16, session: URLSession) async throws -> MCPHTTPAnswer {
        guard let url = URL(string: MCPEndpoint.url(port: port)) else {
            throw CallFailure.unreachable("couldn't build a loopback URL for port \(port)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The SDK's stateless transport validates Accept and answers JSON only.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            return MCPHTTPAnswer(status: status, body: data)
        } catch let error as URLError {
            throw failure(for: error)
        }
    }

    private static func failure(for error: URLError) -> CallFailure {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost:
            // Nothing is listening — the one case worth opening the app for.
            .unreachable(error.localizedDescription)
        case .timedOut:
            // Something IS listening and just took too long. Relaunching would
            // be the wrong answer, and would hide a turn that is still running.
            .tool("M1K3 didn't answer in time — it may still be working; try m1k3 status.")
        default:
            // Including networkConnectionLost: the server accepted and then
            // went away, which a relaunch would paper over.
            .tool("couldn't reach M1K3: \(error.localizedDescription)")
        }
    }

    /// Open the app this binary lives inside, so a DMG copy outside
    /// /Applications wakes ITSELF rather than whichever M1K3 Launch Services
    /// happens to prefer. Falls back to the name when we're not in a bundle
    /// (a build directory, say).
    private static func openM1K3() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = enclosingBundle().map { [$0.path] } ?? ["-a", "M1K3"]
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

    /// `…/M1K3.app/Contents/MacOS/m1k3` → `…/M1K3.app`, or nil when this
    /// binary isn't inside a bundle.
    ///
    /// Bundle.main.executableURL, not argv[0]: invoked through a PATH symlink
    /// argv[0] is just the typed name, and the whole lookup silently fails.
    static func enclosingBundle() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let bundle = executable
            .deletingLastPathComponent() // …/Contents/MacOS
            .deletingLastPathComponent() // …/Contents
            .deletingLastPathComponent() // …/M1K3.app
        return bundle.pathExtension == "app" ? bundle : nil
    }
}
