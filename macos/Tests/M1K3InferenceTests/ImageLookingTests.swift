//
//  ImageLookingTests.swift
//  M1K3InferenceTests
//
//  ImageLooking is an `as?` capability seam: the package façade must forward
//  it (the app's RuntimeInferenceProvider mirrors it by hand, compile-checked),
//  and a backend that cannot look must fail the STREAM, never answer blind.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85, Prior: none (new file)
//  Context: #768, realtime vision on the phone. The lean look route measured in
//  docs/evals/2026-11-09-vision-ttft-iphone/ becomes a seam.

import Foundation
import M1K3Inference
import Testing

private struct BlindProvider: InferenceProvider {
    let name = "blind"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "blind"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

private struct LookerProvider: InferenceProvider, ImageLooking {
    let name = "looker"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "looker"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func look(image: ImageAttachment, instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("saw")
            continuation.yield("saw \(image.url.lastPathComponent)|\(instructions)|\(prompt)")
            continuation.finish()
        }
    }
}

struct ImageLookingTests {
    private let image = ImageAttachment(url: URL(fileURLWithPath: "/tmp/frame.jpg"))

    private func drain(_ stream: AsyncThrowingStream<String, any Error>) async throws -> [String] {
        var snapshots: [String] = []
        for try await snapshot in stream {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    @Test("a look reaches the real backend through the façade, snapshots and arguments intact")
    func lookForwards() async throws {
        let facade = SwappableInferenceProvider(LookerProvider())
        let snapshots = try await drain(facade.look(image: image, instructions: "i", prompt: "p"))
        #expect(snapshots == ["saw", "saw frame.jpg|i|p"])
    }

    @Test("a backend that cannot look fails the stream: nothing is yielded, and the error says why")
    func blindBackendThrows() async {
        let facade = SwappableInferenceProvider(BlindProvider())
        var yielded: [String] = []
        var failure: InferenceError?
        do {
            for try await snapshot in facade.look(image: image, instructions: "i", prompt: "p") {
                yielded.append(snapshot)
            }
        } catch let error as InferenceError {
            failure = error
        } catch {}
        #expect(yielded.isEmpty)
        #expect(failure == ImageLookingError.cannotLook)
    }

    @Test("the façade asks the backend that is active when the look starts")
    func lookFollowsTheSwap() async throws {
        let facade = SwappableInferenceProvider(BlindProvider())
        facade.setProvider(LookerProvider())
        let snapshots = try await drain(facade.look(image: image, instructions: "i", prompt: "p"))
        #expect(snapshots.last == "saw frame.jpg|i|p")
    }
}
