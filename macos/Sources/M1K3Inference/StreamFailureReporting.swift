//
//  StreamFailureReporting.swift
//  M1K3Inference
//
//  `InferenceProvider.generateStreaming` ends the stream on error rather than
//  throwing (its contract), so a consumer that sees an EMPTY stream cannot tell
//  "the model said nothing" from "the call failed". A provider that can name the
//  failure adopts this seam; the eval loop asks through `as?`, the way
//  `PersonaCarrying` and `ToolCallingProvider` are reached. Not conforming keeps
//  the old behaviour exactly.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85 (the first frontier
//  run scored nine provider refusals as "0 chars"; the same shape was latent on
//  the PCC column). Prior: Unknown
//

import Foundation
import Synchronization

public protocol StreamFailureReporting: Sendable {
    /// The failure the last `generateStreaming` swallowed, cleared on read; nil
    /// when the last stream ended normally.
    func takeStreamFailure() -> String?
}

/// The one-slot box the adopters share. A class, not a `Mutex` field: `Mutex` is
/// non-copyable and providers are passed by value.
public final class StreamFailureBox: Sendable {
    private let value = Mutex<String?>(nil)

    public init() {}

    public func record(_ description: String) {
        value.withLock { $0 = description }
    }

    public func take() -> String? {
        value.withLock { v in
            defer { v = nil }
            return v
        }
    }
}
