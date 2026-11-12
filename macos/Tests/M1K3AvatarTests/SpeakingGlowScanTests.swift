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

    @Test("every repaint re-seats the halo, and only body parts are shelled (never the fox's lattice)")
    func repaintKeepsTheHalo() throws {
        let src = try Self.app("PhosphorMaterial.swift")
        let apply = try #require(src.range(of: "static func apply("))
        let body = src[apply.upperBound...].prefix(900)
        #expect(body.contains("defer {") && body.contains("setHalo("), "apply no longer re-seats the halo")
        #expect(src.contains("SiteFoxPaint.role(ofPart: $0.id) == .body"))
    }

    @Test("a silent creature wears its own mesh: the shells go on at the first glow and come off at zero")
    func silentCreatureIsUntouched() throws {
        let view = try Self.app("CompanionAvatarView.swift")
        #expect(view.contains("if glow.isOn { PhosphorMaterial.showHalo(halo) }"))
        #expect(view.contains("scene.glowLevel == 0 { PhosphorMaterial.hideHalo(halo) }"))
        let glue = try Self.app("PhosphorMaterial.swift")
        let set = try #require(glue.range(of: "static func setHalo("))
        #expect(glue[set.upperBound...].prefix(160).contains("guard halo.isShown else { return }"))
    }

    @Test("the glow acts on a change only, a reload starts it dark, and it all sits behind the visionOS guard")
    func changeOnlyAndGuarded() throws {
        let src = try Self.app("CompanionAvatarView.swift")
        #expect(src.contains("if glow != scene.lastGlow {"))
        let reload = try #require(src.range(of: "scene.bakedMaterials = PhosphorMaterial.snapshotMaterials(of: host)"))
        let after = src[reload.upperBound...].prefix(700)
        #expect(after.contains("scene.glowTask?.cancel()"))
        #expect(after.contains("scene.lastGlow = .off") && after.contains("scene.glowLevel = 0"))
        let guarded = try #require(src.range(of: "#if !os(visionOS)\n        /// The displayed creature's halo"))
        #expect(!guarded.isEmpty)
    }
}
