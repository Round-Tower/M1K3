//
//  VoiceMCPTools.swift
//  M1K3MCPKit
//
//  Voice tools for the in-app MCP server: speak / stop_speaking /
//  get_status / listen. Handlers are injected closures — the app wires
//  them to its speech provider, avatar, and transcription router on the
//  MainActor; this package stays free of M1K3Voice/M1K3Avatar links (emotion
//  crosses as a plain string, mirroring the app's toolsProvider pattern).
//
//  `listen` is the "pipe transcription to Claude" v1: a pull-model tool — the
//  client asks, M1K3 listens until silence or timeout, the transcript returns
//  as the result. No server-push plumbing needed.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (contract
//  test-pinned with fakes; live handlers are app glue, verify-at-⌘R).
//  Prior: Unknown.
//
//  Review: Kev + claude-fable-5, 2026-08-19, Confidence 0.9. speak wait:true is
//  now bounded (~25s): the utterance runs detached and a long read hands back a
//  still-speaking note instead of blowing the MCP client's request timeout while
//  the audio plays fine (the logged 2026-08-10 symptom). Also corrected the
//  stale "serial server" rationale — the server interleaves requests; the
//  client's own timeout is the real reason wait defaults false. TDD'd.
//

import Foundation
import MCP

/// Snapshot of the speech stack for `get_status`. The busy flags are
/// computed from the SAME predicates the speak/listen guards use — the whole
/// point is that an agent can poll for readiness instead of getting blind
/// errors (test-report F2).
public struct VoiceStatus: Sendable, Equatable {
    public let providerName: String
    public let tier: String
    /// Active brain tier ("Big", "Mini", etc.) — an agent deciding whether to
    /// delegate wants to know if it's talking to Mini or Big.
    public let brain: String
    /// True from utterance start (synthesis included) until playback ends.
    public let isSpeaking: Bool
    /// The lock that gates `speak` and `ask_m1k3`: a live voice-mode loop or
    /// an in-flight chat turn.
    public let inConversation: Bool
    /// The lock that gates `listen`: dictation, call recording, or voice mode.
    public let micInUse: Bool
    /// True while an `ask_m1k3` call is generating. Distinct from
    /// `inConversation` (the chat UI / voice loop): an MCP ask is single-flight,
    /// and a second one bounces — so a visiting agent can poll this instead of
    /// discovering the lock by hitting an error (test-report F2).
    public let answering: Bool

    public init(
        providerName: String,
        tier: String,
        brain: String = "",
        isSpeaking: Bool,
        inConversation: Bool = false,
        micInUse: Bool = false,
        answering: Bool = false
    ) {
        self.providerName = providerName
        self.tier = tier
        self.brain = brain
        self.isSpeaking = isSpeaking
        self.inConversation = inConversation
        self.micInUse = micInUse
        self.answering = answering
    }
}

/// A tool error with a clean, client-facing message.
public struct MCPVoiceError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// The app-injected implementations behind the voice tools.
public struct VoiceToolHandlers: Sendable {
    /// `wait: false` returns at utterance start; `wait: true` returns after
    /// playback ends. (The server handles requests concurrently — the old
    /// "serial loop starves status polls" rationale was corrected 2026-08-19;
    /// the reason wait defaults false is the CLIENT's own request timeout,
    /// which the tool layer additionally bounds with `speakWaitCapSeconds`.)
    public var speak: @Sendable (_ text: String, _ emotion: String?, _ wait: Bool) async throws -> Void
    public var stopSpeaking: @Sendable () async -> Void
    public var status: @Sendable () async -> VoiceStatus
    public var listen: @Sendable (_ timeoutSeconds: Double) async throws -> String

    public init(
        speak: @escaping @Sendable (_ text: String, _ emotion: String?, _ wait: Bool) async throws -> Void,
        stopSpeaking: @escaping @Sendable () async -> Void,
        status: @escaping @Sendable () async -> VoiceStatus,
        listen: @escaping @Sendable (_ timeoutSeconds: Double) async throws -> String
    ) {
        self.speak = speak
        self.stopSpeaking = stopSpeaking
        self.status = status
        self.listen = listen
    }
}

/// Bounds for the `listen` tool's timeout — long enough for a real sentence,
/// short enough that a forgotten call cannot hold the mic open for minutes.
public func clampListenTimeout(_ seconds: Double) -> Double {
    min(max(seconds, 5), 120)
}

/// How long `speak wait:true` blocks before handing back an honest
/// still-speaking note. Playback continues regardless — the caller polls
/// `get_status.speaking`. Kept well under the MCP client's ~60s request
/// deadline: a long Kokoro read used to blow that deadline while the speech
/// played fine, and the resulting error read as "broken", not "long".
public let defaultSpeakWaitCapSeconds: Double = 25

