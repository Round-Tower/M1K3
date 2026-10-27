//
//  CoolHeadNoteCallSiteTests.swift
//  M1K3ChatTests
//
//  Cool Head's line (#697) is posted once per send and taken once, by the chat turn that send
//  starts. The app shell compiles only under xcodebuild, so its wiring is pinned by reading the
//  source (the AskSurfaceCallSiteTests idiom). Two facts matter. Every send posts, so a line
//  nobody read never carries to a later turn. And only the interactive chat responder takes it:
//  the MCP, Ask-intent, menu-bar and deep-dive responders are built by the same factory, and one
//  of them reading the slot first would eat the chat turn's line.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (a text scan: a rename of the anchors
//  must update them here, and each anchor is asserted to exist first). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #697 pre-push review fold: `send` itself is pinned to fold Cool Head
//  before its chat turn starts. Without that order the turn reads an empty slot. Confidence 0.85.
//

import Foundation
import Testing

struct CoolHeadNoteCallSiteTests {
    private static func source(_ relative: String) throws -> String {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        let text = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
        // Code lines only, so a doc comment naming a call can't satisfy or break a scan.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `head` to the first line that closes it at `indent` (a member or a call).
    private static func block(from head: String, closing: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: head), "anchor missing: \(head)")
        let end = try #require(text[start.upperBound...].range(of: closing), "no close for \(head)")
        return text[start.lowerBound ..< end.upperBound]
    }

    @Test("every send posts to the slot, announced or not, so a line never carries to a later turn")
    func everySendPosts() throws {
        let history = try Self.source("M1K3App/AppEnvironment+ChatHistory.swift")
        let apply = try Self.block(from: "func applyCoolHead() {", closing: "\n    }\n", in: history)
        #expect(apply.contains("Self.coolHeadStep(from: state)"))
        // At the body's own indent: directly in applyCoolHead, never inside an `if`.
        #expect(apply.contains(
            "\n        Self.coolHeadNote.withLock { $0.post(step.announcement, deviceNoun: HostPlatform.noun) }\n"
        ), "the post must run on every send, unconditionally")
    }

    @Test("a send folds Cool Head before its chat turn starts, so that turn reads the send's own line")
    func sendFoldsBeforeTheTurn() throws {
        let env = try Self.source("M1K3App/AppEnvironment.swift")
        let send = try Self.block(
            from: "func send(_ text: String, images: [ImageAttachment] = []) async {", closing: "\n    }\n", in: env
        )
        // At the body's own indent: every send folds, never only inside an `if`.
        let fold = try #require(send.range(of: "\n        applyCoolHead()\n"), "send never folds Cool Head")
        let turn = try #require(send.range(of: "await chat.send(text, images: images)"), "anchor missing: the turn")
        #expect(fold.upperBound <= turn.lowerBound, "a fold after the turn leaves the turn an empty slot")
        #expect(send.components(separatedBy: "applyCoolHead()").count - 1 == 1)
    }

    @Test("the fold reads the live readings; the forced reading exists only in Debug builds")
    func forcedReadingIsDebugOnly() throws {
        let history = try Self.source("M1K3App/AppEnvironment+ChatHistory.swift")
        let fold = try Self.block(
            from: "static func coolHeadStep(from state: CoolHeadState) -> CoolHeadStep {", closing: "\n    }\n",
            in: history
        )
        #expect(fold.contains("CoolHeadPolicy.advance("))
        #expect(fold.contains("thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled"))
        let debug = try #require(fold.range(of: "#if DEBUG"))
        let force = try #require(fold.range(of: "\"coolHeadForce\""))
        let endif = try #require(fold.range(of: "#endif"))
        #expect(debug.upperBound < force.lowerBound && force.upperBound < endif.lowerBound)
        #expect(history.components(separatedBy: "\"coolHeadForce\"").count - 1 == 1)
    }

    @Test("the factory threads the note provider through; only the interactive chat responder passes one")
    func onlyTheChatResponderTakesTheNote() throws {
        let history = try Self.source("M1K3App/AppEnvironment+ChatHistory.swift")
        let factory = try Self.block(
            from: "static func makeAgentResponder(", closing: "\n    }\n", in: history
        )
        #expect(factory.contains("turnNoteProvider: (@Sendable () -> String?)? = nil"))
        #expect(factory.contains("turnNoteProvider: turnNoteProvider,"))

        let env = try Self.source("M1K3App/AppEnvironment.swift")
        #expect(env.components(separatedBy: "turnNoteProvider:").count - 1 == 1, "one responder takes the note")
        let chat = try Self.block(from: "responder = Self.makeAgentResponder(", closing: "\n        )\n", in: env)
        #expect(chat.contains("turnNoteProvider: { Self.coolHeadNote.withLock { $0.take() } }"))
        for lazy in ["lazy var intelligenceResponder", "lazy var mcpResponder"] {
            let decl = try Self.block(from: lazy, closing: "\n        )\n", in: env)
            #expect(!decl.contains("turnNoteProvider"), "\(lazy) would eat the chat turn's line")
        }
        for other in ["M1K3App/MenuBarAsk.swift", "M1K3App/AppEnvironment+DeepDelegation.swift"] {
            #expect(try !Self.source(other).contains("turnNoteProvider"), "\(other) would eat the chat turn's line")
        }
    }

    @Test("the answer bubble shows the note as a caption, apart from the text it speaks and copies")
    func bubbleShowsTheNote() throws {
        let view = try Self.source("M1K3App/MessageView.swift")
        let body = try Self.block(from: "private var assistantBody: some View {", closing: "\n    }\n", in: view)
        let note = try #require(body.range(of: "if let note = message.turnNote"), "the bubble never shows the note")
        let text = try #require(body.range(of: "ReadingText(message.text)"))
        #expect(note.lowerBound < text.lowerBound, "the note sits above the answer")
        #expect(!view.contains("onSpeak(message.turnNote"))
    }
}
