//
//  LocalAPIHandlerTests.swift
//  M1K3LocalAPITests
//
//  One request through the Local API's handler against a fake brain: what a
//  client receives for a good call, a bad one, a busy Mac, a failing brain, and
//  that one call runs at a time.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.85, Prior: none (new file)
//

import Foundation
import M1K3Inference
@testable import M1K3LocalAPI
import Testing

private final class FakeBrain: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(String, RawChatRequest)] = []
    var events: [RawChatEvent] = [.delta("Hel"), .delta("lo"), .finished(.init(reason: .stop, promptTokens: 4, completionTokens: 2))]
    var failure: (any Error)?
    var unavailable = false
    var userBusy = false
    var held: AsyncThrowingStream<RawChatEvent, any Error>.Continuation?
    var holds = false

    var calls: [(String, RawChatRequest)] {
        lock.withLock { asked }
    }

    var backend: LocalAPIBackend {
        LocalAPIBackend(
            models: { ["mini-m1k3", "lil-m1k3"] },
            userBusy: { self.userBusy },
            complete: { model, request in
                self.lock.withLock { self.asked.append((model, request)) }
                if self.unavailable { return nil }
                return AsyncThrowingStream { continuation in
                    if self.holds {
                        self.lock.withLock { self.held = continuation }
                        return
                    }
                    for event in self.events {
                        continuation.yield(event)
                    }
                    continuation.finish(throwing: self.failure)
                }
            }
        )
    }
}

private final class HandlerBox: @unchecked Sendable {
    var handler: LocalAPIHandler?
}

struct LocalAPIHandlerTests {
    private let token = "s3cret"

    private func handler(_ brain: FakeBrain) -> LocalAPIHandler {
        LocalAPIHandler(port: 4141, token: { "s3cret" }, backend: brain.backend, now: { 1_700_000_000 }, newID: { "chatcmpl-test" })
    }

    private func request(
        _ method: String, _ path: String, body: [String: Any]? = nil, auth: String? = "Bearer s3cret",
        origin: String? = nil
    ) -> LocalAPIRequest {
        var headers = ["host": ["127.0.0.1:4141"]]
        if let auth { headers["authorization"] = [auth] }
        if let origin { headers["origin"] = [origin] }
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return LocalAPIRequest(method: method, path: path, headers: headers, body: data)
    }

