//
//  SpeakingGlowScanTests.swift
//  M1K3AvatarTests
//
//  The app shell has no unit-test target, so the speaking glow's wiring is pinned by
//  reading the source: what must not regress is the cost model (no per-frame clock)
//  and the debug switch staying out of Release.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8. Prior: Unknown.
//

import Foundation
import Testing

struct SpeakingGlowScanTests {
    private static func app(_ file: String) throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("M1K3App/\(file)"), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file: \(file) moved")
        return src
    }

    @Test("the view resolves the glow through SpeakingGlow, with the switch, Reduce Motion and pause")
    func resolvesThroughThePolicy() throws {
        let src = try Self.app("CompanionAvatarView.swift")
        #expect(src.contains("SpeakingGlow.resolve("))
        #expect(src.contains("enabled: speakingGlow, reduceMotion: reduceMotion, paused: paused"))
        #expect(src.contains("@AppStorage(CompanionDefaults.speakingGlowKey)"))
    }

    @Test("the glow adds no per-frame clock to the creature view: the pulse lives in the shader")
    func noPerFrameClock() throws {
        let src = try Self.app("CompanionAvatarView.swift")
        for clock in ["TimelineView", "CADisplayLink", "SceneEvents.Update"] {
            #expect(!src.contains(clock + "("), "\(clock) in the creature view")
        }
        let metal = try Self.app("Phosphor.metal")
        #expect(metal.contains("void haloSurface("))
        #expect(metal.contains("void haloGeometry("))
        #expect(metal.contains("uniforms().time()"))
    }

    @Test("the always-glow switch is a Debug aid: false in a Release build")
    func alwaysGlowIsDebugOnly() throws {
        let src = try Self.app("CompanionAvatarView.swift")
        let range = try #require(src.range(of: "private static let glowAlways: Bool = {"))
        let body = src[range.upperBound...].prefix(260)
        #expect(body.contains("#if DEBUG"))
        #expect(body.contains("#else") && body.contains("false"))
    }

    @Test("every repaint re-seats the halo, and a shell part can never read as the fox's lattice body")
    func repaintKeepsTheHalo() throws {
        let src = try Self.app("PhosphorMaterial.swift")
        #expect(src.contains("defer {\n            if let halo {"))
        #expect(src.contains("SiteFoxPaint.role(ofPart: $0.id) == .body"))
    }
}
