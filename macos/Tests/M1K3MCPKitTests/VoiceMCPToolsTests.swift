//
//  VoiceMCPToolsTests.swift
//  M1K3MCPKitTests
//
//  The voice tool definitions against fake handlers — argument validation,
//  emotion passthrough, timeout clamping, and error surfacing pinned here.
//  The real handlers live in the app (they drive speech/avatar/STT on the
//  MainActor); these tests own the contract between the two.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Testing

private final class HandlerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private func makeHandlers(
    log: HandlerLog,
    speakThrows: Bool = false,
    listenResult: String = "hello from the mic"
) -> VoiceToolHandlers {
    VoiceToolHandlers(
        speak: { text, emotion, wait in
            if speakThrows { throw MCPVoiceError("M1K3 is in a voice conversation") }
            log.add("speak:\(text):\(emotion ?? "nil"):\(wait)")
        },
        stopSpeaking: { log.add("stop") },
        status: {
            VoiceStatus(
                providerName: "kokoro",
                tier: "M1K3 Voice",
                brain: "Big",
                isSpeaking: false,
                inConversation: true,
                micInUse: false,
                answering: true
            )
        },
        listen: { timeout in
            log.add("listen:\(timeout)")
            return listenResult
        }
    )
}

private func text(_ result: CallTool.Result) -> String? {
    if case let .text(text, _, _) = result.content.first { return text }
    return nil
}

struct VoiceMCPToolsTests {
    @Test("the voice surface is speak, stop_speaking, get_status, listen")
    func surface() {
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: HandlerLog())))
        #expect(registry.tools.map(\.name) == ["speak", "stop_speaking", "get_status", "listen"])
    }

    @Test("speak passes text and emotion through, defaulting wait to false")
    func speakPassthrough() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(
            name: "speak",
            arguments: ["text": .string("hello"), "emotion": .string("happy")]
        )
        #expect(result.isError != true)
        #expect(text(result) == "Speaking.")
        #expect(log.all == ["speak:hello:happy:false"])
    }

    @Test("speak without emotion passes nil")
    func speakNoEmotion() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        _ = await registry.call(name: "speak", arguments: ["text": .string("hi")])
        #expect(log.all == ["speak:hi:nil:false"])
    }

    @Test("speak with wait true passes through and reports Spoken")
    func speakWaits() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(
            name: "speak",
            arguments: ["text": .string("hello"), "wait": .bool(true)]
        )
        #expect(text(result) == "Spoken.")
        #expect(log.all == ["speak:hello:nil:true"])
    }

    @Test("a speak wait:true that outlives the cap returns a still-speaking note instead of blocking")
    func speakWaitOutlivesCap() async {
        // An utterance longer than the wait cap: the tool must hand back an
        // honest "still speaking" note promptly (non-error) — playback keeps
        // going, the caller polls get_status. Before this, a long line blew the
        // MCP client's request timeout while the speech played fine.
        let handlers = VoiceToolHandlers(
            speak: { _, _, _ in try? await Task.sleep(for: .seconds(60)) },
            stopSpeaking: {},
            status: { VoiceStatus(providerName: "kokoro", tier: "M1K3 Voice", isSpeaking: true) },
            listen: { _ in "" }
        )
        let registry = MCPToolRegistry(
            makeVoiceToolDefinitions(handlers: handlers, speakWaitCapSeconds: 0.2)
        )
        let start = ContinuousClock.now
        let result = await registry.call(
            name: "speak", arguments: ["text": .string("a very long read"), "wait": .bool(true)]
        )
        // Stall-proof bound (half the fake utterance), same doctrine as the
        // ask grace tests — the semantic proof is the note itself.
        #expect(start.duration(to: .now) < .seconds(30))
        #expect(result.isError != true)
        #expect(text(result)?.contains("get_status") == true)
    }

    @Test("a speak error inside the wait window still surfaces as isError")
    func speakWaitSurfacesEarlyError() async {
        let registry = MCPToolRegistry(
            makeVoiceToolDefinitions(
                handlers: makeHandlers(log: HandlerLog(), speakThrows: true),
                speakWaitCapSeconds: 60 // scheduler tolerance, not the thing under test
            )
        )
        let result = await registry.call(
            name: "speak", arguments: ["text": .string("hello"), "wait": .bool(true)]
        )
        #expect(result.isError == true)
        #expect(text(result)?.contains("voice conversation") == true)
    }

    @Test("speak with missing or empty text is an isError without invoking the handler")
    func speakMissingText() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        let missing = await registry.call(name: "speak", arguments: nil)
        let empty = await registry.call(name: "speak", arguments: ["text": .string("  ")])
        #expect(missing.isError == true)
        #expect(empty.isError == true)
        #expect(log.all.isEmpty)
    }

    @Test("a busy speak handler surfaces its message as isError")
    func speakBusy() async {
        let registry = MCPToolRegistry(
            makeVoiceToolDefinitions(handlers: makeHandlers(log: HandlerLog(), speakThrows: true))
        )
        let result = await registry.call(name: "speak", arguments: ["text": .string("hello")])
        #expect(result.isError == true)
        #expect(text(result)?.contains("voice conversation") == true)
    }

    @Test("get_status renders compact JSON including the busy/brain fields")
    func status() async throws {
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: HandlerLog())))
        let result = await registry.call(name: "get_status", arguments: nil)
        let payload = try #require(text(result)?.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(decoded["provider"] as? String == "kokoro")
        #expect(decoded["tier"] as? String == "M1K3 Voice")
        #expect(decoded["brain"] as? String == "Big")
        #expect(decoded["speaking"] as? Bool == false)
        #expect(decoded["in_conversation"] as? Bool == true)
        #expect(decoded["mic_in_use"] as? Bool == false)
        #expect(decoded["answering"] as? Bool == true)
    }

    @Test("listen defaults the timeout and returns the transcript")
    func listenDefault() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(name: "listen", arguments: nil)
        #expect(text(result) == "hello from the mic")
        #expect(log.all == ["listen:30.0"])
    }

    @Test("listen clamps the timeout to 5…120 seconds")
    func listenClamped() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        _ = await registry.call(name: "listen", arguments: ["timeout_s": .int(2)])
        _ = await registry.call(name: "listen", arguments: ["timeout_s": .double(900)])
        #expect(log.all == ["listen:5.0", "listen:120.0"])
    }

    @Test("stop_speaking always succeeds")
    func stop() async {
        let log = HandlerLog()
        let registry = MCPToolRegistry(makeVoiceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(name: "stop_speaking", arguments: nil)
        #expect(result.isError != true)
        #expect(log.all == ["stop"])
    }
}
