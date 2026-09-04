import Foundation
@testable import M1K3Chat
import Testing

/// What's open beside the chat, as it stands — so "what do you make of this
/// page?" a turn after the panel loaded it isn't answered from thin air. The
/// block is present only while a page is showing; the pinned prompts prove the
/// default (nil) is byte-identical to before.
struct BrowserContextTests {
    private let page = BrowserContext(
        url: URL(string: "https://m1k3.app/docs?x=1")!,
        title: "M1K3 for Mac — Your AI. Your Mac. Nothing leaves.",
        text: "M1K3 is a fully on-device AI companion.\n\n\n   Local inference, live voice.  "
    )

    @Test("renders the panel's page as a labelled block: title, address, then its text")
    func renders() {
        let block = page.render()
        #expect(block.hasPrefix("OPEN BESIDE THE CHAT (the review panel, as it stands"))
        #expect(block.contains("\"M1K3 for Mac — Your AI. Your Mac. Nothing leaves.\" — https://m1k3.app/docs?x=1"))
        #expect(block.hasSuffix("M1K3 is a fully on-device AI companion.\nLocal inference, live voice."))
        #expect(block.contains("describe only this text"))
    }

    @Test("an untitled page falls back to its host; text is capped with an ellipsis")
    func fallbackAndCap() throws {
        let long = try BrowserContext(
            url: #require(URL(string: "https://example.com/a")), title: "   ",
            text: String(repeating: "word ", count: 500)
        )
        let block = long.render(textBudget: 40)
        #expect(block.contains("\"example.com\" — https://example.com/a"))
        #expect(block.hasSuffix("…"))
        #expect(try #require(block.split(separator: "\n").last?.count) <= 41)
    }

    @Test("the grounding carries the block between the knowledge and the rules, and only when given")
    func groundingPlacement() throws {
        let tools: Set = ["search_knowledge"]
        let with = AgentRAGResponder.grounding(chunks: [], toolNames: tools, style: .react, ambient: page.render())
        let without = AgentRAGResponder.grounding(chunks: [], toolNames: tools, style: .react)
        #expect(!without.contains("OPEN BESIDE THE CHAT"))
        let open = try #require(with.range(of: "OPEN BESIDE THE CHAT")?.lowerBound)
        let rules = try #require(with.range(of: "RULES:")?.lowerBound)
        let knowledge = try #require(with.range(of: "No stored knowledge")?.lowerBound)
        #expect(knowledge < open && open < rules)
        // Nothing else moved: strip the block and it's the same prompt.
        let stripped = with.replacingOccurrences(of: "\n\n" + page.render(), with: "")
        #expect(stripped == without)
    }
}
