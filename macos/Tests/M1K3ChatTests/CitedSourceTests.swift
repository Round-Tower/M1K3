//
//  CitedSourceTests.swift
//  M1K3ChatTests
//
//  Which page did the last answer cite (#839)? Read off the deterministic "Web sources:" /
//  "Wikipedia sources:" block the app appends (URLs lifted from tool observations, not the
//  model), and only when the turn really ran the matching tool: a block a model wrote itself,
//  or one inside a read's answer, cites nothing.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8. Prior: none (new file).

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

struct CitedSourceTests {
    private func answer(_ text: String, tools: [String]?, status: ChatMessage.Status = .complete) -> ChatMessage {
        var message = ChatMessage(role: .assistant, text: text, status: status)
        message.toolsUsed = tools
        return message
    }

    private let webBlock = "\n\nWeb sources:\n• https://example.com/fox\n• https://example.org/other"

    @Test("the first URL of the web sources block is the cited source")
    func webBlockFirstURL() {
        let message = answer("Foxes are small." + webBlock, tools: ["web_search"])
        #expect(CitedSource.find(in: message)?.url.absoluteString == "https://example.com/fox")
        #expect(CitedSource.urls(in: message).map(\.absoluteString) == ["https://example.com/fox", "https://example.org/other"])
    }

    @Test("the Wikipedia block counts when lookup_fact ran")
    func wikipediaBlock() {
        let message = answer("A fox is a canid.\n\nWikipedia sources:\n• https://en.wikipedia.org/wiki/Fox", tools: ["lookup_fact"])
        #expect(CitedSource.find(in: message)?.url.absoluteString == "https://en.wikipedia.org/wiki/Fox")
    }

    @Test("a block with no matching tool in the turn cites nothing: a model wrote it")
    func blockWithoutToolIgnored() {
        #expect(CitedSource.find(in: answer("Hi." + webBlock, tools: nil)) == nil)
        #expect(CitedSource.find(in: answer("Hi." + webBlock, tools: [])) == nil)
        #expect(CitedSource.find(in: answer("Hi." + webBlock, tools: ["lookup_fact"])) == nil)
    }

    @Test("a read's answer never cites, so a planted link cannot be put up")
    func readNeverCites() {
        let message = answer("Summary." + webBlock, tools: [ReadPrompt.toolName])
        #expect(CitedSource.find(in: message) == nil)
    }

    @Test("a user message cites nothing")
    func userMessage() {
        var message = ChatMessage(role: .user, text: "x" + webBlock, status: .complete)
        message.toolsUsed = ["web_search"]
        #expect(CitedSource.find(in: message) == nil)
    }

    @Test("non-http URLs in the block are skipped")
    func onlyHTTP() {
        let message = answer("A.\n\nWeb sources:\n• file:///etc/hosts\n• https://example.com/ok", tools: ["web_search"])
        #expect(CitedSource.find(in: message)?.url.absoluteString == "https://example.com/ok")
    }

    @Test("a quoted passage in the answer body rides along as the highlight")
    func quoteExtracted() {
        let text = "The page says \u{201C}foxes are small omnivorous mammals of the dog family\u{201D} which is neat." + webBlock
        #expect(CitedSource.find(in: answer(text, tools: ["web_search"]))?.quote
            == "foxes are small omnivorous mammals of the dog family")
        let straight = "It reads \"the red fox is the largest of the true foxes\" in full." + webBlock
        #expect(CitedSource.find(in: answer(straight, tools: ["web_search"]))?.quote
            == "the red fox is the largest of the true foxes")
    }

    @Test("a short quoted word or scare-quote is not a passage", arguments: [
        "People call it \"the fox\" often.", "A \u{201C}quick\u{201D} one.", "He said \"yes it is\" twice.",
    ])
    func shortQuoteIgnored(body: String) {
        #expect(CitedSource.find(in: answer(body + webBlock, tools: ["web_search"]))?.quote == nil)
    }

    @Test("a quote inside the sources block is not read as the passage")
    func quoteInBlockIgnored() {
        let text = "Plain answer.\n\nWeb sources:\n• https://example.com/\"a long quoted thing in the block\""
        #expect(CitedSource.find(in: answer(text, tools: ["web_search"]))?.quote == nil)
    }

    @Test("the last answer is the one that counts: an earlier cite does not carry over")
    func lastAnswerOnly() {
        let earlier = answer("Foxes." + webBlock, tools: ["web_search"])
        let later = answer("Just chatting.", tools: nil)
        let user = ChatMessage(role: .user, text: "thanks", status: .complete)
        #expect(CitedSource.lastAnswer(in: [earlier, user, later]) == nil)
        #expect(CitedSource.lastAnswer(in: [later, user, earlier])?.url.absoluteString == "https://example.com/fox")
        #expect(CitedSource.lastAnswer(in: []) == nil)
    }

    @Test("a failed or streaming answer is still read for its block")
    func streamingStillRead() {
        let message = answer("Foxes." + webBlock, tools: ["web_search"], status: .streaming)
        #expect(CitedSource.find(in: message) != nil)
    }
}
