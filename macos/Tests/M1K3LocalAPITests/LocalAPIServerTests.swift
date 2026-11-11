//
//  LocalAPIServerTests.swift
//  M1K3LocalAPITests
//
//  The listener end to end over a real loopback socket: one buffered call, one
//  streamed call, and a refused one, through URLSession. Proves the shell reads
//  a request, writes a reply's pieces in order and closes.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.75, Prior: none (new file)
//

import Foundation
import M1K3Inference
@testable import M1K3LocalAPI
import Testing

@Suite(.serialized)
struct LocalAPIServerTests {
    private static func backend() -> LocalAPIBackend {
        LocalAPIBackend(
            models: { ["mini-m1k3"] },
            userBusy: { false },
            complete: { _, request in
                AsyncThrowingStream { continuation in
                    continuation.yield(.delta("You said: "))
                    continuation.yield(.delta(request.question))
                    continuation.yield(.finished(.init(reason: .stop, promptTokens: 3, completionTokens: 4)))
                    continuation.finish()
                }
            }
        )
    }

    /// A server on a free port (a few tries: a port can be taken on a busy machine).
    private func started() async throws -> LocalAPIServer {
        var lastError: (any Error)?
        for _ in 0 ..< 8 {
            let port = UInt16.random(in: 20000 ... 60000)
            let handler = LocalAPIHandler(port: port, token: { "test-token" }, backend: Self.backend())
            let server = LocalAPIServer(port: port, handler: handler)
            do {
                try await server.start()
                return server
            } catch {
                lastError = error
            }
        }
        throw try #require(lastError)
    }

    private func call(
        _ server: LocalAPIServer, _ method: String, _ path: String, json: [String: Any]? = nil, token: String? = "test-token"
    ) async throws -> (Int, String) {
        var request = try URLRequest(url: #require(URL(string: "http://127.0.0.1:\(server.port)\(path)")))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
    }

    @Test("a real client lists models, chats buffered and streamed, and is refused without the token")
    func endToEnd() async throws {
        let server = try await started()
        defer { Task { await server.stop() } }

        let (listStatus, list) = try await call(server, "GET", "/v1/models")
        #expect(listStatus == 200 && list.contains("\"mini-m1k3\""))

        let chat: [String: Any] = ["model": "mini-m1k3", "messages": [["role": "user", "content": "ping"]]]
        let (status, body) = try await call(server, "POST", "/v1/chat/completions", json: chat)
        #expect(status == 200)
        #expect(body.contains("\"content\":\"You said: ping\"") && body.contains("\"total_tokens\":7"))

        var streamed = chat
        streamed["stream"] = true
        let (streamStatus, events) = try await call(server, "POST", "/v1/chat/completions", json: streamed)
        #expect(streamStatus == 200)
        #expect(events.contains("\"content\":\"You said: \"") && events.contains("\"content\":\"ping\""))
        #expect(events.hasSuffix("data: [DONE]\n\n"))

        let (refused, _) = try await call(server, "GET", "/v1/models", token: nil)
        #expect(refused == 401)
        let (wrong, _) = try await call(server, "GET", "/v1/models", token: "nope")
        #expect(wrong == 401)
        let (missing, message) = try await call(server, "POST", "/v1/embeddings", json: [:])
        #expect(missing == 404 && message.contains("unsupported_endpoint"))
    }

    @Test("a second server on the same port fails to start, and says so")
    func portInUse() async throws {
        let server = try await started()
        defer { Task { await server.stop() } }
        let handler = LocalAPIHandler(port: server.port, token: { "t" }, backend: Self.backend())
        let second = LocalAPIServer(port: server.port, handler: handler)
        await #expect(throws: (any Error).self) { try await second.start() }
        #expect(await !second.isRunning)
    }
}