    private func chat(_ extra: [String: Any] = [:], model: String = "lil-m1k3") -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Hi"]]]
        body.merge(extra) { _, new in new }
        return body
    }

    /// The whole reply as text (head and body, or head and every event).
    private func text(_ reply: LocalAPIReply) async -> String {
        var data = Data()
        for await piece in reply.pieces {
            data += piece
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func bodyJSON(_ text: String) throws -> [String: Any] {
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    @Test("the model list needs the token and names the brains that are ready")
    func models() async throws {
        let handler = handler(FakeBrain())
        let reply = await text(handler.reply(to: request("GET", "/v1/models")))
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        let ids = try (#require(bodyJSON(reply)["data"] as? [[String: Any]])).map { $0["id"] as? String }
        #expect(ids == ["mini-m1k3", "lil-m1k3"])
        #expect(await text(handler.reply(to: request("GET", "/v1/models", auth: nil))).hasPrefix("HTTP/1.1 401"))
        #expect(await text(handler.reply(to: request("GET", "/v1/models", origin: "https://evil.example"))).hasPrefix("HTTP/1.1 403"))
    }

    @Test("a chat call answers as one object, from the brain that was asked for")
    func chatBuffered() async throws {
        let brain = FakeBrain()
        let reply = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat(["max_tokens": 9]))))
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        let object = try bodyJSON(reply)
        #expect(object["id"] as? String == "chatcmpl-test")
        let choice = try #require((object["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "Hello")
        #expect((object["usage"] as? [String: Any])?["total_tokens"] as? Int == 6)
        #expect(brain.calls.map(\.0) == ["lil-m1k3"])
        #expect(brain.calls.first?.1.maxTokens == 9)
    }

    @Test("a streamed call is role, deltas, a finish chunk, usage when asked, then [DONE]")
    func chatStreamed() async {
        let brain = FakeBrain()
        let body = chat(["stream": true, "stream_options": ["include_usage": true]])
        let reply = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: body)))
        #expect(reply.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream"))
        let events = reply.components(separatedBy: "\r\n\r\n").dropFirst().joined().components(separatedBy: "\n\n").filter { !$0.isEmpty }
        #expect(events.count == 6)
        #expect(events[0].contains("\"role\":\"assistant\""))
        #expect(events[1].contains("\"content\":\"Hel\"") && events[2].contains("\"content\":\"lo\""))
        #expect(events[3].contains("\"finish_reason\":\"stop\""))
        #expect(events[4].contains("\"total_tokens\":6") && events[4].contains("\"choices\":[]"))
        #expect(events[5] == "data: [DONE]")
    }

    @Test("a stop sequence ends the answer and reads as a normal stop")
    func stopSequence() async throws {
        let brain = FakeBrain()
        brain.events = [.delta("one EN"), .delta("D two"), .finished(.init(reason: .length, promptTokens: 1, completionTokens: 9))]
        let reply = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat(["stop": "END"]))))
        let choice = try #require((bodyJSON(reply)["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "one ")
        #expect(choice["finish_reason"] as? String == "stop")
    }

    @Test("what cannot be served says why, in the shape a client parses")
    func refusals() async {
        let brain = FakeBrain()
        let handler = handler(brain)
        func status(_ request: LocalAPIRequest) async -> String {
            String(await text(handler.reply(to: request)).prefix(12))
        }
        #expect(await status(request("POST", "/v1/chat/completions", body: chat(model: "big-m1k3"))) == "HTTP/1.1 404")
        #expect(await status(request("POST", "/v1/chat/completions", body: chat(["tools": [["type": "function"]]]))) == "HTTP/1.1 400")
        #expect(await status(request("POST", "/v1/embeddings", body: [:])) == "HTTP/1.1 404")
        #expect(await status(request("OPTIONS", "/v1/chat/completions")) == "HTTP/1.1 403")
        #expect(await status(request("GET", "/nope")) == "HTTP/1.1 404")
        var chunked = request("POST", "/v1/chat/completions", body: chat())
        chunked = LocalAPIRequest(
            method: chunked.method, path: chunked.path,
            headers: chunked.headers.merging(["transfer-encoding": ["chunked"]]) { _, new in new }, body: Data()
        )
        let chunkedReply = await text(handler.reply(to: chunked))
        #expect(chunkedReply.hasPrefix("HTTP/1.1 400") && chunkedReply.contains("Content-Length"))
        brain.userBusy = true
        let busy = await text(handler.reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(busy.hasPrefix("HTTP/1.1 429") && busy.contains("Retry-After: 10"))
        #expect(brain.calls.isEmpty, "nothing reached a brain")
    }

    @Test("a brain that fails says so: before a word as a status, after one as an event")
    func failures() async {
        let brain = FakeBrain()
        brain.events = []
        brain.failure = RawChatFailure.contextTooLong
        let early = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(early.hasPrefix("HTTP/1.1 400") && early.contains("context_length_exceeded"))
        let earlyStream = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat(["stream": true]))))
        #expect(earlyStream.hasPrefix("HTTP/1.1 400"), "nothing was sent yet, so the status can still say it")

        brain.events = [.delta("Hel")]
        brain.failure = RawChatFailure.busy
        let late = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat(["stream": true]))))
        #expect(late.hasPrefix("HTTP/1.1 200 OK"))
        #expect(late.contains("\"content\":\"Hel\"") && late.contains("\"error\"") && !late.contains("[DONE]"))
        let lateBuffered = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(lateBuffered.hasPrefix("HTTP/1.1 429"), "a buffered call has sent nothing: the status says it")

        brain.unavailable = true
        let none = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(none.hasPrefix("HTTP/1.1 404"), "a brain that cannot serve raw chat right now is not offered")

        brain.unavailable = false
        brain.events = [.finished(.init(reason: .stop, promptTokens: 1, completionTokens: 0))]
        brain.failure = nil
        let empty = await text(handler(brain).reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(empty.hasPrefix("HTTP/1.1 200 OK"), "a brain that truly said nothing is an empty answer, not an error")
    }

    @Test("one call at a time: a second is told to come back, and the slot frees when the first ends")
    func singleFlight() async {
        let brain = FakeBrain()
        brain.holds = true
        let handler = handler(brain)
        let first = await handler.reply(to: request("POST", "/v1/chat/completions", body: chat(["stream": true])))
        let second = await text(handler.reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(second.hasPrefix("HTTP/1.1 429") && second.contains("Retry-After: 3"))
        brain.held?.yield(.delta("ok"))
        brain.held?.yield(.finished(.init(reason: .stop, promptTokens: 1, completionTokens: 1)))
        brain.held?.finish()
        #expect(await text(first).contains("[DONE]"))
        brain.holds = false
        let third = await text(handler.reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(third.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test("a turn that starts while a call is still being admitted stops it too")
    func preemptedBeforeItStarts() async {
        let brain = FakeBrain()
        let box = HandlerBox()
        var backend = brain.backend
        let inner = backend.userBusy
        // The person at the Mac starts a turn while this call is between its claim and its start.
        backend.userBusy = {
            await box.handler?.preempt()
            return await inner()
        }
        let handler = LocalAPIHandler(port: 4141, token: { "s3cret" }, backend: backend)
        box.handler = handler
        let reply = await text(handler.reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(reply.hasPrefix("HTTP/1.1 429"), "\(reply.prefix(40))")
        // And the slot is free again afterwards.
        box.handler = nil
        let after = await text(handler.reply(to: request("POST", "/v1/chat/completions", body: chat())))
        #expect(after.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test("the person at the Mac takes the brain back: a live call ends with a busy event")
    func preemption() async {
        let brain = FakeBrain()
        brain.holds = true
        let handler = handler(brain)
        let reply = await handler.reply(to: request("POST", "/v1/chat/completions", body: chat(["stream": true])))
        brain.held?.yield(.delta("par"))
        await handler.preempt()
        let text = await text(reply)
        #expect(text.contains("\"error\"") && text.contains("busy") && !text.contains("[DONE]"))
    }
}
