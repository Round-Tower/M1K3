//
//  BrainAtHomeSection.swift
//  M1K3App
//
//  Brain at Home's consent surface (Settings → Privacy): the serve toggle
//  (default OFF — nil is a NO), the pairing ceremony (QR sheet + the on-Mac
//  Approve that is audit B2's whole point), the paired-device list with
//  one-tap revoke (audit S3), and the SECOND consent tier — the scoped LAN
//  MCP toggle, never inherited from the serve toggle.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.75 (thin view over
//  the tested controller/policies; layout + the pairing feel are ⌘R
//  verify-owed). Prior: none (new file).
//

import M1K3BrainServe
import SwiftUI

struct BrainAtHomeSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showPairingSheet = false

    var body: some View {
        Section {
            Toggle("Serve my brain to my devices", isOn: Binding(
                get: { env.brainServe.isEnabled },
                set: { env.brainServe.isEnabled = $0 }
            ))
            if env.brainServe.isEnabled {
                if let status = env.brainServe.statusText {
                    LabeledContent("Status", value: status)
                }
                Toggle("Also serve MCP tools to paired devices", isOn: Binding(
                    get: { env.brainServe.lanMCPEnabled },
                    set: { env.brainServe.lanMCPEnabled = $0 }
                ))
                Button("Pair a device…") {
                    showPairingSheet = true
                    Task { await env.brainServe.beginPairing() }
                }
                .buttonStyle(.glass)
                ForEach(env.brainServe.pairedDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Paired \(device.addedAt, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) {
                            Task { await env.brainServe.revoke(device) }
                        }
                    }
                }
            }
        } header: {
            Text("Brain at Home")
        } footer: {
            Text("""
            Serves raw generation to devices you pair by QR code — local \
            network only, encrypted with a key that never travels the \
            network; no persona, memory, or documents included. The MCP \
            toggle adds read-only tools (search, documents, ask) — asks \
            can reach the web when the web-search toggle allows. Off by \
            default; revoking a device cuts it off immediately.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showPairingSheet, onDismiss: { env.brainServe.cancelPairing() }) {
            BrainPairingSheet(showSheet: $showPairingSheet)
        }
    }
}

/// The QR ceremony sheet: code + countdown while displaying; the Approve
/// decision when a device completes the handshake and asks to pair.
struct BrainPairingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showSheet: Bool

    var body: some View {
        VStack(spacing: 16) {
            switch env.brainServe.pairing.phase {
            case .idle:
                // Expired (or just opened) — beginPairing repopulates.
                Text("The pairing code expired.")
                    .font(.headline)
                Button("Show a new code") {
                    Task { await env.brainServe.beginPairing() }
                }
                .buttonStyle(.glass)
            case .displaying:
                Text("Pair a device")
                    .font(.headline)
                if let qr = env.brainServe.pairingQRImage {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Pairing QR code")
                }
                Text("Scan this in M1K3 on the other device. The code lives for a "
                    + "minute and commits nothing until you approve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // Camera-less clients (desktops, emulators, a paired agent on
                // this Mac) paste the same payload the QR encodes. Same
                // security shape: the code is only the UNCOMMITTED candidate —
                // nothing pairs until Approve, and it dies in ≤60s.
                Button("Copy setup code") {
                    if let payload = env.brainServe.pairingQRPayload {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload, forType: .string)
                    }
                }
                .buttonStyle(.glass)
            case let .awaitingApproval(candidateName, _):
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                Text("“\(candidateName)” wants to pair")
                    .font(.headline)
                Text("Only approve a device you're holding right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Decline", role: .cancel) {
                        env.brainServe.cancelPairing()
                        showSheet = false
                    }
                    Button("Approve") {
                        Task {
                            await env.brainServe.approvePairing()
                            showSheet = false
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            Button("Close") {
                showSheet = false
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}
