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
//  Review: Kev + claude-opus-5.5, 2026-11-03 (pre-push review) — the web half is the EFFECTIVE state:
//  a child's age band withholds web tools whatever the switch says, so the line said "Web on" for a
//  search that could never run. `webLockedByAge` lets the shells disable the switch. Confidence 0.85.
//

import M1K3LanguageModel

public struct ChatStatusLine: Equatable, Sendable {
    /// Who answers the next typed send: the brain's name, or Private Cloud Compute when
    /// the send really goes there (the shell's `privateCloudServesNextSend`).
    public let brainText: String
    public let brainSymbol: String?
    /// Whether web search can actually run: the switch AND the age band's tool gate.
    public let webSearchOn: Bool
    /// The switch may be on, but this session's age band withholds web tools, so the
    /// shells disable the toggle rather than offer a switch that does nothing.
    public let webLockedByAge: Bool

    /// One globe for both states (SF Symbols has no slashed globe); the shell dims it when off.
    public static let webSymbol = "globe"

    /// `webSearchOn` is the user's switch; `ageBand` the session's (a child's withholds web
    /// tools whatever the switch says, `AgeAppropriateness`). Undeclared is full capability.
    public init(brainName: String, privateCloudNext: Bool, webSearchOn: Bool, ageBand: AgeBand = .undeclared) {
        brainText = privateCloudNext ? PrivateCloudLabel.text : brainName
        brainSymbol = privateCloudNext ? "cloud.fill" : nil
        let allowed = AgeAppropriateness.policy(for: ageBand).webToolsAllowed
        self.webSearchOn = webSearchOn && allowed
        webLockedByAge = !allowed
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
