//
//  TranscriptFollowPolicyTests.swift
//  M1K3ChatTests
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.85, Prior: none (new file).

@testable import M1K3Chat
import Testing

struct TranscriptFollowPolicyTests {
    private func snap(_ offset: Double, container: Double = 600, content: Double) -> TranscriptScrollSnapshot {
        TranscriptScrollSnapshot(offsetY: offset, containerHeight: container, contentHeight: content)
    }

    @Test("content growing under a still reader never unpins")
    func growthKeepsThePin() {
        let before = snap(400, content: 1000) // at the bottom
        let grown = snap(400, content: 1400) // the reasoning expanded by 400 pt
        #expect(TranscriptFollowPolicy.next(pinned: true, previous: before, current: grown))
    }

    @Test("a scroll up releases the pin; scrolling back near the bottom takes it")
    func scrollUpReleases() {
        let bottom = snap(400, content: 1000)
        let up = snap(200, content: 1000)
        #expect(!TranscriptFollowPolicy.next(pinned: true, previous: bottom, current: up))
        let nearBottom = snap(360, content: 1000) // 40 pt away, inside the 48 pt tolerance
        #expect(TranscriptFollowPolicy.next(pinned: false, previous: up, current: nearBottom))
    }

    @Test("short content is always at the bottom; exactly at the tolerance counts")
    func edges() {
        #expect(snap(0, content: 300).isNearBottom(tolerance: 48), "content shorter than the container")
        #expect(snap(352, content: 1000).isNearBottom(tolerance: 48), "exactly 48 pt away")
        #expect(!snap(351, content: 1000).isNearBottom(tolerance: 48), "49 pt away")
    }

    @Test("without a previous snapshot only the position decides")
    func firstSnapshot() {
        #expect(TranscriptFollowPolicy.next(pinned: false, previous: nil, current: snap(400, content: 1000)))
        #expect(!TranscriptFollowPolicy.next(pinned: false, previous: nil, current: snap(0, content: 1000)))
    }
}
