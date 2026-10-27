//
//  MailHandoff.swift
//  M1K3Diagnostics
//
//  The "Send by email" decision for the opt-in field report (#708), apart from the OS. Three facts
//  decide it: was the link built, does any app on this Mac handle mailto:, and did it open. The
//  privacy-relevant part is the clipboard. The full body goes there on every outcome except a
//  whole link that opened, and before the mail app takes the front, so the user's edited text is
//  never lost to a cut link or a refusal. The app supplies the three OS calls (NSWorkspace and
//  NSPasteboard) as a `MailOpening`; MailHandoffTests drives every row with a fake.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85 (pure, every outcome row pinned;
//  the live hand-off is verify-by-launch, UNVERIFIED this run). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (bot review fold) — comment only: `.opened` is Launch Services
//  accepting the link, so the sheet stays open on it rather than this copying on every send. Confidence 0.85.
//

import Foundation

/// The OS half of the hand-off. The app's live value wraps NSWorkspace and NSPasteboard.
@MainActor
public protocol MailOpening {
    /// Whether any app on this Mac handles the link's scheme.
    func hasHandler(for url: URL) -> Bool
    /// Ask that app to open the link. False when Launch Services refused it. True means only
    /// that it was accepted, not that a compose window appeared.
    func open(_ url: URL) -> Bool
    /// Put the whole text on the clipboard.
    func copy(_ text: String)
}

public enum MailHandoff {
    public enum Outcome: Equatable, Sendable {
        /// A mail app accepted the whole link. Nothing was copied. Accepted is not a compose
        /// window (a Mail with no account opens its setup), so the sheet stays open with the
        /// text on screen rather than putting every send on the clipboard.
        case opened
        /// The link was over the cap: the mail app opened with the start of the body, and the
        /// full text is on the clipboard.
        case copiedTruncated
        /// No app on this Mac handles mailto: links. The full text is on the clipboard.
        case copiedNoMailClient
        /// The link could not be built, or a mail app would not open it. The full text is on
        /// the clipboard.
        case copiedCouldNotOpen
    }

    /// Hand `link` to the user's mail app, with `body` (the full text the user approved) as
    /// the clipboard fallback. A nil link (one that could not be built) is a could-not-open,
    /// never "no mail app": that caption would send the user looking for a problem they don't have.
    @MainActor
    public static func send(link: MailtoURL.Built?, body: String, via mail: some MailOpening) -> Outcome {
        guard let link else {
            mail.copy(body)
            return .copiedCouldNotOpen
        }
        guard mail.hasHandler(for: link.url) else {
            mail.copy(body)
            return .copiedNoMailClient
        }
        // A cut link: the full text goes on the clipboard before the mail app takes the front.
        if link.truncated { mail.copy(body) }
        guard mail.open(link.url) else {
            if !link.truncated { mail.copy(body) }
            return .copiedCouldNotOpen
        }
        return link.truncated ? .copiedTruncated : .opened
    }
}
