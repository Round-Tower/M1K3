//
//  AppCore+VoicePage.swift
//  M1K3iOS
//
//  Voice mode's page, the phone's half (#839): the same pure layers the Mac uses (`VoicePageGrammar`,
//  `VoicePageOpenPolicy` over `WebURLPolicy`, `CitedSource`, `TextFragmentURL`). A page opens only
//  from a tap on the source chip or a spoken request; model output alone never opens one. The host
//  is a WKWebView on a non-persistent store (`VoicePageWebView`); never SFSafariViewController,
//  which shares Safari's cookies.
//
//  Not yet wired here: handing the page to the model through `BrowserContext` ("what does this bit
//  mean?"): the phone has no review model, so that is a follow-up.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.6 (compile-checked; the layout and the
//  spoken commands are verify-on-device). Prior: none (new file).

import Foundation
import M1K3Chat
import M1K3Preview
import UIKit

extension AppCore {
    /// The source the last answer cited, for the chip and "show me that".
    var lastCitedSource: CitedSource? {
        CitedSource.lastAnswer(in: chat.messages)
    }

    func openVoicePage(_ source: CitedSource, origin: VoicePageOpenRequest.Origin) async {
        await voicePage.open(VoicePageOpenRequest(origin: origin, url: source.url, quote: source.quote))
    }

    func closeVoicePage() {
        voicePage.close()
    }

    /// A spoken page command. Returns the line to say back, or nil when the words are not one.
    func handleVoicePageCommand(_ question: String) async -> String? {
        guard let command = VoicePageGrammar.match(question, pageIsOpen: voicePage.isOpen) else { return nil }
        switch command {
        case .scrollDown, .scrollUp:
            pageControl.scroll(command, smooth: !UIAccessibility.isReduceMotionEnabled)
            return String(localized: "Scrolling.")
        case .goBack:
            return pageControl.goBack()
                ? String(localized: "Back.")
                : String(localized: "That's the first page.")
        case .close:
            closeVoicePage()
            return String(localized: "Closed.")
        case .showCited:
            guard let source = lastCitedSource else {
                return String(localized: "I don't have a page for that one.")
            }
            await openVoicePage(source, origin: .spokenRequest)
            return voicePage.isOpen ? String(localized: "Here it is.") : String(localized: "I can't open that one.")
        }
    }
}
