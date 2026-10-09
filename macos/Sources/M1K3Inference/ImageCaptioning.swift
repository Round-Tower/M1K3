//
//  ImageCaptioning.swift
//  M1K3Inference
//
//  The one narrow seam for "describe this picture, neutrally, in the
//  background" (caption memory, Stream D 1.1 slice). It exists because the
//  two obvious routes are both wrong: `generate(prompt:)` honours
//  `InferenceIntent.instructions` but is text-only, and the tool-turn session
//  carries images but seeds from the PERSONA snapshot and never reads the
//  override -- the persona-in-utility trap (2026-09-26/27).
//
//  This is an `as?` capability seam, so EVERY façade must forward it
//  (SwappableInferenceProvider here, RuntimeInferenceProvider in the app) or
//  the cast fails silently in production. Pinned by ImageCaptioningTests
//  (the package façade) and ImageCaptionerTests.throughFacade.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

/// A provider whose model can read an image and answer about it OUTSIDE a chat
/// turn: no persona, no tools, no cached-prefix seed, thinking off.
public protocol ImageCaptioning: Sendable {
    /// The model's answer to `prompt` about `image`. The system turn is
    /// `InferenceIntent.instructions` and nothing else -- an implementation
    /// MUST throw when it is nil rather than fall back to the persona. Raw
    /// output: the caller strips reasoning and checks for refusals.
    func caption(image: ImageAttachment, prompt: String) async throws -> String
}
