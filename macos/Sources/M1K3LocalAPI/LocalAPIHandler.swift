//
//  LocalAPIHandler.swift
//  M1K3LocalAPI
//
//  One request in, one reply out: the Local API's whole behaviour without a
//  socket, so it is tested against a fake brain. The listener only reads bytes
//  into a `LocalAPIRequest` and writes the reply's pieces back.
//
//  Rules it keeps:
//  - Nothing is served before the gate passes (loopback Host, no Origin, the token).
//  - One chat call at a time, and the person at the Mac goes first: a call that
//    arrives while they are chatting is told to come back, and a call in flight
//    ends when they start (`preempt`).
//  - A model that is not ready is "not found", never a brain swap.
//  - A failure is said: as a status while nothing has been sent, as an error
//    event once a stream has begun. Never a successful empty answer.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.8, Prior: none (new file)
//  Review: Kev + claude-fable-5.2, 2026-11-11 (#621) — `isAnswering` says a call holds the brain, so the launch warm
//  can wait for it. Confidence unchanged.
//

import Foundation
import M1K3Inference

/// What the app gives the Local API: which brains can answer now, whether the
/// person at the Mac is using M1K3, and a raw chat on one brain.
public struct LocalAPIBackend: Sendable {
    public var models: @Sendable () async -> [String]
    public var userBusy: @Sendable () async -> Bool
    /// Nil when that brain cannot serve a raw chat right now.
    public var complete: @Sendable (_ model: String, _ request: RawChatRequest) async -> RawChatStream?

    public init(
        models: @escaping @Sendable () async -> [String],
        userBusy: @escaping @Sendable () async -> Bool,
        complete: @escaping @Sendable (String, RawChatRequest) async -> RawChatStream?
    ) {
        self.models = models
        self.userBusy = userBusy
        self.complete = complete
    }
}

/// The bytes of one reply, in order. A buffered reply is one piece; a stream is many.
public struct LocalAPIReply: Sendable {
    public let pieces: AsyncStream<Data>

