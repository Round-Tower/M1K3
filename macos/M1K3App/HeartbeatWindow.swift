//
//  HeartbeatWindow.swift
//  M1K3
//
//  The heartbeat's canonical surface (Kev's call, 2026-08-06: "a core /
//  idle piece" — nav-level, not buried in Settings): the day's pulses as a
//  readable diary, newest first, told-by attribution on every entry.
//  Settings keeps only the consent toggle + Clear; the menu-bar popover
//  keeps the one ambient line (principle 6: one canonical + one ambient,
//  zero elsewhere).
//
//  Loads on appear + on heartbeatRevision (a recorded pulse refreshes an
//  open window); store reads run OFF the main actor — the ConstellationWindow
//  rule, deliberately not AgentLogWindow's sync-read idiom.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.8 (compiles +
//  mirrors the house window idioms; the rendered feel is ⌘R verify-owed).
//  Prior: none (new file).
//

import M1K3Heartbeat
import SwiftUI

extension M1K3App {
    /// Stable id so the sidebar/menu summons (not respawns) the window.
    static let heartbeatWindowID = "heartbeat"
}

struct HeartbeatWindowContent: View {
    let env: AppEnvironment?
    @AppStorage(AppEnvironment.heartbeatEnabledKey) private var heartbeatOn = false
    @State private var pulses: [HeartbeatEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle("Heartbeat")
        .task(id: env?.heartbeatRevision ?? 0) { await refresh() }
    }

    private var header: some View {
        HStack {
            Label("Heartbeat", systemImage: "waveform.path.ecg")
                .symbolRenderingMode(.hierarchical)
                .font(.pixelTitle)
            Text("\(pulses.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                Task { await clearPulses() }
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(pulses.isEmpty)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if !heartbeatOn {
            ContentUnavailableView {
                Label("The heartbeat is off", systemImage: "waveform.path.ecg")
            } description: {
                Text("Every couple of hours M1K3 can take stock — what it learned, who "
                    + "called in, how the machine is doing — and write a short note. "
                    + "Turn it on in Settings → M1K3. Kept on this machine only.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pulses.isEmpty {
            ContentUnavailableView {
                Label("No pulses yet", systemImage: "waveform.path.ecg")
            } description: {
                Text("The first pulse lands within a couple of hours of the machine "
                    + "being awake — sooner if something's already happened today.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(pulses) { pulse in
                    row(for: pulse)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func row(for pulse: HeartbeatEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(pulse.createdAt, format: .dateTime.weekday(.wide).hour().minute())
                    .font(.caption.bold())
                Spacer()
                Text("told by \(pulse.renderedBy)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(pulse.displayText)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func refresh() async {
        guard let store = env?.heartbeatStore else { return }
        pulses = await Task.detached(priority: .utility) {
            (try? store.recent()) ?? []
        }.value
    }

    private func clearPulses() async {
        guard let store = env?.heartbeatStore else { return }
        await Task.detached(priority: .utility) { try? store.clear() }.value
        pulses = []
    }
}
