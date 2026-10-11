//
//  SettingsPaneLayoutTests.swift
//  M1K3AvatarTests
//
//  A source-scan pin on the 1.1 Settings restructure (Kev, TestFlight, 2026-10-11): the MCP
//  server and Brain at Home are top-level panes; model auditions and weight import left
//  Settings. The panes are SwiftUI bodies with no pure seam, so the guard reads the shell
//  files from disk (the VoiceModeFloorTests idiom) and fails if a section drifts back.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.7 (a coarse tripwire over text;
//  the layout itself is verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct SettingsPaneLayoutTests {
    private static var root: URL {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The file's code with whole-line comments stripped (a header may name what left).
    private static func code(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("the pane list is M1K3, You, Privacy, Brain at Home, MCP Server, General, Advanced — in that order")
    func paneOrder() throws {
        let code = try Self.code("M1K3App/SettingsView.swift")
        #expect(code.contains("case m1k3, you, privacy, brainAtHome, mcp, general, advanced"))
        #expect(code.contains("case .brainAtHome: \"Brain at Home\""))
        #expect(code.contains("case .mcp: \"MCP Server\""))
        #expect(code.contains("case .brainAtHome: BrainAtHomeSettingsPane()"))
        #expect(code.contains("case .mcp: MCPServerSettingsPane()"))
    }

    @Test("Advanced no longer mounts auditions, weight import or the agent log")
    func advancedLostAuditionsAndImport() throws {
        let code = try Self.code("M1K3App/Settings/AdvancedSettingsPane.swift")
        #expect(code.contains("struct AdvancedSettingsPane"), "scan is not reading the Advanced pane")
        for gone in ["ModelAuditionSection", "weightImportSection", "weightImportState",
                     "Import weights", "NSOpenPanel", "conversationLogSection"]
        {
            #expect(!code.contains(gone), "Advanced mounts \(gone) again")
        }
    }

    @Test("Privacy no longer holds the MCP server or Brain at Home")
    func privacyLostMCPAndBrainAtHome() throws {
        let code = try Self.code("M1K3App/Settings/PrivacySettingsPane.swift")
        #expect(code.contains("contentControlsSection"), "scan is not reading the Privacy pane")
        for gone in ["mcpSection", "BrainAtHomeSection()", "accessTokenRow", "connectAnAgent"] {
            #expect(!code.contains(gone), "Privacy holds \(gone) again")
        }
    }

    @Test("the new panes own what moved")
    func newPanesOwnTheirSections() throws {
        let mcp = try Self.code("M1K3App/Settings/MCPServerSettingsPane.swift")
        #expect(mcp.contains("accessTokenRow") && mcp.contains("connectAnAgent"))
        #expect(mcp.contains("Log agent conversations"), "the agent log opt-in rides with the MCP server")
        let home = try Self.code("M1K3App/Settings/BrainAtHomeSettingsPane.swift")
        #expect(home.contains("BrainAtHomeSection()"))
    }

    @Test("the audition and weight-import UI is gone; the brain-building seams stay")
    func removedFilesStayRemoved() throws {
        for gone in ["M1K3App/Settings/ModelAuditionSection.swift", "M1K3App/AppEnvironment+WeightImport.swift"] {
            #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(gone).path), "\(gone) is back")
        }
        let auditions = try Self.code("M1K3App/AppEnvironment+Auditions.swift")
        #expect(auditions.contains("func makeMLXBrain") && auditions.contains("func evalMLXBrain"))
        #expect(!auditions.contains("func setAudition") && !auditions.contains("func importAudition"))
    }
}
