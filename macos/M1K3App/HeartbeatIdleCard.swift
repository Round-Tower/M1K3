//
//  HeartbeatIdleCard.swift
//  M1K3
//
//  The heartbeat on the MAIN screen (Kev's call, 2026-08-06 evening: "main
//  screen as opposed to a pop up … core to the ethos. What's going on? …
//  maybe it could be the default"): when the chat is idle/empty, the latest
//  pulse sits under the greeting — the resident telling you what's been
//  going on, ambient and chilled back. Click-through opens the Heartbeat
//  window (the history). Renders nothing while the toggle is off or before
//  the first pulse, so the greeting stays untouched for new users.
//
//  Surface census after this change (principle 6): main-screen idle card
//  (canonical) + menu-bar line (ambient) + the Heartbeat window (history
//  drill-in, summoned). The Settings section remains pure consent.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.8 (compiles;
//  reads via the same off-main revision-driven idiom as the other
//  heartbeat surfaces; rendered feel is ⌘R verify-owed). Prior: none
//  (new file).
//

import M1K3Heartbeat
import SwiftUI

struct HeartbeatIdleCard: View {
    let env: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppEnvironment.heartbeatEnabledKey) private var heartbeatOn = false
    @State private var latest: HeartbeatEntry?

    var body: some View {
        // Resolve the honest-hold line alongside the pulse: a stale pulse
        // with a known hold (thermal / busy / quiet) says why, instead of
        // silently ageing into "the heartbeat looks broken" (2026-08-08).
        let holdLine = currentHoldLine
        Group {
            if heartbeatOn, latest != nil || holdLine != nil {
                Button {
                    openWindow(id: M1K3App.heartbeatWindowID)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let pulse = latest {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform.path.ecg")
                                    .symbolRenderingMode(.hierarchical)
                                Text(pulse.createdAt, style: .relative) + Text(" ago · told by \(pulse.renderedBy)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(pulse.displayText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(5)
                        }
                        if let holdLine {
                            HStack(spacing: 6) {
                                Image(systemName: "zzz")
                                    .symbolRenderingMode(.hierarchical)
                                Text(holdLine)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                    .padding(14)
                    .glassEffect(in: .rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Heartbeat: latest pulse. Opens the Heartbeat window.")
            }
        }
        // lastHold is observable state on env, so a tick's hold refresh
        // re-evaluates the line; revision changes re-read the store.
        .task(id: env.heartbeatRevision) { await refresh() }
    }

    private var currentHoldLine: String? {
        let now = Date()
        return HeartbeatHoldLine.resolve(
            now: now,
            hour: Calendar.current.component(.hour, from: now),
            lastPulse: latest?.createdAt,
            lastHold: env.heartbeatLastHold
        )
    }

    private func refresh() async {
        guard let store = env.heartbeatStore else { return }
        latest = await Task.detached(priority: .utility) {
            (try? store.recent(limit: 1))?.first
        }.value
    }
}
