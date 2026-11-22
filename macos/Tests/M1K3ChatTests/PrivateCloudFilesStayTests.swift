//
//  PrivateCloudFilesStayTests.swift
//  M1K3ChatTests
//
//  ADR 0010: images and files never ride a Private Cloud Compute turn. Files are not a
//  parameter of the request: the composers prepend their text to the words, so they can
//  arrive inside an earlier turn of the conversation (stripped) or inside the question (the
//  composers build it from the typed words alone, read off source: the shells have no test target).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-22, Confidence 0.8 (the request is tested; the shells
//  are a source scan, so a device try is owed). Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

struct PrivateCloudFilesStayTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let file = FileAttachment(filename: "CANARY-NAME.swift", extractedText: "let secret = \"CANARY-BODY\"")

    @Test("typed words are never rewritten, even shaped like a file block")
    func typedWordsAreVerbatim() {
        let pasted = "FILE: notes\n---\nWhat does this header mean?"
        let consent = PrivateCloudTurn.consent(question: pasted, history: [])
        #expect(consent.question == pasted)
    }

    @Test("a file in an earlier turn never rides 'also send this conversation'")
    func fileInTheConversation() throws {
        let history = [
            ChatTurn(role: .user, text: file.contextBlock + "\n\nTidy this up"),
            ChatTurn(role: .assistant, text: "Done."),
        ]
        let consent = PrivateCloudTurn.consent(question: "And now?", history: history)
        let shown = try #require(consent.conversation)
        let request = PrivateCloudTurn.request(consent, includeConversation: true, now: now)
        #expect(!shown.contains("CANARY"))
        #expect(!request.prompt.contains("CANARY"))
        #expect(shown.contains("Tidy this up"))
    }

    @Test("a line break in a file's name doesn't carry its text past the strip")
    func lineBreakInTheName() throws {
        let odd = FileAttachment(filename: "CANARY\nNAME.txt", extractedText: "CANARY-BODY")
        let history = [ChatTurn(role: .user, text: odd.contextBlock + "\n\nTidy this up")]
        let shown = try #require(PrivateCloudTurn.consent(question: "And now?", history: history).conversation)
        #expect(!shown.contains("CANARY"))
    }

    @Test("both composers: files keep the turn here, and the cloud question is the typed words", arguments: [
        "M1K3App/ContentView.swift", "M1K3iOSApp/ChatScreen.swift",
    ])
    func composersKeepFilesHere(path: String) throws {
        let code = try composerCode(path)
        let guardBody = "!pendingAttachments.isEmpty || !pendingFiles.isEmpty"
        #expect(code.contains(guardBody))

        let gates = arguments(after: "hasAttachments: ", in: code)
        let wrongGates = gates.filter { !$0.hasPrefix("hasStagedAttachments") }
        #expect(!gates.isEmpty)
        #expect(wrongGates == [])

        let questions = arguments(after: "privateCloudConsent(for: ", in: code)
        let wrongQuestions = questions.filter { !$0.hasPrefix("draft)") }
        #expect(questions.count == 2)
        #expect(wrongQuestions == [])

        // A file staged while the sheet was up.
        let sheetGuard = "!hasStagedAttachments"
        #expect(code.contains(sheetGuard))
    }

    /// 2026-11-22, on Kev's phone: "It's not even capturing my message". The question became `draft`
    /// with `clearDraft()` a line above it, so every consented send was empty and vanished. One
    /// function clears now, as on the Mac: after its guards, with the words kept for a refused send.
    @Test("only the cloud sender clears the words: after its guards, and it hands them back")
    func onlyTheSenderClears() throws {
        let code = try composerCode("M1K3iOSApp/ChatScreen.swift")
        let branch = try slice(code, from: "case let .sendDirect(includeConversation) where", to: "case .sendDirect, .local")
        let sheet = try slice(code, from: "onSend: { includeConversation in", to: "onCancel:")
        let clears = "clearDraft()"
        #expect(!branch.contains(clears))
        #expect(!sheet.contains(clears))

        let sender = try slice(code, from: "private func sendToPrivateCloud(", to: "await core.sendPrivateCloud(")
        let sameChat = try #require(sender.range(of: "consent.conversationID == core.chat.activeConversationID")).lowerBound
        let free = try #require(sender.range(of: "!core.chat.isResponding")).lowerBound
        let kept = try #require(sender.range(of: "let words = draft")).lowerBound
        let cleared = try #require(sender.range(of: clears)).lowerBound
        #expect(sameChat < kept)
        #expect(free < kept)
        #expect(kept < cleared)
        let restores = "if !sent, draft.isEmpty { draft = words }"
        #expect(code.contains(restores))
    }

    private func slice(_ code: String, from: String, to: String) throws -> String {
        let start = try #require(code.range(of: from))
        let rest = code[start.upperBound...]
        let end = try #require(rest.range(of: to))
        return String(rest[..<end.lowerBound])
    }

    private func composerCode(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func arguments(after label: String, in code: String) -> [String] {
        code.components(separatedBy: label).dropFirst().map { String($0.prefix(40)) }
    }
}
