//
//  HeartbeatIdleCard.swift
//  M1K3
//
//  The heartbeat on the MAIN screen (Kev's call, 2026-08-06 evening: "main
//  screen as opposed to a pop up … core to the ethos. What's going on? …
//  maybe it could be the default"): when the chat is idle/empty, the latest
//  pulse sits under the greeting — the resident telling you what's been
//  going on, ambient and chilled back. Click-through selects the Heartbeat
//  DESTINATION (the timeline — since 2026-08-19; the summoned window it
//  used to open is retired). Renders nothing while the toggle is off, so the
//  greeting stays untouched for new users; with the toggle on it shows the
//  latest pulse and/or the honest-hold line (HeartbeatHoldLine — why the
//  pulse is stale, or that the first one is coming).
//
//  Surface census after the promotion (principle 6): HeartbeatScreen
//  destination (canonical) + this teaser and the menu-bar line (ambient).
//  The Settings section remains pure consent.
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
    /// Selects the Heartbeat destination (ContentView owns the selection).
    let onOpen: () -> Void

    @AppStorage(AppEnvironment.heartbeatEnabledKey) private var heartbeatOn = false
    @State private var latest: HeartbeatEntry?
    /// The store read has completed at least once. Until then the hold line
    /// stays nil — `latest == nil` pre-load would otherwise read as "no pulse
    /// ever" and flash "first pulse on its way" at users with weeks of
    /// history (review catch, PR #104).
    @State private var hasLoadedLatest = false

    var body: some View {
        // Resolve the honest-hold line alongside the pulse: a stale pulse
        // with a known hold (thermal / busy / quiet) says why, instead of
        // silently ageing into "the heartbeat looks broken" (2026-08-08).
        let holdLine = currentHoldLine
        Group {
            if heartbeatOn, latest != nil || holdLine != nil {
                Button {
                    onOpen()
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
                // The hold line joins the label: the Button collapses its
                // subtree into one a11y element, so without this VoiceOver
                // would never hear the honest explanation the card exists
                // for (review catch, PR #104).
                .accessibilityLabel(accessibilityLabel(holdLine: holdLine))
            }
        }
        // lastHold is observable state on env, so a tick's hold refresh
        // re-evaluates the line; revision changes re-read the store.
        .task(id: env.heartbeatRevision) { await refresh() }
    }

    private var currentHoldLine: String? {
        guard hasLoadedLatest else { return nil }
        let now = Date()
        return HeartbeatHoldLine.resolve(
            now: now,
            hour: Calendar.current.component(.hour, from: now),
            lastPulse: latest?.createdAt,
            lastHold: env.heartbeatLastHold
        )
    }

    private func accessibilityLabel(holdLine: String?) -> String {
        var parts = [latest != nil ? "Heartbeat: latest pulse." : "Heartbeat: holding."]
        if let holdLine {
            parts.append(holdLine)
        }
        parts.append("Opens the Heartbeat timeline.")
        return parts.joined(separator: " ")
    }

    private func refresh() async {
        guard let store = env.heartbeatStore else { return }
        latest = await Task.detached(priority: .utility) {
            (try? store.recent(limit: 1))?.first
        }.value
        hasLoadedLatest = true
    }
}
