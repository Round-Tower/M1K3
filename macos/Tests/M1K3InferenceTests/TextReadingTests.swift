//
//  TextReadingTests.swift
//  M1K3InferenceTests
//
//  TextReading is an `as?` capability seam like ImageLooking: the package
//  façade forwards it, a backend that cannot read fails the STREAM, and the
//  budget a read is fitted to comes from the brain that will read it.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.85, Prior: none (new file)
//

import Foundation
import M1K3Inference
import Testing

private struct MuteProvider: InferenceProvider {
    let name = "mute"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "mute"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

private struct ReaderProvider: InferenceProvider, TextReading {
    let name = "reader"
    let isAvailable = true
    var readContextTokens = 4096
    func generate(prompt _: String) async throws -> String {
        "reader"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func read(instructions: String, prompt: String) -> LookStream {
        AsyncThrowingStream { continuation in
            continuation.yield("read")
            continuation.yield("read|\(instructions)|\(prompt)")
            continuation.finish()
        }
    }
}

struct TextReadingTests {
    private func drain(_ stream: LookStream) async throws -> [String] {
        var snapshots: [String] = []
        for try await snapshot in stream {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    @Test("a read reaches the real backend through the façade, snapshots and arguments intact")
    func readForwards() async throws {
        let facade = SwappableInferenceProvider(ReaderProvider())
        #expect(try await drain(facade.read(instructions: "i", prompt: "p")) == ["read", "read|i|p"])
    }

    @Test("a backend that cannot read fails the stream with cannotRead")
    func muteBackendThrows() async {
        let facade = SwappableInferenceProvider(MuteProvider())
        var failure: InferenceError?
        do {
            for try await _ in facade.read(instructions: "i", prompt: "p") {}
        } catch let error as InferenceError {
            failure = error
        } catch {}
        #expect(failure == TextReadingError.cannotRead)
    }

    @Test("the façade reports the active reader's window, and 0 when it cannot read")
    func windowFollowsTheSwap() {
        let facade = SwappableInferenceProvider(MuteProvider())
        #expect(facade.readContextTokens == 0)
        facade.setProvider(ReaderProvider(readContextTokens: 8192))
        #expect(facade.readContextTokens == 8192)
    }

    @Test("blank instructions are the caller's bug and fail loudly")
    func blankInstructions() throws {
        #expect(try TextReadingError.instructions(" Read.\n") == "Read.")
        #expect(throws: InferenceError.self) { try TextReadingError.instructions("  ") }
    }

    @Test("the text budget leaves room for the instructions, the question and the answer")
    func budget() {
        let small = ReadBudget.characters(windowTokens: 4096, question: "When does the ferry leave?")
        let large = ReadBudget.characters(windowTokens: 8192, question: "When does the ferry leave?")
        #expect(small > 8000 && small < 4096 * 4)
        #expect(large > small)
        #expect(ReadBudget.characters(windowTokens: 200, question: "q") == 0)
        // A long question costs text budget.
        let wordy = ReadBudget.characters(windowTokens: 4096, question: String(repeating: "why ", count: 200))
        #expect(wordy < small)
    }

    @Test("dense text (numbers, punctuation) is budgeted at fewer characters a token than prose")
    func densityAware() {
        let prose = String(repeating: "The ferry leaves the north pier at nine each morning, weather permitting. ", count: 40)
        let csv = String(repeating: "2026-10-03,Cordless drill,M. Okafor,returned,0.00,14,3\n", count: 60)
        #expect(ReadBudget.charsPerToken(of: prose) >= 3.3)
        #expect(ReadBudget.charsPerToken(of: csv) < 2.5)
        let proseBudget = ReadBudget.characters(windowTokens: 4096, question: "q", text: prose)
        let csvBudget = ReadBudget.characters(windowTokens: 4096, question: "q", text: csv)
        #expect(csvBudget < proseBudget * 3 / 4)
    }

    @Test("a declined read keeps the backend's sentence; anything else asks for another try")
    func failureReplies() {
        #expect(ReadFailureReply.reply(for: LookDeclined(reply: "No.")) == "No.")
        #expect(ReadFailureReply.reply(for: TextReadingError.cannotRead) == ReadFailureReply.cannotRead)
        #expect(ReadFailureReply.reply(for: CancellationError()) == ReadFailureReply.tryAgain)
    }
}
