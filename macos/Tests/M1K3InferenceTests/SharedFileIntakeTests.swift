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
//  Review: Kev + claude-opus-5-5, 2026-11-23 (share to M1K3, slice 2) — ShareExtensionScanTests: the share extension's
//  types are the ＋ picker's, its activation rule matches them, both targets carry the App Group, the app claims drops
//  on activation and stages them through the same never-send path. Confidence 0.8 (scans; the sheet is on-device).
//

import Foundation
@testable import M1K3Inference
import M1K3ShareInbox
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

    @Test("an Inbox item that isn't waiting to be staged is a leftover to sweep (a kill mid-onboarding)")
    func inboxLeftovers() {
        let inbox = URL(fileURLWithPath: "/var/mobile/X/Documents/Inbox")
        let stale = inbox.appending(path: "old.json")
        let waiting = inbox.appending(path: "waiting.txt")
        let contents = [stale, waiting]
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: [waiting]) == [stale])
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: []) == contents)
        // Waiting under /private/var still matches its /var listing.
        let waitingPrivate = URL(fileURLWithPath: "/private/var/mobile/X/Documents/Inbox/waiting.txt")
        #expect(SharedFileIntake.inboxLeftovers(contents, waiting: [waitingPrivate]) == [stale])
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
        #expect(receive.contains("isSystemInboxCopy"))
        // A batch AirDrop copies every file into Inbox before each URL arrives, and a copy keeps its source's dates,
        // so staging one file must never sweep its siblings (#895 second pass): staging deletes only its own copies.
        #expect(!receive.contains("inboxLeftovers"), "the sweep runs when the app leaves the screen, never while staging")
        #expect(receive.contains("consentPending: privateCloudPending != nil"), "a file waits behind the consent sheet")
        #expect(receive.contains("|| privateCloudSending"), "and behind a consented send still launching (a new chat would orphan it)")
    }

    @Test("leftovers are swept when the app goes to the background, sparing every file still waiting to be staged")
    func sweepsOnBackground() throws {
        let code = try Self.flat("M1K3iOSApp/RootView.swift")
        let sweep = try Self.body(of: "private func sweepInboxLeftovers()", in: code)
        #expect(sweep.contains("SharedFileIntake.inboxLeftovers(") && sweep.contains("waiting: sharedFiles"))
        #expect(code.contains("phase == .background"), "by then every URL of a batch has arrived")
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

/// Share to M1K3, slice 2: text, a link or a file from ANY app's share sheet, through the share extension and the App
/// Group inbox (M1K3ShareInbox), staged by the same never-send path as slice 1. The suite (not a trailing helper) owns
/// every test below.
struct ShareExtensionScanTests {
    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!text.isEmpty, "scan read an empty file: \(relative) moved")
        return text
    }

    private static func flat(_ relative: String) throws -> String {
        try source(relative).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

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

    @Test("the share extension takes exactly the ＋ picker's file types")
    func extensionTypesArePickerTypes() {
        #expect(ShareInbox.fileTypeIdentifiers == SharedFileIntake.registeredTypeIdentifiers)
    }

    @Test("the extension's activation rule offers M1K3 for exactly those types and a web link, nothing more")
    func activationRule() throws {
        let yml = try Self.source("project.yml")
        let start = try #require(yml.range(of: "NSExtensionActivationRule:"), "no activation rule on the extension")
        let line = yml[start.upperBound...].prefix { $0 != "\n" }
        let conforms = line.components(separatedBy: "UTI-CONFORMS-TO \"").dropFirst()
            .compactMap { $0.split(separator: "\"").first.map(String.init) }
        #expect(conforms == ShareInbox.fileTypeIdentifiers + ["public.url"])
        #expect(yml.contains("NSExtensionPointIdentifier: com.apple.share-services"))
    }

    @Test("the app and its share extension both carry the App Group the inbox lives in")
    func appGroupOnBoth() throws {
        for path in ["M1K3iOSApp/M1K3iOS.entitlements", "M1K3ShareExtension/M1K3ShareExtension.entitlements"] {
            let plist = try Self.source(path)
            #expect(plist.contains("<key>com.apple.security.application-groups</key>"), "\(path)")
            #expect(plist.contains("<string>\(ShareInbox.appGroup)</string>"), "\(path)")
        }
    }

    @Test("the extension never fetches, never opens the app by a back door, and only drops into the inbox")
    func extensionStaysInItsLane() throws {
        let code = try Self.flat("M1K3ShareExtension/ShareViewController.swift")
        for forbidden in ["URLSession", "openURL", ".open(", "UIApplication", "perform(", "NSSelectorFromString"] {
            #expect(!code.contains(forbidden), "the share extension must not use \(forbidden)")
        }
        #expect(code.contains("ShareInbox.DropWriter("))
        #expect(code.contains("ShareInbox.appGroup"))
        #expect(code.contains("notify_post(ShareInbox.droppedNotification)"))
    }

    @Test("shared text streams to disk and is read only up to the cap: the extension's memory ceiling is tight")
    func extensionCapsTextEarly() throws {
        let code = try Self.flat("M1K3ShareExtension/ShareViewController.swift")
        let text = try Self.body(of: "private static func loadText(", in: code)
        let fileRep = try #require(text.range(of: "loadFileRepresentation("), "text streams to a file first")
        let bounded = try #require(text.range(of: "ShareInbox.readText("), "and is read back only up to the cap")
        #expect(fileRep.lowerBound < bounded.lowerBound)
        // The fallback (a provider with no file form) trims a string the moment it arrives, and refuses big data.
        #expect(text.contains(".prefix(ShareInbox.textCap)"))
        #expect(text.contains("data.count <= ShareInbox.fileByteCap"))
    }

    @Test("the app claims drops at launch, on activation and on the ping, held above onboarding, never deleting them")
    func rootClaims() throws {
        let code = try Self.flat("M1K3iOSApp/RootView.swift")
        let claim = try Self.body(of: "private func claimShares()", in: code)
        #expect(claim.contains("ShareInbox.pending("))
        #expect(claim.contains("ShareInbox.unseen(") && claim.contains("seen: seenDrops"),
                "a second claim never stages a drop twice")
        #expect(claim.contains("sharedDrops.append(contentsOf:"))
        // Claim then kill must lose nothing: the drop stays in the group container until the chat has staged it.
        #expect(!code.contains("ShareInbox.discard"), "the root claims; only the chat, once staged, deletes")
        #expect(code.contains("phase == .active"), "claimed when M1K3 comes forward")
        #expect(code.contains("ShareInbox.droppedNotification"), "and when a drop lands while it is on screen (iPad)")
    }

    @Test("a shared drop joins the composer through the same step as a shared file, is never sent, and goes once staged")
    func chatStagesDrops() throws {
        let code = try Self.flat("M1K3iOSApp/ChatScreen.swift")
        let receive = try Self.body(of: "private func receiveSharedFiles()", in: code)
        #expect(receive.contains("sharedDrops"))
        #expect(receive.contains("ShareInbox.merge(draft: draft"))
        let step = try #require(receive.range(of: "SharedFileIntake.step("))
        let merge = try #require(receive.range(of: "ShareInbox.merge("))
        let attach = try #require(receive.range(of: "attach(urls)"))
        let discard = try #require(receive.range(of: "ShareInbox.discard("), "a staged drop leaves the group container")
        #expect(step.lowerBound < merge.lowerBound, "drops wait out a turn and the consent sheet like files do")
        #expect(merge.lowerBound < discard.lowerBound && attach.lowerBound < discard.lowerBound,
                "deleted only after its words and files are staged")
        for forbidden in ["send(", ".send", "sendTurn", "submit("] {
            #expect(!receive.contains(forbidden), "the intake must never send: found \(forbidden)")
        }
    }
}
