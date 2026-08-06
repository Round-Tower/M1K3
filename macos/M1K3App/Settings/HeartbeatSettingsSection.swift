//
//  HeartbeatSettingsSection.swift
//  M1K3App
//
//  The heartbeat's canonical surface (principle 6: this list + the one
//  ambient line in the menu-bar popover, zero elsewhere): the consent
//  toggle (OFF by default — a persisted pulse history is a promise
//  surface), the recent pulses, and one-tap Clear. Store reads run off
//  the main actor (the ConstellationWindow rule); the list re-reads on
//  `heartbeatRevision`.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.8 (compiles +
//  wiring mirrors existing panes; the rendered feel is a named ⌘R
//  verify-owed). Prior: none (new file).
//

import M1K3Heartbeat
import SwiftUI

struct HeartbeatSettingsSection: View {
    let env: AppEnvironment

    @AppStorage(AppEnvironment.heartbeatEnabledKey) private var heartbeatOn = false
    @State private var pulses: [HeartbeatEntry] = []

    var body: some View {
        Section {
            Toggle("Heartbeat (status pulse every 2 hours)", isOn: $heartbeatOn)
            if heartbeatOn {
                if pulses.isEmpty {
                    Text("No pulses yet — the first lands within the next couple of hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pulses.prefix(6)) { pulse in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(pulse.createdAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                                Spacer()
                                Text("told by \(pulse.renderedBy)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Text(pulse.displayText)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Clear pulses", role: .destructive) {
                        Task { await clearPulses() }
                    }
                }
            }
        } header: {
            Text("Heartbeat")
        } footer: {
            Text("Every couple of hours M1K3 takes stock — what it learned, who called in, "
                + "how the machine is doing — and writes a short note, told by the best "
                + "brain the moment allows. Kept on this machine only, capped at a week, "
                + "never remembered as facts. Clear wipes every pulse.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: env.heartbeatRevision) { await refresh() }
        .onChange(of: heartbeatOn) { _, enabled in
            env.setHeartbeatEnabled(enabled)
            if enabled { Task { await refresh() } }
        }
    }

    private func refresh() async {
        guard let store = env.heartbeatStore else { return }
        pulses = await Task.detached(priority: .utility) {
            (try? store.recent(limit: 6)) ?? []
        }.value
    }

    private func clearPulses() async {
        guard let store = env.heartbeatStore else { return }
        await Task.detached(priority: .utility) { try? store.clear() }.value
        pulses = []
    }
}
