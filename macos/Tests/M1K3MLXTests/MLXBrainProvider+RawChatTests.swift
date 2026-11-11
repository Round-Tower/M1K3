//
//  MLXBrainProvider+RawChatTests.swift
//  M1K3MLXTests
//
//  The pure half of Lil and Big behind the Local API: the cap a caller cannot
//  raise, the temperature clamp, and the history handed to the session. The
//  generation itself is verify-by-launch (the metallib wall).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.85, Prior: none (new file)
//

import Foundation
import M1K3Inference
@testable import M1K3MLX
import MLXLMCommon
import Testing

struct MLXBrainProviderRawChatTests {
    private func request(
        _ messages: [RawChatMessage], maxTokens: Int? = nil, temperature: Double? = nil
    ) throws -> RawChatRequest {
        try RawChatRequest(messages: messages, maxTokens: maxTokens, temperature: temperature)
    }

    @Test("a caller can shorten the answer and never lengthen it past the brain's cap")
    func capHolds() throws {
        var base = GenerateParameters()
        base.maxTokens = 2048
        let hi = [RawChatMessage(.user, "Hi")]
        func cap(_ asked: Int?) throws -> Int? {
            try MLXBrainProvider.rawChatParameters(base: base, defaultCap: 4096, request: request(hi, maxTokens: asked))
                .maxTokens
        }
        #expect(try cap(nil) == 2048)
        #expect(try cap(64) == 64)
        #expect(try cap(999_999) == 2048)
        base.maxTokens = nil
        #expect(try cap(nil) == 4096, "no cap of its own: the default cap, never unbounded")
        #expect(try cap(8000) == 4096)
    }

    @Test("temperature is the caller's, clamped to 0...2, and the brain's own when none is sent")
    func temperatureClamp() throws {
        var base = GenerateParameters()
        base.temperature = 0.6
        let hi = [RawChatMessage(.user, "Hi")]
        func temperature(_ asked: Double?) throws -> Float {
            try MLXBrainProvider.rawChatParameters(
                base: base, defaultCap: 4096, request: request(hi, temperature: asked)
            ).temperature
        }
        #expect(try temperature(nil) == 0.6)
        #expect(try temperature(0) == 0)
        #expect(try temperature(1.5) == 1.5)
        #expect(try temperature(9) == 2)
        #expect(try temperature(-1) == 0)
    }

    @Test("the earlier turns become the session's history, in order, without the question or the system prompt")
    func history() throws {
        let asked = try request([
            .init(.system, "Be brief."), .init(.user, "Hi"), .init(.assistant, "Hello"), .init(.user, "Bye"),
        ])
        let history = MLXBrainProvider.rawChatHistory(asked)
        #expect(history.map(\.role) == [.user, .assistant])
        #expect(history.map(\.content) == ["Hi", "Hello"])
        #expect(try MLXBrainProvider.rawChatHistory(request([.init(.user, "Hi")])).isEmpty)
    }
}
