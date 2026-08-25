//
//  HomeBrainProvider.swift
//  M1K3BrainLink
//
//  The Mac's brain as an InferenceProvider on the device. Raw compute only:
//  the SERVER strips nothing because there is nothing to strip — /v1/generate
//  runs persona-free, tool-free, retrieval-free by construction (spec §2), so
//  the DEVICE keeps its own persona, grounding and tools and borrows the
//  Mac's decode. That means the provider slots into the existing responder
//  unchanged.
//
//  Failure is words, not silence: a 429 refusal or a dead link renders the
//  etiquette copy into the stream (the InferenceProvider streaming contract
//  terminates on error rather than throwing — an empty bubble would read as
//  a broken app, and the refusal IS the answer). Pre-token connect failures
//  walk the dial order; a break mid-stream never retries (no duplicated
//  half-answers).
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85 (behaviour
//  table-tested over an injected transport; live-LAN feel is the Phase C
//  hardware verify). Prior: BRAIN_AT_HOME_SPEC §2/§5.
//

import Foundation
import M1K3Inference
import M1K3LogCore
import os

public final class HomeBrainProvider: InferenceProvider, Sendable {
    /// A /v1/generate SSE exchange: (requestBytes, host, port, credential) →
    /// throwing token stream. Injected so the flow is table-testable;
    /// the default is BrainConnection.stream.
    public typealias StreamTransport = @Sendable (Data, String, UInt16, PSKCredential)
        -> AsyncThrowingStream<String, Error>

    private static let log = M1K3Log.logger(.brainLink)

    private let state: OSAllocatedUnfairLock<PairedBrain>
    private let credential: PSKCredential
    private let transport: StreamTransport
    private let onBrainUpdate: @Sendable (PairedBrain) -> Void

    public let name: String

    /// Optimistic — a LAN link's real availability is only knowable by
    /// dialing, and failures speak per-turn. The Settings card carries the
    /// live health reading; this flag only orders the router.
    public var isAvailable: Bool {
        true
    }

    public init(
        brain: PairedBrain,
        key: Data,
        transport: @escaping StreamTransport = { bytes, host, port, credential in
            BrainConnection.stream(bytes, host: host, port: port, credential: credential)
        },
        onBrainUpdate: @escaping @Sendable (PairedBrain) -> Void
    ) {
        state = OSAllocatedUnfairLock(initialState: brain)
        credential = PSKCredential(identity: brain.identity, key: key)
        self.transport = transport
        self.onBrainUpdate = onBrainUpdate
        name = "Home — \(brain.name)"
    }

    // MARK: - InferenceProvider

    public func generate(prompt: String) async throws -> String {
        var assembled = ""
        do {
            for try await token in rawStream(prompt) {
                assembled += token
            }
        } catch {
            if assembled.isEmpty {
                throw InferenceError.generationFailed(Self.friendlyLine(for: error))
            }
            // Same contract as the streaming path: a partial answer carries
            // the interruption note — it must never read as complete
            // (PR #152 review, finding 3).
            return assembled + "\n\n" + Self.friendlyLine(for: error)
        }
        return assembled
    }

    public func generateStreaming(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { [rawStream] in
                var yieldedAny = false
                do {
                    for try await token in rawStream(prompt) {
                        yieldedAny = true
                        continuation.yield(token)
                    }
                } catch {
                    // The refusal (or the drop) IS the visible answer — an
                    // empty bubble reads as a broken app.
                    let line = Self.friendlyLine(for: error)
                    continuation.yield(yieldedAny ? "\n\n\(line)" : line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Dial-order streaming

    private var rawStream: @Sendable (String) -> AsyncThrowingStream<String, Error> {
        { [state, credential, transport, onBrainUpdate] prompt in
            AsyncThrowingStream { continuation in
                let task = Task {
                    let brain = state.withLock { $0 }
                    let body = BrainLinkFrames.generateBody(prompt: prompt, maxTokens: nil)
                    var lastError: Error = BrainLinkError.unreachable("no address for the Mac")
                    for host in brain.dialOrder {
                        var yieldedAny = false
                        do {
                            let request = BrainLinkFrames.post("/v1/generate", host: host, body: body)
                            for try await token in transport(request, host, brain.mainPort, credential) {
                                yieldedAny = true
                                continuation.yield(token)
                            }
                            if brain.lastKnownHost != host {
                                let updated = state.withLock { current in
                                    current.lastKnownHost = host
                                    return current
                                }
                                onBrainUpdate(updated)
                            }
                            continuation.finish()
                            return
                        } catch {
                            // Mid-stream breaks never retry (a second host
                            // would duplicate the half-answer); pre-token
                            // connect failures walk the dial order. A refusal
                            // is authoritative — the Mac answered.
                            if yieldedAny {
                                continuation.finish(throwing: error)
                                return
                            }
                            switch error as? BrainLinkError {
                            case .unreachable, .timedOut:
                                lastError = error
                                continue
                            default:
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                    Self.log.notice("home brain: no host reachable")
                    continuation.finish(throwing: lastError)
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    static func friendlyLine(for error: Error) -> String {
        switch error as? BrainLinkError {
        case let .refused(refusal):
            refusal.userMessage
        case .unreachable, .timedOut:
            "Couldn’t reach your Mac — check it’s awake, on the same network, and serving in Settings → Privacy → Brain at Home."
        case let .unavailable(reason):
            "Your Mac’s brain can’t serve remotely right now (\(reason))."
        case .streamInterrupted:
            "(The connection to your Mac was interrupted.)"
        case let .badResponse(reason):
            "The Mac sent an unexpected reply (\(reason))."
        case nil:
            "Couldn’t use your Mac’s brain: \(error.localizedDescription)"
        }
    }
}
