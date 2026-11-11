//
//  RawChatCompletionTests.swift
//  M1K3InferenceTests
//
//  The messages-in, tokens-out seam behind the Local API: what a request must
//  look like, how a brain without a transcript API reads earlier turns, and
//  that both façades forward the capability.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.85, Prior: none (new file)
//

import Foundation
@testable import M1K3Inference
import Testing

private struct ChatProvider: InferenceProvider, RawChatCompleting {
    let name = "chat"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "chat"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func completeRawChat(_ request: RawChatRequest) -> RawChatStream? {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("\(request.messages.count):\(request.maxTokens.map(String.init) ?? "nil")"))
            continuation.yield(.finished(RawChatFinish(reason: .stop, promptTokens: 7, completionTokens: 1)))
            continuation.finish()
        }
    }
}

private struct BareProvider: InferenceProvider {
    let name = "bare"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "bare"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

struct RawChatCompletionTests {
    private func request(_ messages: [RawChatMessage], maxTokens: Int? = nil) throws -> RawChatRequest {
        try RawChatRequest(messages: messages, maxTokens: maxTokens)
    }

    @Test("a request is a conversation that ends on the user's turn")
    func whatARequestMustBe() throws {
        let ok = try request([.init(.system, "Be brief."), .init(.user, "Hi"), .init(.assistant, "Hello"), .init(.user, "Bye")])
        #expect(ok.system == "Be brief.")
        #expect(ok.turns.map(\.role) == [.user, .assistant, .user])
        #expect(ok.question == "Bye")
        #expect(ok.earlier.count == 2)

        #expect(try request([.init(.user, "Hi")]).system == nil)
        // Several system messages are joined in order: clients send more than one.
        #expect(try request([.init(.system, "A"), .init(.system, "B"), .init(.user, "Hi")]).system == "A\n\nB")
    }

    @Test("what is refused, each with a reason a client can read")
    func refusals() {
        #expect(throws: RawChatRequest.Invalid.empty) { try RawChatRequest(messages: [], maxTokens: nil) }
        #expect(throws: RawChatRequest.Invalid.noUserTurn) {
            try RawChatRequest(messages: [.init(.system, "only")], maxTokens: nil)
        }
        #expect(throws: RawChatRequest.Invalid.mustEndOnUser) {
            try RawChatRequest(messages: [.init(.user, "Hi"), .init(.assistant, "Hello")], maxTokens: nil)
        }
        #expect(throws: RawChatRequest.Invalid.blankMessage) {
            try RawChatRequest(messages: [.init(.user, "   ")], maxTokens: nil)
        }
        #expect(throws: RawChatRequest.Invalid.badMaxTokens) {
            try RawChatRequest(messages: [.init(.user, "Hi")], maxTokens: 0)
        }
        for invalid in RawChatRequest.Invalid.allCases {
            #expect(!invalid.message.isEmpty)
        }
    }

    @Test("a brain with no transcript reads earlier turns as a labelled preamble, the question last")
    func flattening() throws {
        let one = try request([.init(.user, "Hi")])
        #expect(RawChatPrompt.flattened(one) == "Hi")
        let many = try request([.init(.user, "Hi"), .init(.assistant, "Hello"), .init(.user, "Bye")])
        #expect(RawChatPrompt.flattened(many) == "Earlier in this conversation:\nUser: Hi\nAssistant: Hello\n\nUser: Bye")
    }

    @Test("cumulative snapshots become deltas that never repeat text, even when a snapshot shrinks or diverges")
    func snapshotDeltas() {
        var sent = ""
        func feed(_ snapshot: String) -> String? {
            RawChatPrompt.delta(sent: &sent, snapshot: snapshot)
        }
        #expect(feed("Hello") == "Hello")
        #expect(feed("Hello wor") == " wor")
        #expect(feed("Hello") == nil, "a shrink sends nothing and forgets nothing")
        #expect(feed("Hello world") == "ld", "only what extends the text already sent")
        #expect(feed("Hello world") == nil)
        #expect(feed("Jello world!") == "!", "a revision cannot be retracted: only the extra length is sent")
        #expect(sent.count == "Hello world!".count)
    }

    @Test("an Apple-model failure becomes a reason a client can act on, never an empty answer")
    func appleFailuresMap() {
        #expect(RawChatFailure(apple: .contextOverflow) == .contextTooLong)
        #expect(RawChatFailure(apple: .guardrailViolation) == .refused)
        #expect(RawChatFailure(apple: .unsupportedLanguage) == .refused)
        #expect(RawChatFailure(apple: .rateLimited) == .busy)
        #expect(RawChatFailure(apple: .daemonUnavailable) == .busy)
        #expect(RawChatFailure(apple: .timeout) == .busy)
        #expect(RawChatFailure(apple: .unknown) == .failed)
        for failure in AFMFailure.allCases {
            _ = RawChatFailure(apple: failure) // every class has a mapping
        }
    }

    @Test("Mini's answer cap: the caller can shorten it, never lengthen it")
    func miniCap() throws {
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(64) == 64)
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(nil) == AppleFoundationModelsProvider.rawResponseTokenCap)
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(1_000_000) == AppleFoundationModelsProvider.rawResponseTokenCap)
        #expect(try AppleFoundationModelsProvider().completeRawChat(
            #require((try? RawChatRequest(messages: [.init(.user, "Hi")], maxTokens: nil)))
        ) != nil)
    }

    @Test("Mini's finish reason is read off the count: a filled ceiling is length, anything less or uncounted is stop")
    func finishReasonFromCount() {
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: 16, ceiling: 16) == .length)
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: 17, ceiling: 16) == .length)
        // The count re-reads the text, so a cut inside a word can read one short: still a cut.
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: 15, ceiling: 16) == .length)
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: 14, ceiling: 16) == .stop)
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: 1, ceiling: 1) == .length)
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: 0, ceiling: 1) == .stop)
        #expect(AppleFoundationModelsProvider.rawChatFinishReason(completionTokens: nil, ceiling: 16) == .stop)
    }

    @Test("the capability reaches the real backend through the façade, and a backend without it reads nil")
    func facadeForwards() async throws {
        let facade = SwappableInferenceProvider(ChatProvider())
        let stream = try #require(facade.completeRawChat(request([.init(.user, "Hi")], maxTokens: 64)))
        var events: [RawChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(events == [
            .delta("1:64"), .finished(RawChatFinish(reason: .stop, promptTokens: 7, completionTokens: 1)),
        ])
        facade.setProvider(BareProvider())
        #expect(try facade.completeRawChat(request([.init(.user, "Hi")])) == nil)
    }
}

