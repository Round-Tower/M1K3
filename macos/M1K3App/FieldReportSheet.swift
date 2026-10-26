//
//  FieldReportSheet.swift
//  M1K3App
//
//  The "Send this exchange to Round Tower?" sheet (#708), in the shape of the Private Cloud
//  Compute consent sheet: one sentence on what leaves and where, the EXACT body in an editable
//  field (trim it, take a word out, add one), and three honest buttons — keep it on this Mac,
//  copy it instead, or send it by email. Nothing leaves until Send, and then only through the
//  user's own mail app; M1K3 makes no connection. Every send shows this sheet: there is no
//  once-and-remember here, by design.
//
//  App glue, committed with TDD_SKIP: the body and the link are M1K3Diagnostics' and pinned
//  there; FieldReportScanTests pins that this is the only caller of FieldReporter.send.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.7 (verify-by-launch owed: the sheet,
//  the mail app's compose window, the clipboard fallback — UNVERIFIED this run).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — the sentence names the note and says the
//  answer may quote what M1K3 read; a could-not-open outcome with its own caption. Confidence 0.7.
//

import SwiftUI

struct FieldReportSheet: View {
    let draft: FieldReportDraft
    let onDone: () -> Void

    @State private var text: String
    /// What happened after Copy or Send, when the sheet stays open to say so.
    @State private var caption: String?

    init(draft: FieldReportDraft, onDone: @escaping () -> Void) {
        self.draft = draft
        self.onDone = onDone
        _text = State(initialValue: draft.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Send this exchange to Round Tower?", systemImage: "envelope")
                .font(.title3.weight(.semibold))

            Text("""
            This is the whole message: your message, M1K3's answer, your note, the brain and the app version — \
            nothing else from this Mac, though the answer may quote what M1K3 read to write it. \
            It goes to \(FieldReporter.recipient) from your own mail app, which opens with it filled in. \
            M1K3 sends nothing itself. Change anything below first if you like.
            """)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .accessibilityLabel("The exact text that will be sent")

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(caption == nil ? "Keep it on this Mac" : "Done", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Copy instead") {
                    FieldReporter.copy(text)
                    caption = "Copied. Nothing was sent — paste it wherever you like."
                }
                Button("Send by email") {
                    switch FieldReporter.send(subject: draft.subject, body: text) {
                    case .opened:
                        onDone()
                    case .copiedTruncated:
                        caption = """
                        Your mail app opened with the start of it. The message was too long for one link, \
                        so the full text is on your clipboard — paste it in before you send.
                        """
                    case .copiedNoMailClient:
                        caption = """
                        No mail app is set up on this Mac. The full text is on your clipboard — \
                        paste it into an email to \(FieldReporter.recipient).
                        """
                    case .copiedCouldNotOpen:
                        caption = """
                        Your mail app didn't open the message — the link may be too long for it. The full text \
                        is on your clipboard; paste it into an email to \(FieldReporter.recipient).
                        """
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
