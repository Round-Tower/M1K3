//
//  LocalAPIPolicyTests.swift
//  M1K3LocalAPITests
//
//  The Local API's pure layer: which paths exist, who gets in, what a chat
//  request must look like, what an error looks like to an OpenAI client, the
//  streaming frames, stop sequences and the admission rules.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.85, Prior: none (new file)
//

import Foundation
import M1K3Inference
@testable import M1K3LocalAPI
import Testing

struct LocalAPIPolicyTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Routes

    @Test("two routes exist; the ones tools try next get a named 404, never a guess")
    func routes() {
        #expect(LocalAPIRoute.classify(method: "GET", path: "/v1/models") == .models)
        #expect(LocalAPIRoute.classify(method: "POST", path: "/v1/chat/completions") == .chatCompletions)
        #expect(LocalAPIRoute.classify(method: "post", path: "/v1/chat/completions?x=1") == .chatCompletions)
        for path in ["/v1/completions", "/v1/embeddings", "/v1/responses", "/v1/audio/speech", "/v1/images/generations"] {
            #expect(LocalAPIRoute.classify(method: "POST", path: path) == .unsupported(path))
        }
        #expect(LocalAPIRoute.classify(method: "OPTIONS", path: "/v1/chat/completions") == .preflight)
        #expect(LocalAPIRoute.classify(method: "GET", path: "/mcp") == .notFound)
        #expect(LocalAPIRoute.classify(method: "GET", path: "/v1/chat/completions") == .notFound)
    }

    // MARK: - The gate

    @Test("only this loopback listener, never a web page, and only with the token")
    func gate() {
        func check(host: [String] = ["127.0.0.1:4141"], origin: String? = nil, auth: String? = "Bearer s3cret") -> Int? {
            LocalAPIGate.check(hosts: host, origin: origin, authorization: auth, port: 4141, token: "s3cret")?.status
        }
        #expect(check() == nil)
        #expect(check(host: ["localhost:4141"]) == nil)
        #expect(check(host: ["[::1]:4141"]) == 403, "the listener is IPv4 only: an IPv6 Host names nothing here")
        #expect(check(host: []) == 400)
        #expect(check(host: ["127.0.0.1:4141", "evil.example"]) == 400)
        #expect(check(host: ["evil.example"]) == 403, "DNS rebinding: a foreign Host is refused")
        #expect(check(host: ["127.0.0.1:9999"]) == 403)
        #expect(check(origin: "https://evil.example") == 403, "a web page cannot call this")
        #expect(check(origin: "http://localhost:3000") == 403, "nor a page served from this Mac: v1 has no browser clients")
        #expect(check(auth: nil) == 401)
        #expect(check(auth: "Bearer wrong") == 401)
        #expect(check(auth: "s3cret") == 401)
        #expect(check(auth: "bearer s3cret") == nil, "the scheme is case-insensitive")
        // An empty configured token never opens the door.
        #expect(LocalAPIGate.check(hosts: ["127.0.0.1:4141"], origin: nil, authorization: "Bearer ", port: 4141, token: "") != nil)
    }

    // MARK: - Errors

    @Test("an error is the shape OpenAI clients parse, with a status they treat correctly")
    func errorShape() throws {
        let busy = LocalAPIError.busy(retryAfter: 5)
        #expect(busy.status == 429 && busy.retryAfter == 5)
        let object = try json(busy.body)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["type"] as? String == "rate_limit_error")
        #expect((error["message"] as? String)?.isEmpty == false)
        #expect(LocalAPIError.modelNotFound("big-m1k3", available: ["mini-m1k3"]).status == 404)
        #expect(LocalAPIError.modelNotFound("x", available: []).code == "model_not_found")
        #expect(LocalAPIError.unauthorized.status == 401)
        // The hint must lead to the key: the pane is "Server", the section "Local API".
        #expect(LocalAPIError.unauthorized.message.contains("Settings ▸ Server ▸ Local API"))
        #expect(LocalAPIError.contextTooLong.code == "context_length_exceeded")
        #expect(LocalAPIError.contextTooLong.status == 400)
        #expect(LocalAPIError.refused.status == 400)
        #expect(LocalAPIError.unsupportedEndpoint("/v1/embeddings").status == 404)
        #expect(LocalAPIError(failure: RawChatFailure.busy).status == 429)
        #expect(LocalAPIError(failure: RawChatFailure.contextTooLong).code == "context_length_exceeded")
        #expect(LocalAPIError(failure: CancellationError()).status == 500)
        // Never a status the OpenAI SDK retries by itself except the two that mean "try again".
        for error in [LocalAPIError.unauthorized, .contextTooLong, .refused, .modelNotFound("x", available: [])] {
            #expect(![408, 409, 429, 500, 502, 503].contains(error.status))
        }
    }

    // MARK: - The chat request

    @Test("a plain chat request parses, with content as a string or as text parts")
    func parsesChat() throws {
        let call = try ChatCompletionCall.parse(body([
            "model": "lil-m1k3", "stream": true, "max_tokens": 64, "temperature": 0.2, "stop": ["END"],
            "stream_options": ["include_usage": true],
            "messages": [
                ["role": "system", "content": "Be brief."],
                ["role": "user", "content": [["type": "text", "text": "Hello"], ["type": "text", "text": " there"]]],
            ],
        ])).get()
        #expect(call.model == "lil-m1k3")
        #expect(call.stream && call.includeUsage)
        #expect(call.stop == ["END"])
        #expect(call.request.system == "Be brief.")
        #expect(call.request.question == "Hello there")
        #expect(call.request.maxTokens == 64)
        #expect(call.request.temperature == 0.2)

        let plain = try ChatCompletionCall.parse(body([
            "model": "mini-m1k3", "max_completion_tokens": 12, "stop": "X", "user": "ignored", "seed": 1,
            "messages": [["role": "developer", "content": "Rules."], ["role": "user", "content": "Hi"]],
        ])).get()
        #expect(!plain.stream && !plain.includeUsage)
        #expect(plain.request.maxTokens == 12)
        #expect(plain.stop == ["X"])
        #expect(plain.request.system == "Rules.", "the developer role is the system role")
    }

    @Test("what v1 does not do is refused by name, never silently ignored")
    func refusesWhatItCannotDo() throws {
        func failure(_ object: [String: Any]) throws -> LocalAPIError {
            let result = try ChatCompletionCall.parse(body(object))
            guard case let .failure(error) = result else {
                Issue.record("parsed: \(object.keys.sorted())")
                return .server("parsed")
            }
            return error
        }
        let hi: [[String: Any]] = [["role": "user", "content": "Hi"]]
        #expect(try failure(["messages": hi]).param == "model")
        #expect(try failure(["model": "lil-m1k3"]).param == "messages")
        #expect(try failure(["model": "lil-m1k3", "messages": hi, "tools": [["type": "function"]]]).param == "tools")
        #expect(try failure(["model": "lil-m1k3", "messages": hi, "n": 2]).param == "n")
        #expect(try failure(["model": "lil-m1k3", "messages": hi, "response_format": ["type": "json_schema"]]).param
            == "response_format")
        let image: [[String: Any]] = [["role": "user", "content": [["type": "image_url", "image_url": ["url": "x"]]]]]
        #expect(try failure(["model": "lil-m1k3", "messages": image]).param == "messages")
        let toolTurn: [[String: Any]] = [["role": "tool", "content": "x"], ["role": "user", "content": "Hi"]]
        #expect(try failure(["model": "lil-m1k3", "messages": toolTurn]).param == "messages")
        #expect(try failure(["model": "lil-m1k3", "messages": [["role": "assistant", "content": "Hi"]]]).status == 400)
        #expect(ChatCompletionCall.parse(Data("not json".utf8)).isFailure)
        #expect(ChatCompletionCall.parse(nil).isFailure)
        // n = 1 and an empty tools list are what careful clients send by default.
        #expect(try ChatCompletionCall.parse(body(["model": "m", "messages": hi, "n": 1, "tools": []])).isSuccess)
    }

    @Test("empty system and assistant messages are dropped, as clients send them; a number that is not a count is refused")
    func lenientWhereClientsAre() throws {
        let call = try ChatCompletionCall.parse(body([
            "model": "m", "max_tokens": 64.0,
            "messages": [
                ["role": "system", "content": ""], ["role": "user", "content": "Hi"],
                ["role": "assistant", "content": ""], ["role": "user", "content": "Again"],
            ],
        ])).get()
        #expect(call.request.system == nil)
        #expect(call.request.turns.map(\.content) == ["Hi", "Again"])
        #expect(call.request.maxTokens == 64)
        // One token is a real request (a yes/no probe), and JSON's 1 must not be mistaken for `true`.
        let one = try ChatCompletionCall.parse(body(["model": "m", "max_tokens": 1, "messages": [["role": "user", "content": "Hi"]]])).get()
        #expect(one.request.maxTokens == 1)
        for (key, value): (String, Any) in [("temperature", "hot"), ("stop", 7), ("stop", ["a", 3])] {
            let result = try ChatCompletionCall.parse(body(["model": "m", key: value, "messages": [["role": "user", "content": "Hi"]]]))
            guard case let .failure(error) = result else {
                Issue.record("\(key) = \(value) was accepted")
                continue
            }
            #expect(error.param == key)
        }
        for bad: Any in [100.5, "100", -3, 0, true] {
            let result = try ChatCompletionCall.parse(body([
                "model": "m", "max_tokens": bad, "messages": [["role": "user", "content": "Hi"]],
            ]))
            guard case let .failure(error) = result else {
                Issue.record("max_tokens \(bad) was accepted")
                continue
            }
            #expect(error.param == "max_tokens", "\(bad)")
        }
        // A blank USER message is still an error: there is nothing to answer.
        #expect(try ChatCompletionCall.parse(body(["model": "m", "messages": [["role": "user", "content": " "]]])).isFailure)
    }

    @Test("a conversation far past any brain's window is refused before it reaches one")
    func oversizeConversation() throws {
        let huge = String(repeating: "word ", count: ChatCompletionCall.maxConversationCharacters / 5 + 1)
        let result = try ChatCompletionCall.parse(body(["model": "lil-m1k3", "messages": [["role": "user", "content": huge]]]))
        guard case let .failure(error) = result else {
            Issue.record("an oversize conversation parsed")
            return
        }
        #expect(error.code == "context_length_exceeded" && error.status == 400)
        let fine = String(repeating: "word ", count: 1000)
        #expect(try ChatCompletionCall.parse(body(["model": "m", "messages": [["role": "user", "content": fine]]])).isSuccess)
    }

    // MARK: - Models and admission

    @Test("the list is M1K3's evaluated brains that can answer now, and nothing else")
    func models() throws {
        let object = try json(LocalAPIWire.modelsBody(ids: ["mini-m1k3", "lil-m1k3"], created: 1))
        #expect(object["object"] as? String == "list")
        let data = try #require(object["data"] as? [[String: Any]])
        #expect(data.map { $0["id"] as? String } == ["mini-m1k3", "lil-m1k3"])
        #expect(data.allSatisfy { $0["object"] as? String == "model" && $0["owned_by"] as? String == "m1k3" })
        #expect(LocalAPIModel.id(forTier: "lil") == "lil-m1k3")
    }

    @Test("the person at the Mac goes first, one API call at a time, and a brain that is not loaded is not found")
    func admission() {
        func decide(_ model: String, userBusy: Bool = false, apiBusy: Bool = false) -> Int? {
            LocalAPIAdmission.decide(
                requested: model, available: ["mini-m1k3", "lil-m1k3"], userBusy: userBusy, apiBusy: apiBusy
            )?.status
        }
        #expect(decide("lil-m1k3") == nil)
        #expect(decide("big-m1k3") == 404, "never a brain swap on a caller's say-so")
        #expect(decide("gpt-4o") == 404)
        #expect(decide("lil-m1k3", userBusy: true) == 429)
        #expect(decide("lil-m1k3", apiBusy: true) == 429)
        #expect(decide("big-m1k3", userBusy: true) == 404, "an unknown model is named before the queue is")
    }

    // MARK: - Wire

    @Test("a non-streamed answer is one chat.completion object")
    func completionBody() throws {
        let finish = RawChatFinish(reason: .length, promptTokens: 9, completionTokens: 3)
        let object = try json(LocalAPIWire.completionBody(id: "chatcmpl-1", model: "lil-m1k3", created: 5, text: "Hi", finish: finish))
        #expect(object["object"] as? String == "chat.completion")
        #expect(object["model"] as? String == "lil-m1k3")
        let choice = try #require((object["choices"] as? [[String: Any]])?.first)
        #expect(choice["finish_reason"] as? String == "length")
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "Hi")
        #expect((choice["message"] as? [String: Any])?["role"] as? String == "assistant")
        let usage = try #require(object["usage"] as? [String: Any])
        #expect(usage["prompt_tokens"] as? Int == 9 && usage["completion_tokens"] as? Int == 3 && usage["total_tokens"] as? Int == 12)
        // No counts from the runtime (Apple's model): zeros, so a client that reads usage does not crash.
        let unknown = RawChatFinish(reason: .stop, promptTokens: nil, completionTokens: nil)
        let bare = try json(LocalAPIWire.completionBody(id: "c", model: "mini-m1k3", created: 5, text: "Hi", finish: unknown))
        #expect((bare["usage"] as? [String: Any])?["total_tokens"] as? Int == 0)
    }

    @Test("a stream is role first, content deltas, a final chunk with the finish reason, then [DONE]")
    func streamFrames() throws {
        func chunk(_ data: Data) throws -> [String: Any] {
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.hasPrefix("data: ") && text.hasSuffix("\n\n"))
            return try json(Data(text.dropFirst(6).utf8))
        }
        let role = try chunk(LocalAPIWire.chunk(id: "c", model: "m", created: 1, role: true))
        let first = try #require((role["choices"] as? [[String: Any]])?.first)
        #expect(role["object"] as? String == "chat.completion.chunk")
        #expect((first["delta"] as? [String: Any])?["role"] as? String == "assistant")
        #expect(first["finish_reason"] is NSNull)

        let delta = try chunk(LocalAPIWire.chunk(id: "c", model: "m", created: 1, content: "He said \"hi\"\n"))
        #expect(((delta["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String == "He said \"hi\"\n")

        let last = try chunk(LocalAPIWire.chunk(id: "c", model: "m", created: 1, finish: .stop))
        let lastChoice = try #require((last["choices"] as? [[String: Any]])?.first)
        #expect(lastChoice["finish_reason"] as? String == "stop")
        #expect((lastChoice["delta"] as? [String: Any])?.isEmpty == true)

        let usage = try chunk(LocalAPIWire.usageChunk(
            id: "c", model: "m", created: 1, finish: RawChatFinish(reason: .stop, promptTokens: 2, completionTokens: 3)
        ))
        #expect((usage["choices"] as? [Any])?.isEmpty == true)
        #expect((usage["usage"] as? [String: Any])?["total_tokens"] as? Int == 5)

        #expect(String(data: LocalAPIWire.done, encoding: .utf8) == "data: [DONE]\n\n")
        let head = try #require(String(data: LocalAPIWire.sseHead, encoding: .utf8))
        #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n") && head.contains("text/event-stream") && head.hasSuffix("\r\n\r\n"))
        let failed = try chunk(LocalAPIWire.errorEvent(.busy(retryAfter: 3)))
        #expect(failed["error"] != nil)
    }

    @Test("a buffered response carries its length, its type and a retry hint when there is one")
    func bufferedResponse() throws {
        let text = try #require(String(data: LocalAPIWire.response(for: .busy(retryAfter: 7)), encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 429 "))
        #expect(text.contains("Retry-After: 7\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        let parts = text.components(separatedBy: "\r\n\r\n")
        #expect(text.contains("Content-Length: \(parts.dropFirst().joined(separator: "\r\n\r\n").utf8.count)\r\n"))
    }

    // MARK: - Stop sequences

    @Test("a stop sequence ends the answer before it, even split across deltas")
    func stopSequences() {
        var filter = StopSequenceFilter(stops: ["END", "\n\nUser:"])
        var out = ""
        var stopped = false
        for piece in ["Hello", " wor", "ld E", "ND and more"] {
            let step = filter.push(piece)
            out += step.emit
            if step.stopped { stopped = true; break }
        }
        #expect(stopped)
        #expect(out == "Hello world ")

        var none = StopSequenceFilter(stops: [])
        #expect(none.push("abc").emit == "abc")
        #expect(none.flush().isEmpty)

        // Split across three deltas, overlapping stops, and characters wider than a byte.
        var three = StopSequenceFilter(stops: ["###", "##!"])
        #expect(three.push("a#").emit == "a")
        #expect(three.push("#").emit.isEmpty)
        let cut = three.push("#b")
        #expect(cut.stopped && cut.emit.isEmpty)
        var wide = StopSequenceFilter(stops: ["fin🙂"])
        #expect(wide.push("café fin").emit == "café ")
        #expect(wide.push("🙂 après").stopped)

        var held = StopSequenceFilter(stops: ["STOP"])
        #expect(held.push("so ST").emit == "so ", "a possible start of the sequence is held back")
        #expect(held.flush() == "ST", "and released when the stream ends without it")
    }

    // MARK: - HTTP

    @Test("a request is read once its head and its whole body have arrived")
    func httpParsing() throws {
        let raw = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:4141\r\nAuthorization: Bearer t\r\n"
            + "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let request = try #require(LocalAPIHTTP.parse(Data(raw.utf8)))
        #expect(request.method == "POST" && request.path == "/v1/chat/completions")
        #expect(request.headers["host"] == ["127.0.0.1:4141"])
        #expect(request.first("Authorization") == "Bearer t")
        #expect(request.body == Data("{}".utf8))
        #expect(LocalAPIHTTP.parse(Data(raw.dropLast(1).utf8)) == nil, "the body has not all arrived")
        #expect(LocalAPIHTTP.parse(Data("GET /v1/models HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n".utf8))?.headers["host"] == ["a", "b"])
        #expect(LocalAPIHTTP.parse(Data("garbage".utf8)) == nil)
        let emptyValue = try #require(LocalAPIHTTP.parse(Data("GET /v1/models HTTP/1.1\r\nHost: a\r\nAccept:\r\n\r\n".utf8)))
        #expect(emptyValue.headers["accept"] == [""], "a header with no value is a header, not a broken request")
        #expect(LocalAPIHTTP.declaredLength(Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)) == 999_999_999)
        // A head that never ends is cut off early, before anyone has shown a key.
        #expect(!LocalAPIHTTP.headIsTooLarge(Data(raw.utf8)))
        #expect(LocalAPIHTTP.headIsTooLarge(Data(repeating: 0x41, count: LocalAPIHTTP.maxHeadBytes + 1)))
        var longHead = Data("GET /v1/models HTTP/1.1\r\nX: ".utf8)
        longHead.append(Data(repeating: 0x41, count: LocalAPIHTTP.maxHeadBytes))
        longHead.append(Data("\r\n\r\n".utf8))
        #expect(LocalAPIHTTP.headIsTooLarge(longHead), "a complete head over the cap is refused too")
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }

    var isFailure: Bool {
        !isSuccess
    }
}
