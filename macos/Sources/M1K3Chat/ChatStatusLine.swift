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
//  Review: claude-opus-5-5, 2026-11-19 — localisable (l10n Phase 0): the chip's "Web on"/"Web off" and
//  the VoiceOver label resolve from M1K3Chat's catalog (`bundle: .module`). The label is ONE sentence per
//  state with the brain name as its argument, never a nested "on"/"off" fragment. Display-only (rg: only
//  the Mac toolbar, the iPhone status line and tests read it; nothing model-facing). English unchanged;
//  `brainText` stays the untranslated brain/PCC name. Confidence 0.85.
//  Review: claude-opus-5-5, 2026-11-19 — review fold: the VoiceOver label's translator comment names "Brain at Home"
//  (what the iPhone passes when Home fronts, `AppCore.answeringBrainName`), not "Home". Comment only.
//

import Foundation
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
        on
            ? String(localized: "Web on", bundle: .module, comment: "Chat status chip: web search can run for the next message")
            : String(localized: "Web off", bundle: .module, comment: "Chat status chip: web search is off for the next message")
    }

    public var text: String {
        "\(brainText) · \(webText)"
    }

    /// One whole sentence per state so a translation never stitches "on"/"off" into another sentence.
    public var accessibilityLabel: String {
        webSearchOn
            ? String(
                localized: "\(brainText) answers. Web search is on.",
                bundle: .module,
                comment: "VoiceOver label of the chat status line. %@ is the brain's name (Mini, Lil, Big, Brain at Home) or Private Cloud Compute; keep it untranslated"
            )
            : String(
                localized: "\(brainText) answers. Web search is off.",
                bundle: .module,
                comment: "VoiceOver label of the chat status line. %@ is the brain's name (Mini, Lil, Big, Brain at Home) or Private Cloud Compute; keep it untranslated"
            )
    }
}
