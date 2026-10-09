//
//  ImageCaptioningTests.swift
//  M1K3InferenceTests
//
//  ImageCaptioning is an `as?` capability seam: the package façade must forward
//  it (the app's RuntimeInferenceProvider mirrors it by hand, compile-checked).
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85, Prior: Unknown

import Foundation
import M1K3Inference
import Testing

private struct PlainProvider: InferenceProvider {
    let name = "plain"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "plain"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

private struct CaptionerProvider: InferenceProvider, ImageCaptioning {
    let name = "captioner"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "captioner"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func caption(image: ImageAttachment, prompt: String) async throws -> String {
        "caption:\(image.url.lastPathComponent):\(prompt)"
    }
}

struct ImageCaptioningTests {
    @Test("image captioning reaches the real backend through the façade; a bare backend throws")
    func captionForwards() async throws {
        let image = ImageAttachment(url: URL(fileURLWithPath: "/tmp/a.jpg"))
        let facade = SwappableInferenceProvider(CaptionerProvider())
        #expect(try await facade.caption(image: image, prompt: "p") == "caption:a.jpg:p")
        facade.setProvider(PlainProvider())
        await #expect(throws: InferenceError.self) {
            try await facade.caption(image: image, prompt: "p")
        }
    }
}
