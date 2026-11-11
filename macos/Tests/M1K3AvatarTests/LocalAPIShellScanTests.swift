//
//  LocalAPIShellScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan pins on the Mac app's Local API glue, which has no pure seam of
//  its own: the test key exists only in Debug, the surface never loads or swaps
//  a brain, it uses its own Keychain account, and a local turn preempts it
//  everywhere it preempts Brain at Home.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.6 (coarse tripwires
//  on spelling; the behaviour is verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct LocalAPIShellScanTests {
    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the test key is compiled into Debug builds only")
    func theTestKeyIsDebugOnly() throws {
        let controller = try Self.source("M1K3App/LocalAPIController.swift")
        let key = try #require(controller.range(of: "M1K3_LOCAL_API_TEST_KEY\"]"))
        let before = controller[..<key.lowerBound]
        let opened = try #require(before.range(of: "#if DEBUG", options: .backwards))
        #expect(!before[opened.upperBound...].contains("#endif"), "the test key must sit inside #if DEBUG")
        #expect(controller.components(separatedBy: "M1K3_LOCAL_API_TEST_KEY\"]").count == 2)
    }

    @Test("the Local API has its own key, serves only the ready brain, and reads no persona path")
    func ownKeyAndNoSwap() throws {
        let controller = try Self.source("M1K3App/LocalAPIController.swift")
        #expect(controller.contains("static let accessTokenAccount = \"localapi.access-token\""))
        #expect(!controller.contains("mcp.loopback-access-token"))
        #expect(controller.contains("env.isReady ? [LocalAPIModel.id(forTier: env.selectedBrain.rawValue)] : []"))
        for banned in ["selectBrain(", "switchBrain(", "generateStreaming(", "askBrain(", "chat.send("] {
            #expect(!controller.contains(banned), "the Local API glue reaches for \(banned)")
        }
        #expect(controller.contains("env.provider as? RawChatCompleting"))
    }

    @Test("a local turn preempts a Local API call wherever it preempts Brain at Home")
    func preemptedBesideBrainAtHome() throws {
        for file in ["AppEnvironment.swift", "AppEnvironment+Intelligence.swift", "AppEnvironment+PrivateCloud.swift"] {
            let text = try Self.source("M1K3App/\(file)")
            let home = text.components(separatedBy: "brainServe?.preemptForLocalTurn()").count - 1
            let api = text.components(separatedBy: "localAPI?.preemptForLocalTurn()").count - 1
            #expect(home > 0 && api == home, "\(file): \(home) Brain at Home preempts, \(api) Local API")
        }
    }
}
