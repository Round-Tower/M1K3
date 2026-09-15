//
//  OpenRouterWireTests.swift
//  M1K3ChatTests
//
//  Pins the wire shape RemoteLiveEvalTests sends and reads, off the network.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: Unknown
//

import Foundation
import Testing

struct OpenRouterWireTests {
    @Test("the body carries the persona as system, the prompt as user, and never streams")
    func bodyShape() throws {
        let data = try OpenRouterWire.body(model: "anthropic/claude-opus-5", system: "You are M1K3.", prompt: "hi")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["model"] as? String == "anthropic/claude-opus-5")
        #expect(root["stream"] as? Bool == false)
        #expect(root["max_tokens"] as? Int == 2048)
        let messages = try #require(root["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "You are M1K3."], ["role": "user", "content": "hi"]])
        #expect(root["temperature"] == nil, "unset temperature is omitted, not sent as null")
    }

    @Test("a completion's answer is choices[0].message.content, reasoning fields ignored")
    func parsesContent() throws {
        let body = """
        {"id":"gen-1","choices":[{"message":{"role":"assistant","content":"Hello there.","reasoning":"thinking…"},"finish_reason":"stop"}]}
        """
        #expect(try OpenRouterWire.text(fromResponse: Data(body.utf8)) == "Hello there.")
    }

    @Test("an empty content is an empty answer, not a crash")
    func emptyContent() throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#
        #expect(try OpenRouterWire.text(fromResponse: Data(body.utf8)) == "")
        let nullContent = #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#
        #expect(try OpenRouterWire.text(fromResponse: Data(nullContent.utf8)) == "")
    }

    @Test("a provider refusal — empty content beside a refusal string — is the answer, not nothing")
    func providerRefusal() throws {
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"","refusal":"This request was blocked under the Usage Policy.","reasoning":""},"finish_reason":"content_filter","native_finish_reason":"refusal"}]}
        """
        #expect(try OpenRouterWire.text(fromResponse: Data(body.utf8)) == "This request was blocked under the Usage Policy.")
        // content wins when both are present; a null refusal never replaces content
        let both = #"{"choices":[{"message":{"content":"Answer.","refusal":"nope"}}]}"#
        #expect(try OpenRouterWire.text(fromResponse: Data(both.utf8)) == "Answer.")
        let nullRefusal = #"{"choices":[{"message":{"content":"","refusal":null}}]}"#
        #expect(try OpenRouterWire.text(fromResponse: Data(nullRefusal.utf8)) == "")
    }

    @Test("the API's error envelope throws with its code and message")
    func errorEnvelope() {
        let body = #"{"error":{"code":429,"message":"Rate limited","metadata":{}}}"#
        #expect(throws: OpenRouterWire.Failure.api(code: 429, message: "Rate limited")) {
            try OpenRouterWire.text(fromResponse: Data(body.utf8))
        }
    }

    @Test("no choices and non-JSON bodies are named failures")
    func malformed() {
        #expect(throws: OpenRouterWire.Failure.emptyChoices) {
            try OpenRouterWire.text(fromResponse: Data(#"{"choices":[]}"#.utf8))
        }
        #expect(throws: OpenRouterWire.Failure.malformed) {
            try OpenRouterWire.text(fromResponse: Data("<html>".utf8))
        }
    }

    @Test("the column name is the bare model, route and variant suffix dropped")
    func columnName() {
        #expect(OpenRouterWire.columnName(for: "anthropic/claude-opus-5") == "claude-opus-5")
        #expect(OpenRouterWire.columnName(for: "google/gemma-4-26b-a4b-it:free") == "gemma-4-26b-a4b-it")
        #expect(OpenRouterWire.columnName(for: "plain") == "plain")
    }

    @Test("the headers carry the bearer key and the attribution pair")
    func headers() {
        let h = OpenRouterWire.headers(key: "sk-test")
        #expect(h["Authorization"] == "Bearer sk-test")
        #expect(h["Content-Type"] == "application/json")
        #expect(h["X-Title"] == "M1K3 brains eval")
    }

    @Test("the provider says it carries the persona, so the ReAct floor sends it once")
    func personaCarrying() {
        let provider = OpenRouterProvider(model: "x/y", key: "k", system: "persona")
        #expect(provider.carriesStandingPersona)
        #expect(provider.name == "y")
        #expect(provider.isAvailable)
        #expect(!OpenRouterProvider(model: "x/y", key: "", system: "persona").isAvailable)
    }
}
