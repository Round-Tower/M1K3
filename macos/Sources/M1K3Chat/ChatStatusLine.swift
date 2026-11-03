//
//  ChatStatusLine.swift
//  M1K3Chat
//
//  The one line over the composer that says who answers the next message and whether web
//  search is in play: "Lil · Web on". Kev, 2026-11-03: "It's about trust." The first App
//  Store review couldn't tell what state M1K3 was in, and web search (the one thing that
//  sends a question off the device) was a switch buried in Settings. Pure, so the copy is
//  pinned by ChatStatusLineTests; the shells draw it and own the taps.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.85 (copy pinned; the layout is
//  verify-by-launch on the iPhone, the Duo and the Mac). Prior: none (new file).
//

import M1K3LanguageModel

public struct ChatStatusLine: Equatable, Sendable {
    /// Who answers the next typed send: the brain's name, or Private Cloud Compute when
    /// the send really goes there (the shell's `privateCloudServesNextSend`).
    public let brainText: String
    public let brainSymbol: String?
    public let webSearchOn: Bool

    /// One globe for both states (SF Symbols has no slashed globe); the shell dims it when off.
    public static let webSymbol = "globe"

    public init(brainName: String, privateCloudNext: Bool, webSearchOn: Bool) {
        brainText = privateCloudNext ? PrivateCloudLabel.text : brainName
        brainSymbol = privateCloudNext ? "cloud.fill" : nil
        self.webSearchOn = webSearchOn
    }

    public var webText: String {
        Self.webText(on: webSearchOn)
    }

    /// The web half alone, for a surface that shows the brain elsewhere (the Mac's toolbar).
    public static func webText(on: Bool) -> String {
        on ? "Web on" : "Web off"
    }

    public var text: String {
        "\(brainText) · \(webText)"
    }

    public var accessibilityLabel: String {
        "\(brainText) answers. Web search is \(webSearchOn ? "on" : "off")."
    }
}
