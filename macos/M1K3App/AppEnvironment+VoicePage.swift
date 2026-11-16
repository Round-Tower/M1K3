//
//  AppEnvironment+VoicePage.swift
//  M1K3App
//
//  Voice mode's page beside the avatar (#839), the app half: the spoken grammar's side effects,
//  and the one function that opens a page. A page opens only from a tap on a link chip or a spoken
//  request (`VoicePageOpenPolicy`; model output alone never does), and every load is judged by
//  `WebURLPolicy` inside that policy. The page's title and text reach the model through its OWN
//  context slot (`VoicePageContext`, read beside `ReviewModel.liveContext` by the responder's
//  `browserContextProvider`), so "what does this bit mean?" goes to the model, which already has the
//  page, and the chat inspector's target and page are never touched.
//
//  Spoken acknowledgements go out through the turn's own chunk lane, so they inherit the loop's
//  speak queue and relisten; no model call is made for a command. Words that are not a command, or
//  "show me that" with nothing cited, return nil and go to the model as an ordinary turn
//  (`VoicePageRouting`).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.7 (the pure parts are pinned in
//  M1K3PreviewTests / M1K3ChatTests; this wiring is verify-by-launch on the device). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: the page has its own context slot (no ReviewModel);
//  routing through `VoicePageRouting`; "show me that" mid-answer says "one moment" and opens when the sources
//  land; `closeVoicePage` always cancels a pending open. Confidence 0.7.

import AppKit
import M1K3Chat
import M1K3Preview
import Synchronization

/// What the open voice page last rendered, for the responder's `BrowserContext` (a lock, not the main
/// actor, because the turn runs off it, the `ReviewModel.liveContext` pattern).
enum VoicePageContext {
    nonisolated static let live = Mutex<BrowserContext?>(nil)

    static func set(_ context: BrowserContext?) {
        live.withLock { $0 = context }
    }
}

extension AppEnvironment {
    /// The source the last answer cited, for the chip. Cached per finished message.
    var lastCitedSource: CitedSource? {
        if case let .ready(source) = citedCache.availability(in: chat.messages) { return source }
        return nil
    }

    /// Open `source` beside the avatar for `origin` (a chip tap or a spoken request).
    func openVoicePage(_ source: CitedSource, origin: VoicePageOpenRequest.Origin) async {
        VoicePageContext.set(nil)
        await voicePage.open(VoicePageOpenRequest(origin: origin, url: source.url, quote: source.quote))
    }

    func closeVoicePage() {
        voicePage.close() // always: it also cancels an open still waiting for its sources
        VoicePageContext.set(nil)
    }

    /// A spoken page command. Returns the line to say back, or nil when the words are an ordinary turn.
    func handleVoicePageCommand(_ question: String) async -> String? {
        let availability = citedCache.availability(in: chat.messages)
        let state: VoicePageCitedState = switch availability {
        case .ready: .ready
        case .pending: .pending
        case .none: .none
        }
        switch VoicePageRouting.route(
            question, pageIsOpen: voicePage.isOpen, cited: state, canGoBack: pageControl.canGoBack
        ) {
        case .passToModel:
            return nil
        case let .scroll(command):
            pageControl.scroll(command, smooth: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return String(localized: "Scrolling.")
        case .goBack:
            pageControl.goBack()
            return String(localized: "Back.")
        case .close:
            closeVoicePage()
            return String(localized: "Closed.")
        case .openCited:
            guard case let .ready(source) = availability else { return nil }
            await openVoicePage(source, origin: .spokenRequest)
            return voicePage.isOpen ? String(localized: "Here it is.") : String(localized: "I can't open that one.")
        case .waitThenOpenCited:
            voicePage.deferOpen { [weak self] in await self?.openWhenSourcesLand() }
            return String(localized: "One moment.")
        }
    }

    /// The answer was still streaming when the person asked; its sources land when it finishes.
    private func openWhenSourcesLand() async {
        while case .pending = citedCache.availability(in: chat.messages) {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        guard !Task.isCancelled, case let .ready(source) = citedCache.availability(in: chat.messages) else { return }
        await openVoicePage(source, origin: .spokenRequest)
    }
}
