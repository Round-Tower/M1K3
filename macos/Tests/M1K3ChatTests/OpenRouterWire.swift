//
//  OpenRouterWire.swift
//  M1K3ChatTests
//
//  The wire shape of one OpenRouter chat completion — request body, headers,
//  response parse — as pure functions, so RemoteLiveEvalTests can pin them
//  without a network. TEST-ONLY on purpose: the product makes no third-party
//  model calls (the "nothing leaves" promise), and a provider that could would
//  be a liability even unused. This lives beside the eval runner that needs it
//  and nowhere near Sources/.
//
//  One shape for every family: OpenRouter normalises Anthropic, OpenAI, Google,
//  DeepSeek, Qwen, xAI and Moonshot behind the OpenAI chat-completions body, so
//  the persona rides as the `system` message and the fixture (or the assembled
//  ReAct floor prompt) as the `user` message — the pairing Mini ships with.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85 (pinned by
//  OpenRouterWireTests; the live call is exercised by RemoteLiveEvalTests
//  against the real endpoint). Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-15 (later the same day) — a provider
//  refusal (`content` empty, `refusal` set) is returned as the answer; the first
//  frontier run scored nine Anthropic/OpenAI refusals as "0 chars" (probed raw).
//

import Foundation
import M1K3Inference

enum OpenRouterWire {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    struct Request: Encodable, Equatable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let maxTokens: Int?
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
        }
    }

    enum Failure: Error, Equatable {
        /// The API's own error envelope (`{"error": {"code": 429, "message": …}}`).
        case api(code: Int?, message: String)
        /// A 2xx body with no choices — nothing to score.
        case emptyChoices
        /// A body that isn't the documented shape at all.
        case malformed
    }

    /// The request body: system (the persona) then user (the prompt), never
    /// streamed — the eval reads finished text, and a non-streamed body is one
    /// JSON document to parse.
    static func body(
        model: String, system: String, prompt: String, maxTokens: Int? = 2048, temperature: Double? = nil
    ) throws -> Data {
        let request = Request(
            model: model,
            messages: [Message(role: "system", content: system), Message(role: "user", content: prompt)],
            temperature: temperature, maxTokens: maxTokens, stream: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    /// The headers OpenRouter wants: the bearer key, JSON, and the optional
    /// attribution pair its dashboard groups spend by.
    static func headers(key: String) -> [String: String] {
        [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://m1k3.app/brains",
            "X-Title": "M1K3 brains eval",
        ]
    }

    /// The assistant text out of a response body. Some reasoning models return
    /// their thinking in a separate `reasoning` field and the answer in
    /// `content`; only `content` is the answer. A provider-side refusal comes
    /// back as an EMPTY `content` beside a `refusal` string (`finish_reason:
    /// content_filter` — seen on every Anthropic refusal fixture, 2026-09-15);
    /// that string IS the answer the user would have read, so it is returned
    /// rather than an empty answer the scorer can only call "0 chars". An API
    /// error envelope throws with the code and message so a 429 reads as a 429
    /// on the transcript.
    static func text(fromResponse data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed
        }
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown error"
            let code = error["code"] as? Int
            throw Failure.api(code: code, message: message)
        }
        guard let choices = root["choices"] as? [[String: Any]] else { throw Failure.malformed }
        guard let first = choices.first else { throw Failure.emptyChoices }
        guard let message = first["message"] as? [String: Any] else { throw Failure.malformed }
        let content = (message["content"] as? String) ?? ""
        if content.isEmpty, let refusal = message["refusal"] as? String, !refusal.isEmpty {
            return refusal
        }
        return content
    }

    /// `anthropic/claude-opus-5` → `claude-opus-5`: the column name on the
    /// scoreboard. The full route stays in `modelID`.
    static func columnName(for model: String) -> String {
        let bare = model.split(separator: "/").last.map(String.init) ?? model
        return bare.split(separator: ":").first.map(String.init) ?? bare
    }
}

/// OpenRouter as an `InferenceProvider`, for the eval runner only. Carries the
/// persona as the system message on every call (`PersonaCarrying`), so the
/// ReAct floor sends the prompt body without it — the same pairing Mini ships
/// with, and the one the AFM column measured against.
struct OpenRouterProvider: InferenceProvider, PersonaCarrying {
    let model: String
    let key: String
    let system: String
    let session: URLSession
    /// Transient failures (429, 5xx, a dropped connection) are retried with a
    /// growing pause; anything else is the model's answer to score.
    let retries: Int

    init(model: String, key: String, system: String, session: URLSession = .shared, retries: Int = 3) {
        self.model = model
        self.key = key
        self.system = system
        self.session = session
        self.retries = retries
    }

    var name: String {
        OpenRouterWire.columnName(for: model)
    }

    var isAvailable: Bool {
        !key.isEmpty
    }

    var carriesStandingPersona: Bool {
        true
    }

    func generate(prompt: String) async throws -> String {
        var request = URLRequest(url: OpenRouterWire.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        for (field, value) in OpenRouterWire.headers(key: key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try OpenRouterWire.body(model: model, system: system, prompt: prompt)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 || status >= 500, attempt <= retries {
                    try await Task.sleep(for: .seconds(Double(attempt * attempt) * 2))
                    continue
                }
                return try OpenRouterWire.text(fromResponse: data)
            } catch let failure as OpenRouterWire.Failure {
                throw failure
            } catch {
                if attempt <= retries {
                    try await Task.sleep(for: .seconds(Double(attempt * attempt) * 2))
                    continue
                }
                throw error
            }
        }
    }

    /// One piece: the finished answer. The eval reads finished text, and the
    /// first-piece timing on a non-streamed call is the whole turn by definition.
    func generateStreaming(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                if let text = try? await generate(prompt: prompt) {
                    continuation.yield(text)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
