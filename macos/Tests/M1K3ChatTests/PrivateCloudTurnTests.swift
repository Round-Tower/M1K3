//
//  PrivateCloudTurnTests.swift
//  M1K3ChatTests
//
//  What leaves on a Private Cloud Compute turn, pinned (ADR 0006). The request
//  is an ALLOWLIST: the PCC persona, the question, and — only when the user
//  ticks it — the exact conversation text the consent sheet showed them. The
//  builder has no parameter for memories, documents, todos, the page open
//  beside the chat, tool results or the profile, so none of them can ride.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

struct PrivateCloudTurnTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private let history: [ChatTurn] = [
        ChatTurn(role: .user, text: "My sister is called CANARY-SISTER-11."),
        ChatTurn(role: .assistant, text: "Noted — say hi to CANARY-SISTER-11 from me."),
    ]

    @Test("nothing ticked: the prompt IS the question, byte for byte")
    func questionOnly() {
        let consent = PrivateCloudTurn.consent(question: "Explain entropy simply.", history: history)
        let request = PrivateCloudTurn.request(consent, includeConversation: false, now: now)
        #expect(request.prompt == "Explain entropy simply.")
        #expect(!request.prompt.contains("CANARY"))
        #expect(!request.instructions.contains("CANARY"))
    }

    @Test("the instructions are the PCC persona, never the local one")
    func pccPersona() {
        let consent = PrivateCloudTurn.consent(question: "hi", history: [])
        let request = PrivateCloudTurn.request(consent, includeConversation: false, now: now)
        #expect(request.instructions == M1K3Persona.privateCloudPrompt(now: now))
    }

    @Test("ticked: the conversation goes exactly as the sheet showed it")
    func conversationWhenTicked() throws {
        let consent = PrivateCloudTurn.consent(question: "What should I get her?", history: history)
        let shown = try #require(consent.conversation)
        let request = PrivateCloudTurn.request(consent, includeConversation: true, now: now)
        #expect(request.prompt.contains(shown))
        #expect(request.prompt.hasSuffix("What should I get her?"))
        #expect(shown.contains("CANARY-SISTER-11"))
    }

    @Test("no earlier turns: there's no conversation to offer")
    func noConversationOffered() {
        let consent = PrivateCloudTurn.consent(question: "hi", history: [])
        #expect(consent.conversation == nil)
        // Ticking a box that isn't there changes nothing.
        let request = PrivateCloudTurn.request(consent, includeConversation: true, now: now)
        #expect(request.prompt == "hi")
    }

    @Test("the shown conversation labels who said what")
    func conversationLabels() throws {
        let shown = try #require(PrivateCloudTurn.consent(question: "q", history: history).conversation)
        #expect(shown.hasPrefix("You: My sister"))
        #expect(shown.contains("\nM1K3: Noted"))
    }

    @Test("a long conversation keeps the most recent turns and says it was cut")
    func conversationCap() throws {
        let long = (0 ..< 200).map { index in
            ChatTurn(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "turn \(index) " + String(repeating: "x", count: 200)
            )
        }
        let shown = try #require(PrivateCloudTurn.consent(question: "q", history: long).conversation)
        #expect(shown.count <= PrivateCloudTurn.conversationCharacterCap)
        #expect(shown.contains("turn 199 "))
        #expect(!shown.contains("turn 0 "))
        #expect(shown.hasPrefix(PrivateCloudTurn.earlierTurnsOmitted))
    }

    @Test("one turn longer than the whole cap keeps its tail, within the cap")
    func oversizedSingleTurn() throws {
        let giant = [ChatTurn(role: .user, text: "START " + String(repeating: "y", count: 30000) + " END")]
        let shown = try #require(PrivateCloudTurn.consent(question: "q", history: giant).conversation)
        #expect(shown.count <= PrivateCloudTurn.conversationCharacterCap)
        #expect(shown.hasSuffix(" END"))
        #expect(!shown.contains("START"))
    }

    @Test("a conversation under the cap is shown whole, with no omission marker")
    func underTheCapIsWhole() throws {
        let shown = try #require(PrivateCloudTurn.consent(question: "q", history: history).conversation)
        #expect(!shown.contains(PrivateCloudTurn.earlierTurnsOmitted))
    }

    @Test("the sheet's sentence says what leaves and where; the guarantee is Apple's, with its source")
    func copy() {
        #expect(PrivateCloudTurn.summary.contains("Private Cloud Compute"))
        #expect(PrivateCloudTurn.summary.contains("Nothing else"))
        #expect(PrivateCloudTurn.appleGuarantee.hasPrefix("Apple says"))
        #expect(PrivateCloudTurn.appleGuaranteeURL.host == "security.apple.com")
    }

    // MARK: - The label survives a reload

    @Test("a PCC answer's origin round-trips through the transcript")
    func originRoundTrips() throws {
        var message = ChatMessage(role: .assistant, text: "from the cloud", status: .complete)
        message.answerOrigin = .privateCloudCompute
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.answerOrigin == .privateCloudCompute)
    }

    @Test("a transcript saved before the field existed decodes to a local answer")
    func originIsOptionalOnDecode() throws {
        let message = ChatMessage(role: .assistant, text: "old", status: .complete)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        object.removeValue(forKey: "answerOrigin")
        let decoded = try JSONDecoder().decode(
            ChatMessage.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.answerOrigin == nil)
        #expect(decoded.text == "old")
    }
}
