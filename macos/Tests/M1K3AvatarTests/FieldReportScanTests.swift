//
//  FieldReportScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan tripwires for #708's gate, "nothing is sent without the sheet": the chat chrome
//  raises a sheet and never a mail link; only the sheet's Send button calls the reporter; the
//  reporter builds its link through the unit-pinned `MailtoURL`, scrubs the body, and keeps the
//  clipboard fallback. The views have no pure seam, so this reads the shell files from disk
//  (the ChatChromeScanTests idiom) and matches on strings, not line numbers.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.6 (coarse tripwires over text; the
//  mail-app hand-off is verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — the button parks the note and the sheet is
//  raised from the popover's close; the redactor reads the display name. Confidence 0.6.
//

import Foundation
import Testing

struct FieldReportScanTests {
    private static var root: URL {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Source with comment lines stripped, so headers may explain what is kept out.
    private static func code(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return stripped(src)
    }

    private static func stripped(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every Swift file under the Mac shell, relative to `macos/`.
    private static func shellFiles() throws -> [String] {
        let shell = root.appendingPathComponent("M1K3App")
        let walker = try #require(FileManager.default.enumerator(atPath: shell.path))
        return walker.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { "M1K3App/" + $0 }
            .sorted()
    }

    @Test("the chat chrome raises the sheet and never a mail link")
    func chromeNeverSends() throws {
        let message = try Self.code("M1K3App/MessageView.swift")
        #expect(!message.contains("mailto"))
        #expect(!message.contains("NSWorkspace"))
        #expect(!message.contains("FieldReporter"))
        #expect(message.contains("onSendExchange("), "the thumbs-down editor hands the note up, nothing more")

        let content = try Self.code("M1K3App/ContentView.swift")
        #expect(!content.contains("mailto"))
        #expect(!content.contains("MailtoURL"))
        #expect(!content.contains("FieldReporter.send("))
        #expect(content.contains("FieldReportSheet("), "the sheet is what the chrome raises")
        #expect(content.contains("env.chat.exchange(for:"), "the payload comes from the one-exchange seam")
    }

    @Test("only the sheet's Send button calls the reporter")
    func onlyTheSheetSends() throws {
        let callers = try Self.shellFiles().filter { path in
            let src = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            return Self.stripped(src).contains("FieldReporter.send(")
        }
        #expect(callers == ["M1K3App/FieldReportSheet.swift"])
    }

    @Test("the reporter builds its link through MailtoURL, scrubs the body, and keeps the clipboard fallback")
    func reporterUsesThePureCore() throws {
        let reporter = try Self.code("M1K3App/FieldReporter.swift")
        #expect(reporter.contains("MailtoURL.compose("))
        #expect(!reporter.contains("URL(string: \"mailto"), "a hand-built mailto skips the encoding and the cap")
        #expect(reporter.contains("NSPasteboard"), "an over-long or unopenable link still leaves the text in reach")
        #expect(reporter.contains("DiagnosticRedactor("), "paths, emails and the user's name are scrubbed")
        #expect(reporter.contains("AppEnvironment.userDisplayNameKey"), "the name scrubbed is the display name, not the profile text")
        #expect(!reporter.contains("M1K3Persona.userProfile"), "the About-you text is not a name; it never matched one")
        #expect(reporter.contains("urlForApplication(toOpen:"), "no mail handler is told apart from a link that would not open")
        #expect(reporter.contains("CanaryGuard.fromLocalConfig()"), "the honeypot pass runs on every outward surface")
        #expect(reporter.contains("hello@round-tower.ie"))
    }

    @Test("the thumbs-down editor commits the verdict and note, parks the note, and the sheet follows the popover's close")
    func sendButtonCommitsFirst() throws {
        let message = try Self.code("M1K3App/MessageView.swift")
        let start = try #require(message.range(of: "private var feedbackCommentEditor"), "the editor moved")
        let editor = String(message[start.upperBound...])
        let button = try #require(editor.range(of: "Button(\"Send this exchange…\")"), "the button is named for what it does")
        let action = editor[button.upperBound...]
        let close = try #require(action.range(of: "showComment = false"))
        let before = action[..<close.lowerBound]
        #expect(before.contains("onFeedback(.bad, commentDraft)"), "the bad verdict and note are saved first")
        #expect(before.contains("pendingExchangeNote = commentDraft"), "the note is parked for the sheet")
        #expect(!action[..<close.upperBound].contains("onSendExchange("), "the sheet is not raised inside the button")

        let flush = try #require(message.range(of: ".onChange(of: showComment)"), "the popover's close is watched")
        let afterFlush = message[flush.upperBound...]
        let raise = try #require(afterFlush.range(of: "onSendExchange(note)"))
        #expect(afterFlush[..<raise.lowerBound].contains("pendingExchangeNote = nil"), "the parked note is consumed once")
    }
}
