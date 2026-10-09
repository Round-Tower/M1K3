//
//  ImageCaptioner.swift
//  M1K3Chat
//
//  Runs one caption: policy check, then the provider's `ImageCaptioning`
//  capability under the NEUTRAL instructions and `backgroundUtility` -- the same
//  wrapper the call summaries and titles use (InferenceIntent), not a second
//  seam. The `as?` cast lives here, once, and a miss is a reported failure, never
//  a silent skip.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

import Foundation
import M1K3Inference

public struct ImageCaptioner: Sendable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        /// The selected brain cannot caption; the message names it.
        case refused(String)
        /// The provider has no captioning capability (a façade that did not forward it).
        case unavailable
        /// The model's answer was empty, a refusal, or a persona leak.
        case unusable

        public var errorDescription: String? {
            switch self {
            case let .refused(message): message
            case .unavailable: String(localized: "This brain can't read photos right now.")
            case .unusable: String(localized: "I couldn't make out that photo. Try again?")
            }
        }
    }

    private let provider: any InferenceProvider

    public init(provider: any InferenceProvider) {
        self.provider = provider
    }

    /// `tier` is the brain the user has SELECTED -- never load another to caption.
    public func caption(image: ImageAttachment, tier: BrainTier) async throws -> String {
        if case let .refused(message) = ImageCaptionPolicy.decision(for: tier) {
            throw Failure.refused(message)
        }
        guard let captioner = provider as? ImageCaptioning else { throw Failure.unavailable }
        let raw = try await InferenceIntent.withInstructions(ImageCaptionPolicy.neutralInstructions) {
            try await InferenceIntent.backgroundUtility {
                try await captioner.caption(image: image, prompt: ImageCaptionPolicy.prompt)
            }
        }
        guard let cleaned = ImageCaptionPolicy.clean(raw) else { throw Failure.unusable }
        return cleaned
    }
}
