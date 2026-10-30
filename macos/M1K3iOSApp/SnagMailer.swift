//
//  SnagMailer.swift
//  M1K3iOS
//
//  The phone's half of #750's hand-off: the snag report goes out through the user's own mail
//  app, never from M1K3. `MailHandoff` (M1K3Diagnostics, unit-pinned) decides the outcome and
//  the clipboard rule; this supplies the three OS calls. Asking iOS whether any app handles
//  mailto: needs LSApplicationQueriesSchemes in Info.plist, so `hasHandler` answers yes and the
//  open's own answer is logged instead: a phone with Mail deleted gets the system's Restore
//  prompt, and the sheet's caption already says Copy instead still has the text.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.7 (verify-by-launch owed: Mail opens
//  with the report filled in). Prior: none (new file; FieldReporter's Mac shape).
//

import M1K3Diagnostics
import os
import UIKit

enum SnagMailer {
    /// Open the user's mail app with the report filled in. Called from the sheet's Send button
    /// and nowhere else (SnagNoteScanTests).
    @MainActor
    static func send(subject: String, body: String) -> MailHandoff.Outcome {
        MailHandoff.send(
            link: MailtoURL.compose(to: RoundTowerReports.recipient, subject: subject, body: body),
            body: body, via: PhoneMail()
        )
    }

    /// The whole text to the clipboard: the sheet's "Copy instead", and the fallback above.
    @MainActor
    static func copy(_ body: String) {
        UIPasteboard.general.string = body
    }
}

@MainActor
private struct PhoneMail: MailOpening {
    func hasHandler(for _: URL) -> Bool {
        true
    }

    func open(_ url: URL) -> Bool {
        UIApplication.shared.open(url) { accepted in
            Logger(subsystem: "app.m1k3", category: "launch")
                .notice("snag report: mail link \(accepted ? "accepted" : "refused", privacy: .public)")
        }
        return true
    }

    func copy(_ text: String) {
        SnagMailer.copy(text)
    }
}
