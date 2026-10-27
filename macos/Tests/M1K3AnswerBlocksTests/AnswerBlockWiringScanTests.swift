//
//  AnswerBlockWiringScanTests.swift
//  M1K3AnswerBlocksTests
//
//  How the shells wire typed answer blocks (#717), pinned as text: the view bodies are
//  verify-by-launch, and MessageBubble / ChatScreen compile only in CI's mobile job, so a
//  dropped argument would otherwise go unseen. The rules: only the assistant's answer opts
//  into blocks; it says when it is still streaming; a choices card sends only from the
//  newest message while no turn responds (a reloaded or earlier card never sends a stale
//  option); and on the Mac a follow-up send is dropped while a turn responds, as iOS's
//  brainReady gate does.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.6 (text tripwires; the felt
//  behaviour is verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct AnswerBlockWiringScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("each shell opts its answer, and only its answer, into typed blocks, and says when it streams")
    func answerOnlyOptsIn() throws {
        for shell in ["M1K3App/MessageView.swift", "M1K3iOSApp/MessageBubble.swift"] {
            let source = try Self.code(shell)
            let answer = "ReadingText(message.text, answerBlocks: true, streaming: message.status == .streaming)"
            #expect(source.contains(answer), "\(shell): the answer's ReadingText")
            #expect(Self.occurrences(of: "answerBlocks: true", in: source) == 1, "\(shell): one opt-in, the answer")
            #expect(source.contains(".environment(\\.answerChoiceAction, answerChoiceAction)"), "\(shell)")
            #expect(
                source.contains("guard acceptsChoices, case .complete = message.status else { return nil }"),
                "\(shell): the card's gate"
            )
            #expect(source.contains("var acceptsChoices = false"), "\(shell): read-only unless the caller says")
        }
        // The other ReadingText callers render as before.
        let settings = try Self.code("M1K3App/Settings/YouSettingsPane.swift")
        #expect(!settings.contains("answerBlocks"))
        let phoneSettings = try Self.code("M1K3iOSApp/SettingsScreen.swift")
        #expect(!phoneSettings.contains("answerBlocks"))
    }

    @Test("only the newest message, while no turn responds, gets a live choices card")
    func newestMessageOnly() throws {
        let mac = try Self.code("M1K3App/ContentView.swift")
        #expect(mac.contains("acceptsChoices: message.id == env.chat.messages.last?.id && !env.chat.isResponding"))
        let phone = try Self.code("M1K3iOSApp/ChatScreen.swift")
        #expect(phone.contains("acceptsChoices: message.id == core.chat.messages.last?.id && !core.chat.isResponding"))
    }

    @Test("a follow-up send is dropped while a turn responds, before any side effect, on both shells")
    func sendGatedWhileResponding() throws {
        let mac = try Self.code("M1K3App/ContentView.swift")
        let follow = try #require(mac.components(separatedBy: "onSendFollowUp: { text in").dropFirst().first)
        let guardAt = try #require(follow.range(of: "guard !env.chat.isResponding else { return }"))
        let sendAt = try #require(follow.range(of: "await env.send(text)"))
        #expect(guardAt.lowerBound < sendAt.lowerBound)
        let phone = try Self.code("M1K3iOSApp/ChatScreen.swift")
        let question = try #require(phone.components(separatedBy: "onSendFollowUp: { question in").dropFirst().first)
        let readyAt = try #require(question.range(of: "guard brainReady else { return }"))
        let phoneSendAt = try #require(question.range(of: "await core.send(question)"))
        #expect(readyAt.lowerBound < phoneSendAt.lowerBound)
    }
}