/// Terminal outcome of a detached speak — polled by the bounded wait. The
/// utterance task is never cancelled (the whole point is that playback
/// continues past the cap); only the first terminal transition counts.
private actor SpeakOutcome {
    enum State {
        case pending
        case spoken
        case failed(String)
    }

    private(set) var state: State = .pending

    func finish(_ errorMessage: String?) {
        guard case .pending = state else { return }
        state = errorMessage.map(State.failed) ?? .spoken
    }
}

private func speakDefinition(
    handlers: VoiceToolHandlers,
    speakWaitCapSeconds: Double
) -> MCPToolDefinition {
    MCPToolDefinition(
        tool: Tool(
            name: "speak",
            description: "Speak text aloud through M1K3's voice (and animate the avatar). Optional "
                + "emotion: happy, sad, angry, surprised, love, thinking, excited, sleepy, neutral. "
                + "Pass wait:true to return once playback finishes, or after ~25s with a "
                + "still-speaking note for a long read (poll get_status); default returns as "
                + "speech starts.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "what to say"],
                    "emotion": ["type": "string", "description": "avatar emotion while speaking (optional)"],
                    "wait": [
                        "type": "boolean",
                        "description": "return after playback completes, bounded at ~25s (default false)",
                    ],
                ],
                "required": ["text"],
            ]
        ),
        handler: { args in
            let text = stringArg(args, "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw MCPVoiceError("speak requires non-empty text") }
            let emotion = stringArg(args, "emotion")
            guard boolArg(args, "wait") ?? false else {
                try await handlers.speak(text, emotion, false)
                return "Speaking."
            }
            // Bounded wait: run the utterance detached and poll its outcome
            // until the cap. Never cancel it — a timeout must not cut the
            // audio; the caller just switches to polling get_status.
            let outcome = SpeakOutcome()
            Task {
                do {
                    try await handlers.speak(text, emotion, true)
                    await outcome.finish(nil)
                } catch let error as MCPVoiceError {
                    await outcome.finish(error.description)
                } catch {
                    await outcome.finish(error.localizedDescription)
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(speakWaitCapSeconds))
            while ContinuousClock.now < deadline {
                switch await outcome.state {
                case .spoken:
                    return "Spoken."
                case let .failed(message):
                    throw MCPVoiceError(message)
                case .pending:
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return "Still speaking — the utterance outlived this call’s "
                + "\(Int(speakWaitCapSeconds))s wait window. Poll get_status until "
                + "\"speaking\" is false. (Playback was not interrupted.)"
        }
    )
}

public func makeVoiceToolDefinitions(
    handlers: VoiceToolHandlers,
    speakWaitCapSeconds: Double = defaultSpeakWaitCapSeconds
) -> [MCPToolDefinition] {
    [
        speakDefinition(handlers: handlers, speakWaitCapSeconds: speakWaitCapSeconds),
        MCPToolDefinition(
            tool: Tool(
                name: "stop_speaking",
                description: "Stop any in-progress speech immediately.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                await handlers.stopSpeaking()
                return "Stopped."
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "get_status",
                description: "M1K3's overall status: active brain tier, TTS provider, voice tier, and "
                    + "the busy flags — whether M1K3 is speaking, in a conversation, using its mic, or "
                    + "already answering an ask_m1k3 call. Poll this before speak/listen/ask_m1k3.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                let status = await handlers.status()
                // Stable key order — clients parse this; dictionaries don't sort.
                return """
                {"provider":"\(status.providerName)","tier":"\(status.tier)",\
                "brain":"\(status.brain)","speaking":\(status.isSpeaking),\
                "in_conversation":\(status.inConversation),"mic_in_use":\(status.micInUse),\
                "answering":\(status.answering)}
                """
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "listen",
                description: "Listen on M1K3's microphone and return the transcript once the speaker "
                    + "pauses (or the timeout passes). Waits for any in-progress speech to finish "
                    + "before opening the mic — that wait comes OUT of timeout_s (at least 5s of "
                    + "real listening is always kept), so the call is bounded by roughly timeout_s "
                    + "overall. This is how you hear the user.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "timeout_s": ["type": "number", "description": "max seconds to listen (default 30, clamped 5-120)"],
                    ],
                ]
            ),
            handler: { args in
                let timeout = clampListenTimeout(doubleArg(args, "timeout_s") ?? 30)
                return try await handlers.listen(timeout)
            }
        ),
    ]
}
