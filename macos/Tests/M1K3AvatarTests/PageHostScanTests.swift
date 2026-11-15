//
//  PageHostScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan pins on the voice-mode page hosts (#839), the VoiceModeFloorTests idiom: the shells
//  have no pure seam for a WKWebView host, so the guard reads the files. The pins are the issue's
//  gates: the iOS host uses the shared non-persistent configuration and the shared navigation guard
//  (`WebURLPolicy.refusesNavigation`), never SFSafariViewController, and no app code opens a page on
//  a model's say-so (`.modelOutput` is only ever named by the policy and its tests).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.7 (coarse tripwires on spelling; the
//  behaviour is pinned in M1K3PreviewTests and verified on device). Prior: none (new file).

import Foundation
import Testing

struct PageHostScanTests {
    private static var root: URL {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Source with comment lines stripped, so headers may describe what is pinned.
    private static func code(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file: \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func swiftFiles(in directory: String) throws -> [String] {
        let url = root.appendingPathComponent(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return names.filter { $0.hasSuffix(".swift") }.map { "\(directory)/\($0)" }
    }

    @Test("the iOS host builds its web view from the shared non-persistent configuration")
    func iosUsesSharedConfiguration() throws {
        let host = try Self.code("M1K3iOSApp/VoicePageWebView.swift")
        #expect(host.contains("WKWebView(frame: .zero, configuration: PrivateWebConfiguration.make())"))
        #expect(!host.contains(".default()"), "a default data store persists cookies")
        #expect(!host.contains("WKWebViewConfiguration()"), "configure through PrivateWebConfiguration only")
    }

    @Test("the iOS host judges every move with the shared WebURLPolicy guard")
    func iosUsesSharedGuard() throws {
        let host = try Self.code("M1K3iOSApp/VoicePageWebView.swift")
        #expect(host.contains("WebNavigationGuard(initialURL: url)"))
        #expect(host.contains("navigationGuard.allows("))
        #expect(host.contains("decidePolicyFor navigationAction"))
    }

    @Test("no iOS shell file reaches for SFSafariViewController or SafariServices")
    func iosNeverSafariViewController() throws {
        for file in try Self.swiftFiles(in: "M1K3iOSApp") {
            let source = try Self.code(file)
            #expect(!source.contains("SFSafariViewController"), "\(file) shares Safari's cookies")
            #expect(!source.contains("import SafariServices"), "\(file) imports SafariServices")
        }
    }

    @Test("the iOS shell makes no other WKWebView than the guarded host")
    func iosNoOtherWebView() throws {
        for file in try Self.swiftFiles(in: "M1K3iOSApp") where file != "M1K3iOSApp/VoicePageWebView.swift" {
            #expect(try !(Self.code(file)).contains("WKWebView("), "\(file) builds an unguarded web view")
        }
    }

    @Test("nothing in the app shells opens a page on model output alone")
    func noShellNamesModelOutput() throws {
        for directory in ["M1K3App", "M1K3iOSApp"] {
            for file in try Self.swiftFiles(in: directory) {
                #expect(try !(Self.code(file)).contains(".modelOutput"), "\(file) opens a page for the model")
            }
        }
    }

    @Test("both shells open a voice page only from a chip tap or a spoken request")
    func openOriginsAreThePerson() throws {
        let macChip = try Self.code("M1K3App/VoiceModeView.swift")
        let iosChip = try Self.code("M1K3iOSApp/VoiceScreen.swift")
        #expect(macChip.contains("origin: .linkChipTap"))
        #expect(iosChip.contains("origin: .linkChipTap"))
        let macSpoken = try Self.code("M1K3App/AppEnvironment+VoicePage.swift")
        let iosSpoken = try Self.code("M1K3iOSApp/AppCore+VoicePage.swift")
        #expect(macSpoken.contains("origin: .spokenRequest"))
        #expect(iosSpoken.contains("origin: .spokenRequest"))
    }

    @Test("the Mac voice page never touches the chat inspector's ReviewModel")
    func macVoicePageLeavesReviewModelAlone() throws {
        for file in ["M1K3App/VoicePagePanel.swift", "M1K3App/AppEnvironment+VoicePage.swift"] {
            let source = try Self.code(file)
            #expect(!source.contains("env.review"), "\(file) reaches the inspector's model")
            #expect(!source.contains("review.open"), "\(file) opens the inspector's target")
            #expect(!source.contains("review.clear"), "\(file) wipes the inspector's target")
        }
        let panel = try Self.code("M1K3App/VoicePagePanel.swift")
        #expect(panel.contains("guard env.voicePage.url == url"), "a stale capture must be judged on the requested url")
        #expect(panel.contains(".keyboardShortcut(.cancelAction)"), "Esc must reach Close after a click into the page")
    }

    @Test("the responder reads the voice page's context slot beside the review panel's")
    func providerReadsVoiceSlot() throws {
        let source = try Self.code("M1K3App/AppEnvironment+ChatHistory.swift")
        #expect(source.contains("ReviewModel.liveContext.withLock { $0 } ?? VoicePageContext.live.withLock { $0 }"))
    }

    @Test("closing the voice page always cancels a pending open, before any early return")
    func closeAlwaysCancels() throws {
        for file in ["M1K3App/AppEnvironment+VoicePage.swift", "M1K3iOSApp/AppCore+VoicePage.swift"] {
            let source = try Self.code(file)
            let range = try #require(source.range(of: "func closeVoicePage() {"), "\(file)")
            let body = source[range.upperBound...].prefix(160)
            #expect(!body.contains("guard"), "\(file): closeVoicePage must not return early")
            #expect(body.contains("voicePage.close()"))
        }
    }

    @Test("the Mac panel keeps the review view's navigation policy and store")
    func macHostIsTheReviewView() throws {
        let panel = try Self.code("M1K3App/VoicePagePanel.swift")
        #expect(panel.contains("WebReviewView(url: url"))
        let review = try Self.code("M1K3App/WebReviewView.swift")
        #expect(review.contains("PrivateWebConfiguration.make()"))
        #expect(review.contains("WebURLPolicy.refusesNavigation"))
    }
}
