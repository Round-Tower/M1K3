//
//  AppCore+VoicePage.swift
//  M1K3iOS
//
//  Voice mode's page, the phone's half (#839): the same pure layers the Mac uses (`VoicePageRouting`,
//  `VoicePageOpenPolicy` over `WebURLPolicy`, `CitedSource`, `TextFragmentURL`). A page opens only
//  from a tap on the source chip or a spoken request; model output alone never opens one. The host
//  is a WKWebView on a non-persistent store (`VoicePageWebView`); never SFSafariViewController,
//  which shares Safari's cookies. Words that are not a command, or "show me that" with nothing
//  cited, return nil and go to the model as an ordinary turn.
//
//  Not yet wired here: handing the page to the model through `BrowserContext` ("what does this bit
//  mean?"): the phone has no review model, so that is a follow-up.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.6 (compile-checked; the layout and the
//  spoken commands are verify-on-device). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: routing through `VoicePageRouting`; "show me that"
//  mid-answer says "one moment" and opens when the sources land; `closeVoicePage` always cancels a pending open.

import Foundation
import M1K3Chat
import M1K3Preview
import UIKit

extension AppCore {
    /// The source the last answer cited, for the chip. Cached per finished message.
    var lastCitedSource: CitedSource? {
        if case let .ready(source) = citedCache.availability(in: chat.messages) { return source }
        return nil
    }

    func openVoicePage(_ source: CitedSource, origin: VoicePageOpenRequest.Origin) async {
        await voicePage.open(VoicePageOpenRequest(origin: origin, url: source.url, quote: source.quote))
    }

    func closeVoicePage() {
        voicePage.close() // always: it also cancels an open still waiting for its sources
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
            pageControl.scroll(command, smooth: !UIAccessibility.isReduceMotionEnabled)
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
