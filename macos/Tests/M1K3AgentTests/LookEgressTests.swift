//
//  LookEgressTests.swift
//  M1K3AgentTests
//
//  A look's frame stays on the device (#768). Private Cloud Compute answers
//  off the device, behind its own consent (`PrivateCloudArming`, ADR 0010), so
//  neither its adapter nor its backend may gain eyes by accident: these fail
//  the day someone conforms either to `ImageLooking`.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85, Prior: none (new file)
//  Context: the twin, for Brain at Home, is in M1K3BrainLinkTests.
//

import Foundation
import M1K3Agent
import M1K3Inference
import M1K3LanguageModel
import Synchronization
import Testing

struct LookEgressTests {
    @Test("the Private Cloud adapter has no eyes")
    func cloudAdapterCannotLook() {
        let type: Any.Type = PrivateCloudInferenceAdapter.self
        #expect(!(type is any ImageLooking.Type))
        #expect(!(type is any ImageCaptioning.Type))
    }

    #if compiler(>=6.4)
        @Test("the Private Cloud backend has no eyes")
        func cloudBackendCannotLook() {
            guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) else { return }
            let type: Any.Type = PrivateCloudComputeBackend.self
            #expect(!(type is any ImageLooking.Type))
        }
    #endif

    @Test("a look through a façade whose brain is the cloud adapter fails on the device")
    func lookThroughTheFacadeNeverReachesTheCloud() async {
        let cloud = CountingCloud()
        let adapter = PrivateCloudInferenceAdapter(backend: cloud, instructions: { "persona" })
        let facade = SwappableInferenceProvider(adapter)
        let frame = ImageAttachment(url: URL(fileURLWithPath: "/tmp/look-egress-frame.jpg"))
        var thrown: (any Error)?
        do {
            for try await _ in facade.look(image: frame, instructions: "Say what you see.", prompt: "What is this?") {
                Issue.record("a blind brain must not answer")
            }
        } catch {
            thrown = error
        }
        #expect(thrown as? InferenceError == ImageLookingError.cannotLook)
        #expect(cloud.asked.count == 0)
    }
}

/// A cloud that counts what it is asked. A look must leave it at zero.
private final class CountingCloud: PrivateCloudAnswering, Sendable {
    final class Counter: Sendable {
        private let value = Mutex(0)
        var count: Int {
            value.withLock { $0 }
        }

        func bump() {
            value.withLock { $0 += 1 }
        }
    }

    let asked = Counter()

    func status() async -> PrivateCloudStatus {
        PrivateCloudStatus(available: true, quota: .belowLimit)
    }

    func answer(instructions _: String, prompt _: String) -> AsyncThrowingStream<String, any Error> {
        asked.bump()
        return AsyncThrowingStream { $0.finish() }
    }
}
