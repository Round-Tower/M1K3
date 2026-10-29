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

//  Review: Kev + claude-opus-5.5, 2026-10-26 (code-review fold) — the send pin matches its name (one call,
//  inside the Send button, no lifecycle hook in the sheet; no other shell file builds a mail link); the
//  button is gated on the age band; the reporter hands its scrub and its send to the pure seams
//  (`redactedBody`, `MailHandoff`), which are unit-tested where they live. Confidence 0.6.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (bot review fold) — the offer is wired only for an answer M1K3 wrote
//  (`message.isExchangeAnswer`: no script output, no PCC notice); Send never closes the sheet, because "opened"
//  is only Launch Services accepting the link; a blank editor can be neither copied nor sent. Confidence 0.6.
//  Review: Kev + claude-opus-5.5, 2026-10-29 — Return sends once: the sheet stays open after Send, so a second
//  Return opened a second email (#708's 1.3.0 fix). Confidence 0.6.
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — the reporter reads the one address every
//  report uses, `RoundTowerReports.recipient`. Confidence 0.6.
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
        #expect(message.contains("onSendExchange?("), "the thumbs-down editor hands the note up, nothing more")

        let content = try Self.code("M1K3App/ContentView.swift")
        #expect(!content.contains("mailto"))
        #expect(!content.contains("MailtoURL"))
        #expect(!content.contains("FieldReporter.send("))
        #expect(content.contains("FieldReportSheet("), "the sheet is what the chrome raises")
        #expect(content.contains("env.chat.exchange(for:"), "the payload comes from the one-exchange seam")
    }

    @Test("only the sheet's Send button calls the reporter, once, and only the reporter builds a mail link")
    func onlyTheSheetSends() throws {
        let callers = try Self.shellFiles().filter { path in
            let src = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            return Self.stripped(src).contains("FieldReporter.send(")
        }
        #expect(callers == ["M1K3App/FieldReportSheet.swift"])

        let sheet = try Self.code("M1K3App/FieldReportSheet.swift")
        #expect(sheet.components(separatedBy: "FieldReporter.send(").count == 2, "exactly one call")
        let sendButton = try #require(sheet.range(of: "Button(\"Send by email\")"), "the Send button moved")
        let call = try #require(sheet.range(of: "FieldReporter.send("))
        #expect(call.lowerBound > sendButton.upperBound, "the call sits inside the Send button")
        if let nextButton = sheet[sendButton.upperBound...].range(of: "Button(") {
            #expect(call.lowerBound < nextButton.lowerBound, "and not in a later button")
        }
        for hook in [".onAppear", ".task", ".onChange"] {
            #expect(!sheet.contains(hook), "the sheet has no \(hook): nothing runs without a press")
        }

        // One place builds a mail link or hands one to the OS.
        let linkBuilders = try Self.shellFiles().filter { path in
            let src = try Self.code(path)
            return ["mailto", "MailtoURL", "MailHandoff"].contains { src.contains($0) }
        }
        #expect(linkBuilders == ["M1K3App/FieldReporter.swift"])
    }

    @Test("the offer is withheld from the age bands the web tools are withheld from, and from display-only text")
    func offerIsGatedOnTheAgeBand() throws {
        let content = try Self.code("M1K3App/ContentView.swift")
        #expect(content.contains("AgeAppropriateness.fieldReportAllowed(for:"), "the shell asks the policy")
        // Whitespace-collapsed, so the formatter may wrap the ternary.
        let flat = content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let wiring = "onSendExchange: fieldReportAllowed && message.isExchangeAnswer ?"
        #expect(
            flat.contains(wiring + " sendExchange(for: message.id) : nil"),
            "no offer is wired when the band says no, or for a script's output or a PCC notice"
        )
        let message = try Self.code("M1K3App/MessageView.swift")
        let gate = try #require(message.range(of: "if onSendExchange != nil {"), "the button only exists when wired")
        let button = try #require(message.range(of: "Button(\"Send this exchange…\")"))
        #expect(gate.upperBound < button.lowerBound)
        #expect(message.contains("var onSendExchange: ((String?) -> Void)?"), "unwired means hidden: nil by default")
    }

    @Test("Send never closes the sheet, and a blank editor can be neither copied nor sent")
    func sendKeepsTheTextOnScreen() throws {
        let sheet = try Self.code("M1K3App/FieldReportSheet.swift")
        let send = try #require(sheet.range(of: "Button(\"Send by email\")"), "the Send button moved")
        let afterSend = sheet[send.upperBound...]
        // `.opened` is Launch Services accepting the link, not a compose window appearing (a Mail
        // with no account opens its setup): the edited text stays on screen until the user's Done.
        #expect(afterSend.contains("case .opened:"))
        #expect(!afterSend.contains("onDone"), "no outcome of Send closes the sheet")
        for label in ["Button(\"Copy instead\")", "Button(\"Send by email\")"] {
            let button = try #require(sheet.range(of: label), "\(label) moved")
            let rest = sheet[button.upperBound...]
            let next = rest.range(of: "Button(")?.lowerBound ?? rest.endIndex
            #expect(rest[..<next].contains(".disabled(isBlank)"), "\(label) is off while the editor is blank")
        }
        #expect(sheet.contains("text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"), "blank means trimmed")
    }

    @Test("the reporter builds its link through MailtoURL, scrubs the body, and keeps the clipboard fallback")
    func reporterUsesThePureCore() throws {
        let reporter = try Self.code("M1K3App/FieldReporter.swift")
        #expect(reporter.contains("MailtoURL.compose("))
        #expect(!reporter.contains("URL(string: \"mailto"), "a hand-built mailto skips the encoding and the cap")
        #expect(reporter.contains("MailHandoff.send("), "the outcome and the clipboard rule are the unit-tested ones")
        #expect(reporter.contains("NSPasteboard"), "an over-long or unopenable link still leaves the text in reach")
        #expect(reporter.contains("FieldReportFormatter.redactedBody("), "the scrub is the unit-tested pipeline")
        #expect(!reporter.contains("FieldReportFormatter.body("), "no unscrubbed body reaches the sheet")
        #expect(reporter.contains("AppEnvironment.userDisplayNameKey"), "the name scrubbed is the display name, not the profile text")
        #expect(!reporter.contains("M1K3Persona.userProfile"), "the About-you text is not a name; it never matched one")
        #expect(reporter.contains("urlForApplication(toOpen:"), "no mail handler is told apart from a link that would not open")
        #expect(reporter.contains("CanaryGuard.fromLocalConfig()"), "the honeypot pass runs on every outward surface")
        #expect(reporter.contains("RoundTowerReports.recipient"), "one address for every report (SnagReportTests pins it)")
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
        #expect(!action[..<close.upperBound].contains("onSendExchange?("), "the sheet is not raised inside the button")

        let flush = try #require(message.range(of: ".onChange(of: showComment)"), "the popover's close is watched")
        let afterFlush = message[flush.upperBound...]
        let raise = try #require(afterFlush.range(of: "onSendExchange?(note)"))
        #expect(afterFlush[..<raise.lowerBound].contains("pendingExchangeNote = nil"), "the parked note is consumed once")
    }

    @Test("after a send, Return no longer sends the message again")
    func returnSendsOnce() throws {
        let sheet = try Self.code("M1K3App/FieldReportSheet.swift")
        let conditional = ".keyboardShortcut(sent ? nil : .defaultAction)"
        #expect(sheet.contains(conditional), "Send gives up Return once it has sent")
        #expect(!sheet.contains(".keyboardShortcut(.defaultAction)"), "no unconditional Return on Send")
        let sendButton = try #require(sheet.range(of: "Button(\"Send by email\")"))
        let call = try #require(sheet.range(of: "FieldReporter.send("))
        let beforeCall = sheet[sendButton.upperBound ..< call.lowerBound]
        #expect(beforeCall.contains("sent = true"), "the flag is set before the hand-off")
    }
}
