//
//  LookEgressTests.swift
//  M1K3BrainLinkTests
//
//  A look's frame stays on the device (#768). Brain at Home answers on the
//  Mac over the LAN, so it must never gain eyes by accident: these fail the
//  day someone conforms `HomeBrainProvider` to `ImageLooking`, and show that a
//  look through the façade while the home brain is active sends NOTHING.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85, Prior: none (new file)
//  Context: the twin, for Private Cloud Compute, is in M1K3AgentTests.
//

import Foundation
import M1K3BrainLink
import M1K3Inference
import Synchronization
import Testing

struct LookEgressTests {
    private let frame = ImageAttachment(url: URL(fileURLWithPath: "/tmp/look-egress-frame.jpg"))

    @Test("Brain at Home has no eyes: the type does not conform to the look seam")
    func homeBrainCannotLook() {
        let type: Any.Type = HomeBrainProvider.self
        #expect(!(type is any ImageLooking.Type))
        #expect(!(type is any ImageCaptioning.Type))
    }

    @Test("a look while the home brain is active fails on the device and dials nothing")
    func lookThroughTheFacadeSendsNothing() async {
        let dials = Mutex(0)
        let home = HomeBrainProvider(
            brain: PairedBrain(
                identity: "ID-1", name: "Studio", hosts: ["192.168.1.24"], mainPort: 4243,
                lastKnownHost: nil, addedAt: Date(timeIntervalSince1970: 0)
            ),
            key: Data((0 ..< 32).map { UInt8($0) }),
            transport: { _, _, _, _ in
                dials.withLock { $0 += 1 }
                return AsyncThrowingStream { $0.finish() }
            },
            onBrainUpdate: { _ in }
        )
        let facade = SwappableInferenceProvider(home)
        var thrown: (any Error)?
        do {
            for try await _ in facade.look(image: frame, instructions: "Say what you see.", prompt: "What is this?") {
                Issue.record("a blind brain must not answer")
            }
        } catch {
            thrown = error
        }
        #expect(thrown as? InferenceError == ImageLookingError.cannotLook)
        #expect(dials.withLock { $0 } == 0)
    }
}