    static func buffered(_ data: Data) -> LocalAPIReply {
        LocalAPIReply(pieces: AsyncStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }

    static func refusal(_ error: LocalAPIError) -> LocalAPIReply {
        buffered(LocalAPIWire.response(for: error))
    }
}

public actor LocalAPIHandler {
    private let port: UInt16
    private let token: @Sendable () -> String
    private let backend: LocalAPIBackend
    private let now: @Sendable () -> Int
    private let newID: @Sendable () -> String

    /// The one chat call in flight, if any.
    private var claimed = false
    private var inFlight: Task<Void, Never>?
    private var preempted = false

    public init(
        port: UInt16, token: @escaping @Sendable () -> String, backend: LocalAPIBackend,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
        newID: @escaping @Sendable () -> String = { "chatcmpl-" + UUID().uuidString.lowercased() }
    ) {
        self.port = port
        self.token = token
        self.backend = backend
        self.now = now
        self.newID = newID
    }

    /// Whether a chat call holds the brain right now. The launch warm reads it and waits (#621).
    public var isAnswering: Bool {
        claimed
    }

    /// The person at the Mac has started using M1K3: a call in flight ends now.
    public func preempt() {
        // A call still being admitted has claimed the slot but has no task yet: mark it, and it
        // is stopped the moment it would start.
        guard claimed else { return }
        preempted = true
        inFlight?.cancel()
    }

    public func reply(to request: LocalAPIRequest) async -> LocalAPIReply {
        if let refusal = LocalAPIGate.check(
            hosts: request.headers["host"] ?? [], origin: request.first("origin"),
            authorization: request.first("authorization"), port: port, token: token()
        ) {
            return .refusal(refusal)
        }
        switch LocalAPIRoute.classify(method: request.method, path: request.path) {
        case .models:
            return await .buffered(LocalAPIWire.response(
                status: 200, body: LocalAPIWire.modelsBody(ids: backend.models(), created: now())
            ))
        case .chatCompletions:
            return await chat(request)
        case let .unsupported(path):
            return .refusal(.unsupportedEndpoint(path))
        case .preflight:
            return .refusal(.forbidden("M1K3's Local API does not serve web pages."))
        case .notFound:
            return .refusal(.notFound(request.path))
        }
    }

    private func chat(_ request: LocalAPIRequest) async -> LocalAPIReply {
        // The reader takes Content-Length bodies only: say so, rather than "the body must be JSON".
        if request.first("transfer-encoding") != nil {
            return .refusal(.invalid("Send the body with a Content-Length header; chunked uploads are not supported."))
        }
        let call: ChatCompletionCall
        switch ChatCompletionCall.parse(request.body) {
        case let .success(parsed): call = parsed
        case let .failure(error): return .refusal(error)
        }
        // Claim the slot BEFORE the first suspension, so two calls cannot both pass admission.
        let mine = !claimed
        if mine {
            claimed = true
            preempted = false
        }
        let available = await backend.models()
        let userBusy = await backend.userBusy()
        if let refusal = LocalAPIAdmission.decide(
            requested: call.model, available: available, userBusy: userBusy, apiBusy: !mine
        ) {
            if mine { claimed = false }
            return .refusal(refusal)
        }
        // The person at the Mac started a turn while this call was being admitted.
        if preempted {
            claimed = false
            return .refusal(.busy(retryAfter: 10))
        }
        guard let stream = await backend.complete(call.model, call.request) else {
            claimed = false
            return .refusal(.modelNotFound(call.model, available: available.filter { $0 != call.model }))
        }
        if preempted {
            claimed = false
            return .refusal(.busy(retryAfter: 10))
        }
        let (pieces, continuation) = AsyncStream<Data>.makeStream()
        let identity = (id: newID(), created: now())
        let task = Task {
            await self.run(call, stream: stream, identity: identity, into: continuation)
            await self.release()
            continuation.finish()
        }
        inFlight = task
        // The client went away: stop generating for nobody.
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return LocalAPIReply(pieces: pieces)
    }

    private func release() {
        claimed = false
        inFlight = nil
    }

    /// Reset only when the next call claims the slot (`chat`), so a finished call's flag can never
    /// be read by another.
    private var wasPreempted: Bool {
        preempted
    }

    /// Drain one generation into the reply. Nonisolated work between hops: the actor is only asked whether
    /// the call was preempted.
    private nonisolated func run(
        _ call: ChatCompletionCall, stream: RawChatStream, identity: (id: String, created: Int),
        into continuation: AsyncStream<Data>.Continuation
    ) async {
        let (id, created) = identity
        var filter = StopSequenceFilter(stops: call.stop)
        var sentHead = false
        var text = ""
        var finish: RawChatFinish?
        var stopped = false

        func emit(_ piece: String) {
            guard !piece.isEmpty else { return }
            text += piece
            guard call.stream else { return }
            if !sentHead {
                continuation.yield(LocalAPIWire.sseHead)
                continuation.yield(LocalAPIWire.chunk(id: id, model: call.model, created: created, role: true))
                sentHead = true
            }
            continuation.yield(LocalAPIWire.chunk(id: id, model: call.model, created: created, content: piece))
        }

        func fail(_ error: LocalAPIError) {
            if call.stream, sentHead {
                continuation.yield(LocalAPIWire.errorEvent(error))
            } else {
                continuation.yield(LocalAPIWire.response(for: error))
            }
        }

        do {
            events: for try await event in stream {
                switch event {
                case let .delta(delta):
                    let step = filter.push(delta)
                    emit(step.emit)
                    if step.stopped {
                        stopped = true
                        break events
                    }
                case let .finished(done):
                    finish = done
                }
            }
            // A cancelled stream ends quietly: tell a preemption from a finished answer. An answer that
            // DID finish stands, even if the person at the Mac started a turn a moment later.
            if finish == nil, !stopped, await wasPreempted { return fail(.busy(retryAfter: 10)) }
            if Task.isCancelled { return }
            if !stopped { emit(filter.flush()) }
            let done = finish ?? RawChatFinish(reason: .stop, promptTokens: nil, completionTokens: nil)
            let ended = RawChatFinish(
                reason: stopped ? .stop : done.reason, promptTokens: done.promptTokens,
                completionTokens: done.completionTokens
            )
            guard call.stream else {
                continuation.yield(LocalAPIWire.response(status: 200, body: LocalAPIWire.completionBody(
                    id: id, model: call.model, created: created, text: text, finish: ended
                )))
                return
            }
            if !sentHead {
                continuation.yield(LocalAPIWire.sseHead)
                continuation.yield(LocalAPIWire.chunk(id: id, model: call.model, created: created, role: true))
            }
            continuation.yield(LocalAPIWire.chunk(id: id, model: call.model, created: created, finish: ended.reason))
            if call.includeUsage {
                continuation.yield(LocalAPIWire.usageChunk(id: id, model: call.model, created: created, finish: ended))
            }
            continuation.yield(LocalAPIWire.done)
        } catch {
            if await wasPreempted { return fail(.busy(retryAfter: 10)) }
            if error is CancellationError { return }
            fail(LocalAPIError(failure: error))
        }
    }
}
