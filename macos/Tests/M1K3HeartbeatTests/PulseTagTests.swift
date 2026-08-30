//
//  PulseTagTests.swift
//  M1K3HeartbeatTests
//
//  Pins the structural-tags ruling (2026-08-30 addendum): a tag describes
//  the SHAPE of a window, never its content. The vocabulary is closed, the
//  composer mints every tag deterministically (the #102 guard extended —
//  the model never sees or produces one), and nothing user-written — no
//  conversation title, memory title, fun-fact source, or exact count — may
//  ever surface in a tag.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.9 (pure function,
//  pinned red-first alongside the implementation). Prior: none (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct PulseTagTests {
    private func makeContext(
        memory: HeartbeatContext.MemoryActivity? = nil,
        chat: HeartbeatContext.ChatActivity? = nil,
        mcp: HeartbeatContext.MCPActivity? = nil,
        brain: HeartbeatContext.BrainStatus? = nil,
        thermal: ThermalBand = .nominal,
        lowPower: Bool = false,
        isCharging: Bool? = nil,
        earlierPulsesToday: [String] = []
    ) -> HeartbeatContext {
        HeartbeatContext(
            date: Date(timeIntervalSince1970: 1_754_480_000),
            device: HeartbeatContext.Device(
                batteryPercent: isCharging == nil ? nil : 60,
                isCharging: isCharging,
                thermal: thermal,
                lowPowerMode: lowPower
            ),
            memory: memory,
            chat: chat,
            mcp: mcp,
            brain: brain,
            earlierPulsesToday: earlierPulsesToday
        )
    }

    @Test("a quiet first pulse tags shape only")
    func quietFirstPulse() {
        let tags = HeartbeatComposer.tags(from: makeContext(), renderedBy: "digest")
        #expect(tags.contains(.firstToday))
        #expect(tags.contains(.quiet))
        #expect(tags.contains(.machineCool))
        #expect(tags.contains(.toldByDigest))
        #expect(!tags.contains(.active))
    }

    @Test("an active later pulse drops first-today and quiet")
    func activeLaterPulse() {
        let tags = HeartbeatComposer.tags(
            from: makeContext(
                memory: .init(newFactTitles: ["Ardmore round tower"], supersededCount: 1),
                chat: .init(touchedConversationTitles: ["The Ballmer Legacy"]),
                earlierPulsesToday: ["Slow start."]
            ),
            renderedBy: "Big"
        )
        #expect(tags.contains(.active))
        #expect(tags.contains(.memoryLearned))
        #expect(tags.contains(.memoryCorrected))
        #expect(tags.contains(.chatTouched))
        #expect(!tags.contains(.firstToday))
        #expect(!tags.contains(.quiet))
        #expect(!tags.contains(.toldByDigest))
    }

    @Test("machine and power bands map to their tags")
    func machineAndPower() {
        let hot = HeartbeatComposer.tags(
            from: makeContext(thermal: .serious, lowPower: true, isCharging: false),
            renderedBy: "digest"
        )
        #expect(hot.contains(.machineHot))
        #expect(hot.contains(.lowPower))
        #expect(hot.contains(.onBattery))
        let warm = HeartbeatComposer.tags(
            from: makeContext(thermal: .fair, isCharging: true), renderedBy: "digest"
        )
        #expect(warm.contains(.machineWarm))
        #expect(warm.contains(.charging))
        // No battery on a desktop — no power tag at all.
        let desktop = HeartbeatComposer.tags(from: makeContext(), renderedBy: "digest")
        #expect(!desktop.contains(.charging))
        #expect(!desktop.contains(.onBattery))
    }

    @Test("an agent visit tags the fact and the client — client identity is not user content")
    func agentTags() {
        let tags = HeartbeatComposer.tags(
            from: makeContext(
                mcp: .init(callCount: 4, topTools: ["search_knowledge"], clientNames: ["Claude Code"])
            ),
            renderedBy: "digest"
        )
        #expect(tags.contains(.agentVisited))
        #expect(tags.contains(PulseTag(rawValue: "agent:claude-code")))
    }

    @Test("the resident brain tags by tier")
    func brainTags() {
        let big = HeartbeatComposer.tags(
            from: makeContext(brain: .init(residentTierName: "Big")), renderedBy: "Big"
        )
        #expect(big.contains(.brainBig))
        let lil = HeartbeatComposer.tags(
            from: makeContext(brain: .init(residentTierName: "Lil")), renderedBy: "digest"
        )
        #expect(lil.contains(.brainLil))
    }

    @Test("no tag ever carries content — titles, tool names, and exact counts stay out")
    func noContentInTags() {
        let tags = HeartbeatComposer.tags(
            from: makeContext(
                memory: .init(
                    newFactTitles: ["Kev prefers Barry's tea", "A second private thing"],
                    supersededCount: 17
                ),
                chat: .init(touchedConversationTitles: ["Authentic Irish coffee in Cork"]),
                mcp: .init(callCount: 23, topTools: ["search_knowledge"], clientNames: ["Claude"])
            ),
            renderedBy: "Big"
        )
        let joined = tags.map(\.rawValue).joined(separator: " ")
        #expect(!joined.lowercased().contains("barry"))
        #expect(!joined.lowercased().contains("cork"))
        #expect(!joined.contains("17"))
        #expect(!joined.contains("23"))
        #expect(!joined.contains("search_knowledge"))
    }

    @Test("client tags normalise: lowercase, spaces to dashes, nothing but word characters")
    func clientTagNormalises() {
        #expect(PulseTag.agentClient("Claude Code").rawValue == "agent:claude-code")
        #expect(PulseTag.agentClient("Cursor").rawValue == "agent:cursor")
        #expect(PulseTag.agentClient("Weird//Name!!").rawValue == "agent:weirdname")
    }

    @Test("tags are deterministic — same context, same set")
    func deterministic() {
        let context = makeContext(
            memory: .init(newFactTitles: ["A"], supersededCount: 0),
            thermal: .fair, isCharging: true
        )
        #expect(
            HeartbeatComposer.tags(from: context, renderedBy: "Big")
                == HeartbeatComposer.tags(from: context, renderedBy: "Big")
        )
    }

    @Test("every tag renders a short human label for the filter chips")
    func displayLabels() {
        #expect(PulseTag.agentVisited.displayLabel == "Agent visit")
        #expect(PulseTag.machineHot.displayLabel == "Ran hot")
        #expect(PulseTag.memoryLearned.displayLabel == "Learned")
        #expect(PulseTag.agentClient("Claude Code").displayLabel == "Claude Code")
        #expect(PulseTag(rawValue: "unknown:future").displayLabel == "future")
    }
}
