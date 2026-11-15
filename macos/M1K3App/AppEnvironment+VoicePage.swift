//
//  AppEnvironment+VoicePage.swift
//  M1K3App
//
//  Voice mode's page beside the avatar (#839), the app half: the spoken grammar's side effects,
//  and the one function that opens a page. A page opens only from a tap on a link chip or a spoken
//  request (`VoicePageOpenPolicy`; model output alone never does), and every load is judged by
//  `WebURLPolicy` inside that policy. The page is ALSO routed through the shared `ReviewModel`
//  (without presenting the inspector) so `BrowserContext` hands the model the page's title and text:
//  "what does this bit mean?" then goes to the model, which already has the page.
//
//  Spoken acknowledgements go out through the turn's own chunk lane, so they inherit the loop's
//  speak queue and relisten; no model call is made for a command.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.7 (the pure parts are pinned in
//  M1K3PreviewTests / M1K3ChatTests; this wiring is verify-by-launch on the device). Prior: none (new file).

import AppKit
import M1K3Chat
import M1K3Preview

extension AppEnvironment {
    /// The source the last answer cited, for the chip and "show me that".
    var lastCitedSource: CitedSource? {
        CitedSource.lastAnswer(in: chat.messages)
    }

    /// Open `source` beside the avatar for `origin` (a chip tap or a spoken request).
    func openVoicePage(_ source: CitedSource, origin: VoicePageOpenRequest.Origin) async {
        await voicePage.open(VoicePageOpenRequest(origin: origin, url: source.url, quote: source.quote))
        if let shown = voicePage.url {
            // Present: false, the inspector stays shut; this only feeds the page to BrowserContext.
            review.open(url: shown, present: false)
        }
    }

    func closeVoicePage() {
        guard voicePage.isOpen else { return }
        voicePage.close()
        review.clear()
    }

    /// A spoken page command. Returns the line to say back, or nil when the words are not one
    /// (they go to the model as an ordinary turn).
    func handleVoicePageCommand(_ question: String) async -> String? {
        guard let command = VoicePageGrammar.match(question, pageIsOpen: voicePage.isOpen) else { return nil }
        switch command {
        case .scrollDown, .scrollUp:
            pageControl.scroll(command, smooth: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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
            if voicePage.isOpen { return String(localized: "Here it is.") }
            return String(localized: "I can't open that one.")
        }
    }
}
