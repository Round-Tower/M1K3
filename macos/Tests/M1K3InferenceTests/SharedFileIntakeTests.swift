//
//  SharedFileIntakeTests.swift
//  M1K3InferenceTests
//
//  A file shared to M1K3 (AirDrop, Files, Share → Open in) is staged in the composer of a new chat and never
//  sent (1.6, #893 C; Kev 2026-11-22: "I wish I could have shared the JSON file directly to M1K3"). The pure
//  half: what an incoming URL is, when the chat can take it, which copies are ours to delete, and which types
//  M1K3 registers. The shell half is pinned by source scans below (the iPhone has no pure seam for onOpenURL).
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8 (pure decisions + coarse scans; the share sheet,
//  AirDrop and cold launch are verify-on-device). Prior: Unknown.
//

import Foundation
@testable import M1K3Inference
import Testing

struct SharedFileIntakeTests {
    // MARK: - What arrived

    @Test("an m1k3:// link is a deep link, a local file is a file to stage, anything else is ignored")
    func classify() throws {
        let link = try #require(URL(string: "m1k3://event/christmas"))
        #expect(SharedFileIntake.classify(link) == .deepLink)
        let file = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/X/Documents/Inbox/notes.json")
        #expect(SharedFileIntake.classify(file) == .file(file))
        // Every m1k3:// link opens the chat (DeepLink.chat), so an unknown one is still a deep link.
        #expect(try SharedFileIntake.classify(#require(URL(string: "m1k3://nothing-we-know"))) == .deepLink)
        for text in ["https://m1k3.app", "mailto:a@b.c"] {
            let url = try #require(URL(string: text))
            #expect(SharedFileIntake.classify(url) == .ignore, "\(text)")
        }
    }

    // MARK: - When the chat takes it

    @Test("an empty chat takes the file now; a chat with messages starts a new one first")
    func stepByTranscript() {
        #expect(SharedFileIntake.step(isResponding: false, hasMessages: false, consentPending: false) == .stageHere)
        #expect(SharedFileIntake.step(isResponding: false, hasMessages: true, consentPending: false) == .newChatThenStage)
    }

    @Test("while a turn is answering, the file waits: a new chat can't start mid-turn, and it must not join that turn")
    func waitsMidTurn() {
        #expect(SharedFileIntake.step(isResponding: true, hasMessages: true, consentPending: false) == .wait)
        #expect(SharedFileIntake.step(isResponding: true, hasMessages: false, consentPending: false) == .wait)
    }

    @Test("while the Private Cloud consent sheet is open, the file waits: it must not join the send the sheet confirms")
    func waitsBehindConsent() {
        #expect(SharedFileIntake.step(isResponding: false, hasMessages: false, consentPending: true) == .wait)
        #expect(SharedFileIntake.step(isResponding: false, hasMessages: true, consentPending: true) == .wait)
    }

    // MARK: - Copies we may delete

    @Test("iOS's copy in Documents/Inbox is ours to delete once staged; a file anywhere else is not")
    func inboxCopy() {
        let documents = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents")
        #expect(SharedFileIntake.isSystemInboxCopy(documents.appending(path: "Inbox/notes.json"), documents: documents))
        #expect(SharedFileIntake.isSystemInboxCopy(documents.appending(path: "Inbox/sub/a.txt"), documents: documents))
        #expect(!SharedFileIntake.isSystemInboxCopy(documents.appending(path: "notes.json"), documents: documents))
        #expect(!SharedFileIntake.isSystemInboxCopy(documents.appending(path: "Inboxes/notes.json"), documents: documents))
        #expect(!SharedFileIntake.isSystemInboxCopy(URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/notes.json"),
                                                    documents: documents))
        // iOS hands the file over under /private/var while URL.documentsDirectory says /var: the same place.
        let privateVar = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/X/Documents/Inbox/notes.json")
        #expect(SharedFileIntake.isSystemInboxCopy(privateVar, documents: documents))
        // A path that climbs out of the inbox is not in it.
        #expect(!SharedFileIntake.isSystemInboxCopy(documents.appending(path: "Inbox/../notes.json"), documents: documents))
    }

    @Test("after staging, an Inbox item that isn't waiting and is older than the grace is a leftover (a kill mid-onboarding)")
    func inboxLeftovers() {
        let inbox = URL(fileURLWithPath: "/var/mobile/X/Documents/Inbox")
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let old = now.addingTimeInterval(-(SharedFileIntake.leftoverGrace + 1))
        let stale = inbox.appending(path: "old.json")
        let waiting = inbox.appending(path: "waiting.txt")
        let contents = [(url: stale, modified: old), (url: waiting, modified: old)]
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: [waiting], now: now) == [stale])
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: [], now: now) == [stale, waiting])
        // Waiting under /private/var still matches its /var listing.
        let waitingPrivate = URL(fileURLWithPath: "/private/var/mobile/X/Documents/Inbox/waiting.txt")
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: [waitingPrivate], now: now) == [stale])
    }

    @Test("a fresh Inbox copy is never swept: a batch AirDrop copies every file before each one's URL arrives")
    func inboxLeftoversSpareABatchInFlight() {
        let inbox = URL(fileURLWithPath: "/var/mobile/X/Documents/Inbox")
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let b = inbox.appending(path: "b.txt")
        let c = inbox.appending(path: "c.txt")
        let contents = [(url: b, modified: now.addingTimeInterval(-2)), (url: c, modified: now)]
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: [], now: now).isEmpty)
        // An unreadable date is treated as fresh: never delete what can't be aged.
        #expect(SharedFileIntake.inboxLeftovers([(url: b, modified: nil)], waiting: [], now: now).isEmpty)
    }

    // MARK: - What M1K3 registers

    @Test("the registered document types are exactly the ＋ picker's file types, and never PDF (a decision still owed)")
    func registeredTypes() {
        let ids = SharedFileIntake.registeredTypeIdentifiers
        #expect(ids == AttachmentRouting.fileTypes.map(\.identifier))
        #expect(ids.contains("public.json"))
        #expect(!ids.contains("com.adobe.pdf"))
    }
}

