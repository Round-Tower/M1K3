//
//  VoicePagePanel.swift
//  M1K3App
//
//  The glass panel voice mode shows a quoted page in (#839): the existing WebReviewView (its
//  non-persistent store, its WebURLPolicy navigation gate, BrowserContext capture) behind a slim
//  header with Open-in-browser and Close. It is a HOST for that view, not a second browser.
//  VoiceModeView places it beside the avatar on a wide window and over it as a pop-up on a narrow
//  one; the avatar stays visible and stays the barge-in target either way.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.6 (verify-by-launch: placement over each
//  avatar skin, VoiceOver order, whether WebKit highlights the text fragment on this load).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: the page feeds its own context slot, judged on the requested
//  URL (no ReviewModel); Close takes `.cancelAction` so Esc works after a click into the page. Confidence 0.6.

import AppKit
import M1K3Preview
import SwiftUI

struct VoicePagePanel: View {
    @Environment(AppEnvironment.self) private var env
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            DeferredPanelMount {
                WebReviewView(url: url, onPageLoaded: { context in
                    // The model reads the page through BrowserContext, from the voice page's own slot. A capture
                    // that lands after the page moved on (or closed) is dropped, judged on the REQUESTED url.
                    guard env.voicePage.url == url else { return }
                    VoicePageContext.set(context)
                }, control: env.pageControl)
            }
            .id(url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Source page"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.readableSecondary)
                .accessibilityHidden(true)
            Text(url.host ?? url.absoluteString)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "safari")
            }
            .help("Open in browser")
            .accessibilityLabel("Open in browser")
            Button { env.closeVoicePage() } label: {
                Image(systemName: "xmark")
            }
            // Esc closes the page even when a click inside the web view took focus from the hero.
            .keyboardShortcut(.cancelAction)
            .help("Close page (Esc)")
            .accessibilityLabel("Close page")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The chip on a spoken answer that cited a source: a tap is the person asking for the page.
struct VoiceSourceChip: View {
    let source: CitedSourceLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(source.host, systemImage: "safari")
                .font(.callout)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .help("Show the page beside M1K3")
        .accessibilityLabel(Text("Open source: \(source.host)"))
        .accessibilityHint(Text("Shows the page beside M1K3"))
    }
}

/// What the chip needs from a cited source: just the host to name.
struct CitedSourceLabel: Equatable {
    let host: String
}
