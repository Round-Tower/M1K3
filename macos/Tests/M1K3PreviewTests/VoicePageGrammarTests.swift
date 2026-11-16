//
//  VoicePageGrammarTests.swift
//  M1K3PreviewTests
//
//  The closed voice grammar for the page beside the avatar (#839). Whole-utterance matches
//  only: a near-miss must reach the model, not scroll a page or close it.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8. Prior: none (new file).

@testable import M1K3Preview
import Testing

struct VoicePageGrammarTests {
    @Test("page commands match while a page is open", arguments: [
        ("scroll down", VoicePageCommand.scrollDown),
        ("Scroll down.", .scrollDown),
        ("scroll down a bit", .scrollDown),
        ("page down", .scrollDown),
        ("scroll up", .scrollUp),
        ("scroll back up", .scrollUp),
        ("page up", .scrollUp),
        ("go back", .goBack),
        ("Go back!", .goBack),
        ("go back a page", .goBack),
        ("close it", .close),
        ("close that", .close),
        ("close the page", .close),
        ("close this", .close),
    ])
    func pageCommands(phrase: String, expected: VoicePageCommand) {
        #expect(VoicePageGrammar.match(phrase, pageIsOpen: true) == expected)
    }

    @Test("filler around a command is allowed")
    func filler() {
        #expect(VoicePageGrammar.match("okay scroll down please", pageIsOpen: true) == .scrollDown)
        #expect(VoicePageGrammar.match("Can you close it", pageIsOpen: true) == .close)
        #expect(VoicePageGrammar.match("please go back", pageIsOpen: true) == .goBack)
    }

    @Test("page commands do nothing with no page open: they are ordinary speech", arguments: [
        "scroll down", "scroll up", "go back", "close it",
    ])
    func needsPage(phrase: String) {
        #expect(VoicePageGrammar.match(phrase, pageIsOpen: false) == nil)
    }

    @Test("show me that and put it up open the cited source, page or no page", arguments: [
        "show me that", "Show me that!", "put it up", "put that up", "pull it up", "show me the source",
        "please put it up", "can you show me that",
    ])
    func showCited(phrase: String) {
        #expect(VoicePageGrammar.match(phrase, pageIsOpen: false) == .showCited)
        #expect(VoicePageGrammar.match(phrase, pageIsOpen: true) == .showCited)
    }

    @Test("near-misses must NOT match", arguments: [
        "scroll down the list of options in my recipe",
        "can you scroll down to the part about pricing and read it",
        "go back to the beginning of the story",
        "go back in time and tell me about rome",
        "close it down for the night",
        "close the door",
        "close the window",
        "show me that again",
        "show me that recipe",
        "show me what you found about bread",
        "put it up on the shelf",
        "put it up there with the others",
        "what does scroll down mean",
        "don't scroll down",
        "scrolling down",
        "how do I close it",
        "",
        "   ",
    ])
    func nearMisses(phrase: String) {
        #expect(VoicePageGrammar.match(phrase, pageIsOpen: true) == nil)
        #expect(VoicePageGrammar.match(phrase, pageIsOpen: false) == nil)
    }
}