/// Source scans for the iPhone shell (RootView / ChatScreen have no pure seam) and the plist in project.yml.
struct SharedFileIntakeScanTests {
    private static func source(_ relative: String) throws -> String {
        // …/macos/Tests/M1K3InferenceTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!text.isEmpty, "scan read an empty file: \(relative) moved")
        return text
    }

    /// Code with comment lines dropped and whitespace collapsed, so a reformat can't pass or fail a pin.
    private static func flat(_ relative: String) throws -> String {
        try source(relative).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The body of the first function whose declaration starts with `signature`, brace-matched.
    private static func body(of signature: String, in code: String) throws -> Substring {
        let start = try #require(code.range(of: signature), "\(signature) moved")
        let open = try #require(code[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" { depth -= 1; if depth == 0 { return code[open ... index] } }
            index = code.index(after: index)
        }
        Issue.record("unbalanced braces after \(signature)")
        return ""
    }

    @Test("the phone stages a shared file through the ＋ picker's own attach, and never sends it")
    func stagesThroughAttachNeverSends() throws {
        let code = try Self.flat("M1K3iOSApp/ChatScreen.swift")
        let receive = try Self.body(of: "private func receiveSharedFiles()", in: code)
        #expect(receive.contains("SharedFileIntake.step("))
        #expect(receive.contains("attach(urls)"), "a shared file must take the same route (and rules) as one picked with ＋")
        for forbidden in ["send(", ".send", "sendTurn", "submit("] {
            #expect(!receive.contains(forbidden), "the intake must never send: found \(forbidden)")
        }
        // The copy is deleted only after it is read, and only if it is iOS's Inbox copy.
        let attach = try #require(receive.range(of: "attach(urls)"))
        let remove = try #require(receive.range(of: "removeItem"))
        #expect(attach.lowerBound < remove.lowerBound, "read the file before deleting the copy")
        #expect(receive.contains("isSystemInboxCopy") && receive.contains("inboxLeftovers"))
        #expect(receive.contains("consentPending: privateCloudPending != nil"), "a file waits behind the consent sheet")
        #expect(receive.contains("|| privateCloudSending"), "and behind a consented send still launching (a new chat would orphan it)")
    }

    @Test("the root catches a shared file before onboarding is done, so cold launch and first run keep it")
    func rootCatchesDuringOnboarding() throws {
        let code = try Self.flat("M1K3iOSApp/RootView.swift")
        // The handler follows the Group's closing braces (the end of the onboarding branch), not a view inside it.
        let handler = try #require(code.range(of: ".onOpenURL"))
        let before = code[..<handler.lowerBound].trimmingCharacters(in: .whitespaces)
        #expect(before.hasSuffix(".transition(.opacity) } }"), "onOpenURL must sit on the root Group, after both branches")
        #expect(code.components(separatedBy: ".onOpenURL").count == 2, "one URL handler at the root")
        #expect(code.contains("SharedFileIntake.classify("))
    }

    @Test("the iPhone plist registers exactly SharedFileIntake's types, as copies (not open in place)")
    func plistMatchesTypes() throws {
        let yml = try Self.source("project.yml")
        let start = try #require(yml.range(of: "CFBundleDocumentTypes:"), "the iOS target registers no document types")
        let block = yml[start.upperBound...]
        let end = try #require(block.range(of: "LSSupportsOpeningDocumentsInPlace: false"),
                               "copies, not in place: the file is staged and the copy deleted")
        let declared = block[..<end.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- public.") }
            .map { String($0.dropFirst(2)) }
        #expect(declared == SharedFileIntake.registeredTypeIdentifiers)
        #expect(yml.components(separatedBy: "CFBundleDocumentTypes:").count == 2, "only the iPhone target registers types (slice 1)")
    }
}
