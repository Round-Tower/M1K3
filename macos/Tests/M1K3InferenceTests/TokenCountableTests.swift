//
//  TokenCountableTests.swift
//  M1K3InferenceTests
//
//  Pin the TokenCountable protocol shape — two async methods, Sendable.

import M1K3Inference
import Testing

struct TokenCountableTests {
    struct FakeCountable: TokenCountable {
        func tokenCount(forInstructions text: String) async throws -> Int {
            text.count / 4
        }

        func tokenCount(forPrompt text: String) async throws -> Int {
            text.count / 4
        }
    }

    @Test("a conforming type can measure instructions and prompts independently")
    func conformanceShape() async throws {
        let counter: any TokenCountable = FakeCountable()
        let instrTokens = try await counter.tokenCount(forInstructions: "You are M1K3.")
        let promptTokens = try await counter.tokenCount(forPrompt: "Hello")
        #expect(instrTokens > 0)
        #expect(promptTokens > 0)
        #expect(instrTokens > promptTokens)
    }
}