/// Opt-in (`M1K3_AFM_EVAL=1`, Apple Intelligence on): Mini through the seam, live.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct RawChatLiveTests {
    private func run(_ messages: [RawChatMessage], maxTokens: Int? = 60) async throws -> (String, RawChatFinish?) {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available here")
        let stream = try #require(provider.completeRawChat(RawChatRequest(messages: messages, maxTokens: maxTokens)))
        var text = ""
        var finish: RawChatFinish?
        for try await event in stream {
            switch event {
            case let .delta(piece): text += piece
            case let .finished(done): finish = done
            }
        }
        return (text, finish)
    }

    @Test("Mini answers under the caller's system prompt, with nothing of M1K3's in it")
    func callerSystemPromptRules() async throws {
        let (text, finish) = try await run([
            .init(.system, "You are a parrot. Reply with only the single word BLUE, in capitals."),
            .init(.user, "What colour is the sky on a clear day?"),
        ])
        print("RAWCHAT-LIVE system: \(text.debugDescription)")
        #expect(text.contains("BLUE"))
        #expect(!text.lowercased().contains("m1k3"))
        #expect(finish?.reason == .stop)
    }

    @Test("Mini reports what the call cost, counted after the answer")
    func usageIsCounted() async throws {
        let clock = ContinuousClock()
        var usage: (prompt: Int, completion: Int)?
        let took = await clock.measure {
            usage = await AppleFoundationModelsProvider.rawChatUsage(
                system: "You answer in one short sentence.", prompt: "What colour is the sky on a clear day?",
                answer: "The sky is blue on a clear day."
            )
        }
        print("RAWCHAT-LIVE usage: \(String(describing: usage)) in \(took)")
        let counted = try #require(usage)
        // Apple counts each part with its wrapper, so a short ask reads about 65 (measured 2026-11-11).
        #expect(counted.prompt > 8 && counted.prompt < 150)
        #expect(counted.completion > 4 && counted.completion < 30)
        let (_, finish) = try await run([.init(.user, "Say hi in five words.")])
        #expect((finish?.promptTokens ?? 0) > 0)
        #expect((finish?.completionTokens ?? 0) > 0)
    }

    @Test("Mini says length when the answer ran into the ceiling, and stop when it did not")
    func ceilingIsReported() async throws {
        let (cut, cutFinish) = try await run([.init(.user, "Write a 300-word story about a lighthouse.")], maxTokens: 16)
        print("RAWCHAT-LIVE ceiling: \(cut.debugDescription) finish=\(String(describing: cutFinish))")
        #expect(cutFinish?.reason == .length)
        #expect((15 ... 17).contains(cutFinish?.completionTokens ?? 0))
        let (short, shortFinish) = try await run([.init(.user, "Reply with the single word: yes")], maxTokens: 60)
        print("RAWCHAT-LIVE under: \(short.debugDescription) finish=\(String(describing: shortFinish))")
        #expect(shortFinish?.reason == .stop)
    }

    @Test("Mini reads the earlier turns")
    func earlierTurnsAreRead() async throws {
        let (text, _) = try await run([
            .init(.user, "My dog is called Biscuit."), .init(.assistant, "Noted."),
            .init(.user, "What is my dog called? One word."),
        ])
        print("RAWCHAT-LIVE history: \(text.debugDescription)")
        #expect(text.contains("Biscuit"))
    }
}
