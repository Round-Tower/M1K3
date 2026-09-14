//
//  PrivateCloudConsentSheet.swift
//  M1K3App
//
//  The sheet every Private Cloud Compute send passes through (ADR 0006). It
//  says in one sentence what leaves and where it goes, shows the message, and
//  offers one box — this conversation — that is OFF each time, with its exact
//  text one click away. Nothing is remembered between sends: a habit of
//  ticking is the risk the design guards against, and the default sends the
//  minimum.
//
//  App glue, committed with TDD_SKIP: the words are PrivateCloudTurn's and the
//  send path is ChatSession's, both tested in the package.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 (verified by launch
//  against the Debug echo backend: the message, the box off by default, the
//  disclosed transcript matching what the echo received; the words are the
//  package's, pinned there). Prior: Unknown
//

import M1K3Chat
import M1K3LanguageModel
import SwiftUI

struct PrivateCloudConsentSheet: View {
    let consent: PrivateCloudTurn.Consent
    let onSend: (_ includeConversation: Bool) -> Void
    let onCancel: () -> Void

    @State private var includeConversation = false
    @State private var showConversation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Send to Private Cloud Compute?", systemImage: PrivateCloudLabel.symbolName)
                .font(.title3.weight(.semibold))

            Text(PrivateCloudTurn.summary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Your message") {
                Text(consent.question)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1 ... 8)
            }

            if let conversation = consent.conversation {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Also send this conversation", isOn: $includeConversation)
                    DisclosureGroup("Show exactly what that sends", isExpanded: $showConversation) {
                        ScrollView {
                            Text(conversation)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                    .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(PrivateCloudTurn.appleGuarantee)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("How Apple protects it", destination: PrivateCloudTurn.appleGuaranteeURL)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Keep it on this Mac", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Send to Private Cloud Compute") { onSend(includeConversation) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
