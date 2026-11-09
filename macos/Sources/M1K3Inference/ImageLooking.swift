//
//  ImageLooking.swift
//  M1K3Inference
//
//  The seam for "look at this frame and answer me, now" (#768): the streamed
//  sibling of `ImageCaptioning`. One image, one question, the instructions the
//  caller hands over and NOTHING else: no persona, no tools, no grounding, no
//  history. That leanness is the whole point. On the iPhone 17 Pro the chat
//  send took 9 s to first text on Lil with a photo (an image in the transcript
//  vetoes the cached prefix) while this shape answered in under a second on
//  both brains (docs/evals/2026-11-09-vision-ttft-iphone/).
//
//  The instructions are a PARAMETER, not `InferenceIntent.instructions`: a
//  look's stream outlives the call that made it, and a task-local read inside
//  a detached generation task would see nil.
//
//  This is an `as?` capability seam, so EVERY façade must forward it
//  (SwappableInferenceProvider here, RuntimeInferenceProvider in the app) or
//  the cast fails silently in production. Only the on-device brains conform:
//  Brain at Home and Private Cloud Compute do not, so a frame handed to this
//  seam cannot leave the device (pinned by `LookEgressTests` in
//  M1K3BrainLinkTests and M1K3AgentTests).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8, Prior: none (new file)
//  Context: Kev, 2026-11-09: "Let's implement the vision on this research pal,
//  and make it easily accessible via chat, and voice interfaces".
//  Open: the 10-minute heat and battery soak (#768) is not run; the route is
//  measured on one photo of one street.
//  Review: Kev + claude-fable-5.2, 2026-11-09 (review fold, before the first
//  push) — two lines for a look that never reached a brain: `noFrame` (the
//  camera gave no picture) and `cameraOff` (access is refused). A turn that
//  asked to look says one of them instead of becoming an ordinary send.

import Foundation

/// A look's answer: cumulative snapshots, finishing by throwing on failure.
public typealias LookStream = AsyncThrowingStream<String, any Error>

/// A provider whose model can look at one image and answer about it as a
/// stream, outside a chat turn: no persona, no tools, thinking off.
public protocol ImageLooking: Sendable {
    /// CUMULATIVE snapshots of the answer to `prompt` about `image` (each
    /// element is the whole answer so far, the shape `PrivateCloudAnswering`
    /// streams). The system turn is `instructions` and nothing else. The stream
    /// finishes by throwing when the backend cannot look or the model fails;
    /// cancelling the consumer stops the generation.
    func look(image: ImageAttachment, instructions: String, prompt: String) -> LookStream
}

public enum ImageLookingError {
    /// What a façade's stream throws when the active backend has no eyes.
    public static let cannotLook = InferenceError.generationFailed("active backend cannot look at images")

    /// The system turn of a look, trimmed. NEVER the persona: blank
    /// instructions are the caller's bug and fail loudly on every backend.
    public static func instructions(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InferenceError.generationFailed("a look needs instructions")
        }
        return trimmed
    }
}

/// A look the backend could not finish, with the honest sentence to show for
/// it. The chat turn prints `reply` as the answer; anything else thrown gets
/// `LookFailureReply.tryAgain`.
public struct LookDeclined: Error, Sendable, Equatable {
    public let reply: String

    public init(reply: String) {
        self.reply = reply
    }
}

/// What M1K3 says when a look fails, by failure class: never a guess at what
/// was in view. A passing failure asks for another try; a guardrail or an
/// unplaced throw declines and names the brains that can look instead (the
/// `AFMToolPrompt.visionFailureReply` reasoning: "try again" on a guardrail is
/// a loop, a brain switch always resolves).
public enum LookFailureReply {
    public static let tryAgain = "I couldn't get a look at that just now. Try again in a moment."
    /// The brain that would answer has no eyes (Brain at Home, a text-only
    /// checkpoint): "try again" would loop, so name the way out.
    public static let cannotSee =
        "The brain that's answering right now can't see. Switch to one that can and ask again."

    /// The camera gave no picture (it would not open, it was taken away, the
    /// frame was stale): said instead of answering blind, or from memory.
    public static let noFrame = "I couldn't get a picture just then. Try again in a moment."
    /// The camera is refused: no retry helps until Settings changes.
    public static let cameraOff = "Camera access is off for M1K3. You can allow it in Settings."

    /// The line for anything a look throws: the backend's own sentence when it
    /// declined, the way out when it has no eyes, another go for the rest.
    public static func reply(for error: any Error) -> String {
        if let declined = error as? LookDeclined { return declined.reply }
        if let known = error as? InferenceError, known == ImageLookingError.cannotLook { return cannotSee }
        return tryAgain
    }

    public static func reply(for failure: AFMFailure, platform: BrainTier.DevicePlatform) -> String {
        reply(for: failure, readers: BrainTier.imageReaders(platform: platform))
    }

    public static func reply(for failure: AFMFailure, readers: [BrainTier]) -> String {
        switch failure {
        case .rateLimited, .daemonUnavailable, .timeout, .contextOverflow:
            return tryAgain
        case .unsupportedLanguage:
            return AFMFailure.unsupportedLanguageReply
        case .guardrailViolation, .unknown:
            let decline = "I couldn't make that out on this brain, so I won't guess at what's in view."
            guard !readers.isEmpty else { return decline }
            let names = readers.map(\.displayName).joined(separator: " or ")
            return decline + " Switch to \(names) and ask again."
        }
    }
}

extension SwappableInferenceProvider: ImageLooking {
    /// Forwards to whichever backend is active when the look STARTS. A backend
    /// without the capability fails the stream; it never answers blind.
    public func look(image: ImageAttachment, instructions: String, prompt: String) -> LookStream {
        guard let looker = active as? ImageLooking else {
            return AsyncThrowingStream { $0.finish(throwing: ImageLookingError.cannotLook) }
        }
        return looker.look(image: image, instructions: instructions, prompt: prompt)
    }
}
