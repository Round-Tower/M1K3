//
//  WindowFieldTests.swift
//  M1K3AvatarTests
//
//  A source-scan pin (the VoiceModeFloorTests idiom) on the phone shells' floor:
//  iOS sits on the window's own field, visionOS keeps the deep gradient — the
//  challenger's NO-GO on `Color.clear` there (a RealityView hero over the system
//  glass pane is unverified on device, and a bright creature loses its contrast).
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.6 (a coarse tripwire;
//  the visionOS look is verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct WindowFieldTests {
    private static func code() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("M1K3iOSApp/WindowField.swift"), encoding: .utf8)
        #expect(src.contains("struct WindowField"), "scan is not reading the window field")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("iOS sits on the window's own field; visionOS keeps its gradient, and only there")
    func iosFieldAndVisionOSGradient() throws {
        let code = try Self.code()
        #expect(code.contains("Rectangle().fill(.background)"), "iOS must sit on the window field")
        #expect(code.contains("#if os(visionOS)"), "the visionOS arm is gone")
        #expect(!code.contains("Color.clear"), "visionOS must not paint nothing (challenger NO-GO)")
        // The gradient lives in the visionOS arm only.
        let arms = code.components(separatedBy: "#if os(visionOS)")
        #expect(arms.count == 2, "exactly one visionOS arm")
        let visionArm = arms[1].components(separatedBy: "#else")[0]
        let elseArm = arms[1].components(separatedBy: "#else")[1]
        #expect(visionArm.contains("LinearGradient("), "visionOS keeps the deep gradient")
        #expect(!elseArm.contains("LinearGradient(") && !elseArm.contains("Color(red:"), "iOS paints no private floor")
    }
}
