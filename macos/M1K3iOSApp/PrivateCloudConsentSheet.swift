//
//  PrivateCloudConsentSheet.swift
//  M1K3iOS
//
//  The PCC consent sheet for iOS (ADR 0010: asked once, answer persists until
//  PCC is turned off). Mirrors the Mac's sheet with "this device" instead of
//  "this Mac", and a navigation-bar presentation that suits the phone.
//
//  Signed: Kev + claude-opus-4-6, 2026-10-12, Confidence 0.75 (verify on device).
//  Prior: the Mac's PrivateCloudConsentSheet (M1K3App/).
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
        NavigationStack {
            ScrollView {
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
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep it here", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(includeConversation) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PendingPrivateCloudSend: Identifiable {
    let id = UUID()
    let consent: PrivateCloudTurn.Consent
    let onDeviceShown: Set<UUID>
}
