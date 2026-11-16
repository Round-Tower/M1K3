//
//  VoicePageRoutingTests.swift
//  M1K3PreviewTests
//
//  What a spoken turn does once the grammar has matched (#839 review): the grammar must not swallow
//  ordinary turns. "Show me that" with nothing cited goes to the model; page commands exist only while
//  a page is open; "go back" at the first page closes the page (the page-relative "back" has nowhere
//  left to go, so it leaves the page, rather than being mistaken for a question).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8. Prior: none (new file).

import Foundation
@testable import M1K3Preview
import Testing

struct VoicePageRoutingTests {
    private func route(
        _ words: String, open: Bool = false, cited: VoicePageCitedState = .none, canGoBack: Bool = false
    ) -> VoicePageAction {
        VoicePageRouting.route(words, pageIsOpen: open, cited: cited, canGoBack: canGoBack)
    }

    @Test("show me that with nothing cited falls through to the model", arguments: [
        "show me that", "put it up", "pull it up", "put that up", "show me the source",
    ])
    func nothingCitedFallsThrough(words: String) {
        #expect(route(words, cited: .none) == .passToModel)
        #expect(route(words, open: true, cited: .none) == .passToModel)
    }

    @Test("show me that with a source ready opens it")
    func readyOpens() {
        #expect(route("show me that", cited: .ready) == .openCited)
        #expect(route("Put it up", open: true, cited: .ready) == .openCited)
    }

    @Test("show me that while the answer is still being written waits for its sources")
    func pendingWaits() {
        #expect(route("show me that", cited: .pending) == .waitThenOpenCited)
    }

    @Test("page commands are live only while a page is open", arguments: [
        "scroll down", "scroll up", "go back", "close it", "close that",
    ])
    func needsOpenPage(words: String) {
        #expect(route(words, open: false, cited: .ready) == .passToModel)
        #expect(route(words, open: false, cited: .none) == .passToModel)
    }

    @Test("with a page open: scroll, close and back route to the page")
    func openPageCommands() {
        #expect(route("scroll down", open: true) == .scroll(.scrollDown))
        #expect(route("scroll up", open: true) == .scroll(.scrollUp))
        #expect(route("close it", open: true) == .close)
        #expect(route("go back", open: true, canGoBack: true) == .goBack)
    }

    @Test("go back at the first page closes the page, it is not handed to the model")
    func backAtFirstPageCloses() {
        #expect(route("go back", open: true, canGoBack: false) == .close)
    }

    @Test("ordinary speech always falls through", arguments: [
        "what's the weather", "go back to the beginning of the story", "close the door", "",
    ])
    func ordinary(words: String) {
        #expect(route(words, open: true, cited: .ready, canGoBack: true) == .passToModel)
        #expect(route(words, open: false, cited: .none) == .passToModel)
    }

    // MARK: - A deferred open dies with the page

    @Test("a deferred open is cancelled when the page is closed before it lands")
    @MainActor
    func deferredOpenCancelledByClose() async {
        let session = VoicePageSession()
        let probe = CancelProbe()
        let task = session.deferOpen {
            // Long enough that only a cancel ends it; the test never waits on a clock.
            do { try await Task.sleep(for: .seconds(600)) } catch { probe.cancelled = true }
        }
        session.close()
        await task.value
        #expect(probe.cancelled)
    }

    @Test("a newer deferred open replaces the older one")
    @MainActor
    func deferredOpenReplaced() async {
        let session = VoicePageSession()
        let probe = CancelProbe()
        let first = session.deferOpen {
            do { try await Task.sleep(for: .seconds(600)) } catch { probe.cancelled = true }
        }
        let second = session.deferOpen {}
        await first.value
        await second.value
        #expect(probe.cancelled)
    }

    @MainActor
    private final class CancelProbe {
        var cancelled = false
    }
}
