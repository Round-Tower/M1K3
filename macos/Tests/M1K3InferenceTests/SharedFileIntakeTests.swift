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
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#893 C, the Mac half) — `admit` (the Mac's held queue: files only,
//  each once) and Mac scans: the M1K3 target registers the same types (Viewer, Alternate), the delegate holds what
//  arrives above the onboarding gate, and ContentView stages through the paperclip's `attach` and never sends. The
//  one-block plist count is now a per-target read. Confidence 0.8 (pure + scans; the shell is verified by launch).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#898 review) — the waiting hint: its reason mirrors `step` over every
//  input, its English (both plural forms) is pinned, and a scan holds both shells to showing it over the composer,
//  announcing it and never sending or wrapping it in glass. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — the bar scan reads the call, not its layout,
//  and pins the hint to a top overlay hung from a zero-height anchor (never a row that grows the bar); the
//  announcement is keyed on the wait reason. Confidence 0.8.
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

    // MARK: - The hint while a file waits

    @Test("why a file waits: voice outranks the consent sheet, which outranks a reply; nothing waiting is nil")
    func waitReason() {
        #expect(SharedFileIntake.waitReason(isResponding: false, inVoice: false, consentPending: false) == nil)
        #expect(SharedFileIntake.waitReason(isResponding: true, inVoice: false, consentPending: false) == .reply)
        #expect(SharedFileIntake.waitReason(isResponding: false, inVoice: false, consentPending: true) == .consent)
        #expect(SharedFileIntake.waitReason(isResponding: true, inVoice: false, consentPending: true) == .consent)
        // A reply inside voice still waits for voice to end (the Mac stages only after voice).
        #expect(SharedFileIntake.waitReason(isResponding: true, inVoice: true, consentPending: false) == .voice)
        #expect(SharedFileIntake.waitReason(isResponding: false, inVoice: true, consentPending: true) == .voice)
    }

    @Test("the hint shows exactly when the step waits: never a hint over a file that stages now, never a silent wait")
    func reasonMirrorsStep() {
        for responding in [false, true] {
            for voice in [false, true] {
                for consent in [false, true] {
                    for messages in [false, true] {
                        // The Mac folds voice into isResponding for `step`; the phone passes inVoice: false.
                        let waits = SharedFileIntake.step(isResponding: responding || voice, hasMessages: messages,
                                                          consentPending: consent) == .wait
                        let reason = SharedFileIntake.waitReason(isResponding: responding, inVoice: voice,
                                                                 consentPending: consent)
                        #expect((reason != nil) == waits, "responding \(responding) voice \(voice) consent \(consent)")
                    }
                }
            }
        }
    }

    @Test("the hint says, in plain words, how many files wait and when they go in the box; none waiting is no hint")
    func waitingHintWording() {
        #expect(SharedFileIntake.waitingHint(count: 1, reason: .reply)
            == "1 file is waiting. It goes in the box when this reply ends.")
        #expect(SharedFileIntake.waitingHint(count: 3, reason: .reply)
            == "3 files are waiting. They go in the box when this reply ends.")
        #expect(SharedFileIntake.waitingHint(count: 1, reason: .voice)
            == "1 file is waiting. It goes in the box when you leave voice.")
        #expect(SharedFileIntake.waitingHint(count: 2, reason: .voice)
            == "2 files are waiting. They go in the box when you leave voice.")
        #expect(SharedFileIntake.waitingHint(count: 1, reason: .consent)
            == "1 file is waiting. It goes in the box when you answer the Private Cloud question.")
        #expect(SharedFileIntake.waitingHint(count: 2, reason: .consent)
            == "2 files are waiting. They go in the box when you answer the Private Cloud question.")
        #expect(SharedFileIntake.waitingHint(count: 0, reason: .reply) == nil)
        #expect(SharedFileIntake.waitingHint(count: 2, reason: nil) == nil)
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

    // MARK: - The Mac's held queue

    @Test("the Mac holds the files that arrived, in order, after those already held; links and web URLs are dropped")
    func admitKeepsFilesInOrder() throws {
        let a = URL(fileURLWithPath: "/Users/x/Desktop/a.json")
        let b = URL(fileURLWithPath: "/Users/x/Desktop/b.txt")
        let c = URL(fileURLWithPath: "/Users/x/c.yaml")
        let web = try #require(URL(string: "https://m1k3.app"))
        let link = try #require(URL(string: "m1k3://event/christmas"))
        #expect(SharedFileIntake.admit([b, web, link, c], holding: [a]) == [a, b, c])
        #expect(SharedFileIntake.admit([web, link], holding: [a]) == [a])
        #expect(SharedFileIntake.admit([], holding: []).isEmpty)
    }

    @Test("a waiting file is held once: a second Open With before it stages, or a path spelled two ways, adds nothing")
    func admitHoldsEachFileOnce() {
        let a = URL(fileURLWithPath: "/Users/x/Desktop/a.json")
        let sameA = URL(fileURLWithPath: "/Users/x/Desktop/sub/../a.json")
        let b = URL(fileURLWithPath: "/Users/x/Desktop/b.txt")
        #expect(SharedFileIntake.admit([a], holding: [a]) == [a])
        #expect(SharedFileIntake.admit([sameA, b, b], holding: [a]) == [a, b])
        #expect(SharedFileIntake.admit([b, a, b], holding: []) == [b, a])
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

/// Source scans for the iPhone shell (RootView / ChatScreen have no pure seam), the Mac shell (the app delegate,
/// SharedFileInbox, ContentView) and both plists in project.yml.
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

    @Test("a shared page also opens beside the chat, read from the file before iOS's copy is deleted")
    func sharedPageOpensBeforeTheCopyGoes() throws {
        let code = try Self.flat("M1K3iOSApp/ChatScreen.swift")
        let receive = try Self.body(of: "private func receiveSharedFiles()", in: code)
        let open = try #require(receive.range(of: "core.openSharedPage("))
        let remove = try #require(receive.range(of: "removeItem"))
        #expect(open.lowerBound < remove.lowerBound, "the page is read from the file, so it must open before the delete")
        let core = try Self.flat("M1K3iOSApp/AppCore+Artifact.swift")
        #expect(core.contains("ArtifactOpenPolicy.sharedPage("), "the shell asks the pure policy which files are pages")
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

    /// One target's section of project.yml's `targets:` map: from `  <name>:` to the next two-space key.
    private static func target(_ name: String, in yml: String) throws -> Substring {
        let targets = try #require(yml.range(of: "\ntargets:\n"), "project.yml has no targets map")
        // From the targets line's own newline: the first target's `\n  <name>:\n` starts there.
        let rest = yml[yml.index(before: targets.upperBound)...]
        let head = try #require(rest.range(of: "\n  \(name):\n"), "no \(name) target")
        let body = rest[head.upperBound...]
        let next = body.firstRange(of: /\n  [A-Za-z][A-Za-z0-9_-]*:\n/)?.lowerBound ?? body.endIndex
        let schemes = body.range(of: "\nschemes:\n")?.lowerBound ?? body.endIndex
        return body[..<min(next, schemes)]
    }

    /// The UTIs a target's document-types block lists, in order.
    private static func documentTypes(in target: Substring) throws -> [String] {
        let start = try #require(target.range(of: "CFBundleDocumentTypes:"), "this target registers no document types")
        var declared: [String] = []
        let lines = target[start.upperBound...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if line.hasPrefix("- public.") {
                declared.append(String(line.dropFirst(2)))
            } else if !declared.isEmpty, !line.hasPrefix("- ") {
                break
            }
        }
        return declared
    }

    @Test("the iPhone plist registers exactly SharedFileIntake's types, as copies (not open in place)")
    func plistMatchesTypes() throws {
        let ios = try Self.target("M1K3iOS", in: Self.source("project.yml"))
        #expect(try Self.documentTypes(in: ios) == SharedFileIntake.registeredTypeIdentifiers)
        #expect(ios.contains("LSSupportsOpeningDocumentsInPlace: false"),
                "copies, not in place: the file is staged and the copy deleted")
        #expect(ios.contains("CFBundleTypeRole: Viewer") && ios.contains("LSHandlerRank: Alternate"))
    }

    // MARK: - The Mac half (Finder Open With, a drop on the Dock icon, `open -a M1K3 file`)

    @Test("the Mac plist registers the same types as a Viewer at Alternate rank: never anyone's default editor")
    func macPlistMatchesTypes() throws {
        let yml = try Self.source("project.yml")
        let mac = try Self.target("M1K3", in: yml)
        #expect(try Self.documentTypes(in: mac) == SharedFileIntake.registeredTypeIdentifiers)
        #expect(mac.contains("CFBundleTypeRole: Viewer"), "M1K3 reads a file; it never edits one")
        #expect(mac.contains("LSHandlerRank: Alternate"), "M1K3 must never become the default app for a type")
        for owner in ["CFBundleTypeRole: Editor", "LSHandlerRank: Owner", "LSHandlerRank: Default"] {
            #expect(!mac.contains(owner), "found \(owner)")
        }
        // Two blocks in the file: the Mac app and the iPhone app (the visionOS shell takes none yet).
        #expect(yml.components(separatedBy: "CFBundleDocumentTypes:").count == 3)
    }

    @Test("the Mac delegate holds what Launch Services hands over above the onboarding gate, and brings M1K3 forward")
    func macDelegateHoldsAndSummons() throws {
        let code = try Self.flat("M1K3App/M1K3App.swift")
        let open = try Self.body(of: "func application(_: NSApplication, open urls: [URL])", in: code)
        #expect(open.contains("if sharedFiles.receive(urls) { NSApp.activate() }"), "only a file brings M1K3 forward")
        for forbidden in ["send(", ".send", "sendTurn", "submit(", "attach("] {
            #expect(!open.contains(forbidden), "the delegate only holds: found \(forbidden)")
        }
        // The delegate owns the inbox (it outlives the window and onboarding), and ContentView reads it.
        #expect(code.contains("let sharedFiles = SharedFileInbox()"))
        #expect(code.contains("ContentView() .environment(env) .environment(appDelegate.sharedFiles)"))
        // A closed window (menu-bar only) is summoned by the always-mounted status-bar label.
        #expect(code.contains(".modifier(SharedFileSummons(inbox: appDelegate.sharedFiles))"))
        let inbox = try Self.flat("M1K3App/SharedFileInbox.swift")
        #expect(inbox.contains("SharedFileIntake.admit("))
        #expect(inbox.contains("openWindow(id: M1K3App.mainWindowID)"))
    }

    @Test("the Mac stages an opened file through the paperclip's attach, waits out a turn or voice, and never sends")
    func macStagesThroughAttachNeverSends() throws {
        let code = try Self.flat("M1K3App/ContentView.swift")
        let receive = try Self.body(of: "private func receiveSharedFiles()", in: code)
        #expect(receive.contains("SharedFileIntake.step("))
        #expect(receive.contains("isResponding: env.chat.isResponding || env.isVoiceModeActive"),
                "a file waits out a turn and a voice session (a new chat under either would orphan it)")
        #expect(receive.contains("consentPending: privateCloudPending != nil || privateCloudSending"))
        #expect(receive.contains("env.chat.startNewConversation()"))
        #expect(receive.contains("attach(urls)"), "an opened file takes the same route (and rules) as the paperclip")
        for forbidden in ["send(", ".send", "sendTurn", "submit(", "ingest("] {
            #expect(!receive.contains(forbidden), "the intake must never send: found \(forbidden)")
        }
        #expect(code.contains(".onChange(of: sharedFiles.files, initial: true)"),
                "a file held through onboarding or a cold launch is staged when the chat first appears")
    }

    // MARK: - The "file waiting" hint (both shells)

    /// Each shell's hint: read from the pure helper with its waiting count, a caption with a symbol, an accessibility
    /// label, an announcement when it first shows, never a send, and never a glass surface that resizes around it.
    @Test("both shells show the waiting hint over the composer, announce it, and never send from it",
          arguments: [
              ("M1K3iOSApp/ChatScreen.swift", "sharedFiles.count", "inputBar"),
              ("M1K3App/ContentView.swift", "sharedFiles.files.count", "bottomChrome"),
          ])
    func waitingHintInBothShells(file: String, count: String, composer: String) throws {
        let code = try Self.flat(file)
        let text = try Self.body(of: "private var sharedFileHintText: String?", in: code)
        #expect(text.contains("SharedFileIntake.waitingHint(count: \(count)"))
        let reason = try Self.body(of: "private var sharedFileWaitReason: SharedFileIntake.WaitReason?", in: code)
        #expect(reason.contains("SharedFileIntake.waitReason("))
        let hint = try Self.body(of: "private func sharedFileHint(_ text: String)", in: code)
        #expect(hint.contains("doc.badge.clock"))
        #expect(hint.contains(".accessibilityLabel(text)"))
        for forbidden in ["send(", ".send", "sendTurn", "submit(", "attach(", "glassEffect", "m1k3Glass"] {
            for (name, part) in [("hint", hint), ("text", text), ("reason", reason)] {
                #expect(!part.contains(forbidden), "the hint only tells: found \(forbidden) in \(name)")
            }
        }
        let bar = try Self.body(of: "private var \(composer): some View", in: code)
        #expect(bar.contains("sharedFileHint(sharedFileHintText)"), "the hint sits over the composer")
        // Hung from the bar's top edge, never a row in it: a row grows the bar (the Mac's safe-area inset) mid-reply
        // and jumps the transcript (#898 follow-up review).
        // The hint hangs from a zero-height anchor on the top edge (an alignmentGuide was not honoured on the Mac).
        let overlay = try #require(bar.range(of: ".overlay(alignment: .top)"), "the hint rides a top overlay")
        let anchor = try #require(bar.range(of: ".frame(height: 0) .overlay(alignment: .bottom)"),
                                  "hung above the bar from a zero-height anchor, not drawn over the bar")
        let call = try #require(bar.range(of: "sharedFileHint(sharedFileHintText)"))
        #expect(overlay.lowerBound < anchor.lowerBound && anchor.lowerBound < call.lowerBound)
        // Announced when it shows and again for each new reason, not once per count.
        #expect(code.contains(".onChange(of: sharedFileWaitReason, initial: true)"))
        #expect(code.contains("AccessibilityNotification.Announcement(sharedFileHintText).post()"))
    }

    @Test("the Mac's waiting hint also shows over voice mode, where the composer hides")
    func macHintOverVoice() throws {
        let code = try Self.flat("M1K3App/ContentView.swift")
        let reason = try Self.body(of: "private var sharedFileWaitReason: SharedFileIntake.WaitReason?", in: code)
        #expect(reason.contains("inVoice: env.isVoiceModeActive"))
        #expect(code.contains("VoiceModeView() .overlay(alignment: .top) { if let sharedFileHintText {"))
    }
}
