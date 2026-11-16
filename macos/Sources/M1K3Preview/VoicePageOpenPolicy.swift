//
//  VoicePageOpenPolicy.swift
//  M1K3Preview
//
//  When may voice mode open a page beside the avatar (#839)? Only when the person asked: a tap
//  on a link chip or a spoken request ("show me that"). A request that came from model output
//  alone never opens anything, whatever it names: every load sends something off the device, so
//  the user asks for each one. The refusal happens BEFORE any lookup, so a model that merely
//  names a host causes no network traffic either.
//
//  Asked-for requests still go through `WebURLPolicy` (the same gate `open_link` uses), and the
//  quote, if any, becomes a text fragment (`TextFragmentURL`). `VoicePageSession` is the shared
//  state both shells render: the Mac host and the iOS host hold one and show its `url`.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85 (pure; the pin is the
//  model-output test). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: `deferOpen` (one pending open, cancelled by `close()`).

import Foundation
import Observation

public struct VoicePageOpenRequest: Sendable, Equatable {
    /// Who is asking. Only the first two are the person.
    public enum Origin: Sendable, Equatable {
        case linkChipTap
        case spokenRequest
        case modelOutput
    }

    public let origin: Origin
    public let url: URL
    /// The passage to highlight, when the answer quoted one.
    public let quote: String?

    public init(origin: Origin, url: URL, quote: String? = nil) {
        self.origin = origin
        self.url = url
        self.quote = quote
    }
}

public enum VoicePageRefusal: Sendable, Equatable {
    /// The request did not come from the person.
    case notAskedFor
    /// Not an http(s) URL.
    case notWebPage
    /// A local or private address, or a name that resolves into one.
    case privateAddress
}

public enum VoicePageOpenDecision: Sendable, Equatable {
    case open(URL)
    case refused(VoicePageRefusal)
}

public enum VoicePageOpenPolicy {
    public static func decide(
        _ request: VoicePageOpenRequest, resolver: any HostResolving
    ) async -> VoicePageOpenDecision {
        switch request.origin {
        case .modelOutput:
            return .refused(.notAskedFor)
        case .linkChipTap, .spokenRequest:
            break
        }
        guard let target = TextFragmentURL.url(for: request.url, quote: request.quote) else {
            return .refused(.notWebPage)
        }
        // Judge the page, not the fragment: the host is what leaves the device.
        guard await !WebURLPolicy.isLocalOrPrivate(request.url, resolver: resolver) else {
            return .refused(.privateAddress)
        }
        return .open(target)
    }
}

/// What voice mode's page host shows. One per shell; `open` is the only way in.
@MainActor
@Observable
public final class VoicePageSession {
    /// The page on show (with its text fragment), or nil when closed.
    public private(set) var url: URL?
    /// Why the last request was refused, until the next good open or a close.
    public private(set) var refusal: VoicePageRefusal?

    @ObservationIgnored private let resolver: any HostResolving
    /// Bumped per request and per close: an open that finishes its lookup after a newer
    /// request (or a close) is dropped, so a slow lookup cannot reopen a closed page.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(resolver: any HostResolving = SystemHostResolver()) {
        self.resolver = resolver
    }

    public var isOpen: Bool {
        url != nil
    }

    public func open(_ request: VoicePageOpenRequest) async {
        generation += 1
        let mine = generation
        let decision = await VoicePageOpenPolicy.decide(request, resolver: resolver)
        guard mine == generation else { return }
        switch decision {
        case let .open(target):
            refusal = nil
            url = target
        case let .refused(reason):
            // A model-originated request is not the person's, so it says nothing either.
            if reason != .notAskedFor { refusal = reason }
        }
    }

    /// Run `work` (an open that waits for something, like an answer's sources) as the session's one
    /// pending open. A newer one replaces it, and `close()` cancels it, so a page the person closed
    /// cannot reopen itself later.
    @discardableResult
    public func deferOpen(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        pending?.cancel()
        let task = Task { @MainActor in await work() }
        pending = task
        return task
    }

    public func close() {
        generation += 1
        pending?.cancel()
        pending = nil
        url = nil
        refusal = nil
    }
}
