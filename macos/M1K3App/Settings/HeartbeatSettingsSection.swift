//
//  HeartbeatSettingsSection.swift
//  M1K3App
//
//  The heartbeat's consent surface: the feature toggle (OFF by default — a
//  persisted pulse history is a promise surface), the pulse-notification
//  opt-in (its own key + honest-grant contract), and one-tap Clear. The
//  pulses themselves live in the Heartbeat sidebar DESTINATION (the canonical
//  surface since the 2026-08-19 promotion — this Settings section keeps only
//  consent; the summoned window is retired).
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.8 (compiles +
//  mirrors existing panes; the rendered feel is a named ⌘R verify-owed).
//  Prior: none (new file). Review: Kev + claude-fable-5, 2026-08-06 — list
//  moved to HeartbeatWindow on Kev's "core / idle piece" call; notification
//  opt-in added on his "rich notification" call.
//

import M1K3Heartbeat
import SwiftUI

struct HeartbeatSettingsSection: View {
    let env: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppEnvironment.heartbeatEnabledKey) private var heartbeatOn = false
    @AppStorage(AppEnvironment.notifyOnHeartbeatKey) private var notifyOn = false

    var body: some View {
        Section {
            Toggle("Heartbeat (status pulse every 2 hours)", isOn: $heartbeatOn)
            if heartbeatOn {
                Toggle("Notify on new pulses", isOn: Binding(
                    get: { notifyOn },
                    set: { enabled in
                        Task {
                            await env.setHeartbeatNotifications(enabled)
                            notifyOn = env.notifyOnHeartbeatEnabled
                        }
                    }
                ))
                Button("Show the Heartbeat") {
                    // Settings is its own scene: ask the main window to select
                    // the destination, then summon it (request set FIRST so
                    // ContentView's consume-on-task sees it even on a cold open).
                    env.pendingSidebarRequest = .heartbeat
                    openWindow(id: M1K3App.mainWindowID)
                }
                .buttonStyle(.glass)
                Button("Clear pulses", role: .destructive) {
                    Task { await clearPulses() }
                }
            }
        } header: {
            Text("Heartbeat")
        } footer: {
            Text("Every couple of hours M1K3 takes stock and writes a short note. "
                + "Kept on this machine, capped at a week, never remembered as facts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: heartbeatOn) { _, enabled in
            env.setHeartbeatEnabled(enabled)
        }
    }

    private func clearPulses() async {
        guard let store = env.heartbeatStore else { return }
        await Task.detached(priority: .utility) { try? store.clear() }.value
        env.heartbeatRevision += 1
    }
}
