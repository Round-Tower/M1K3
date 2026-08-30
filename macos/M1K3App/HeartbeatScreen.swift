//
//  HeartbeatScreen.swift
//  M1K3
//
//  The heartbeat's canonical surface — PROMOTED from a summoned Window to a
//  sidebar DESTINATION 2026-08-19 (Kev: "the heartbeat needs to be a
//  destination screen, with the agent comms foldered in — like a timeline of
//  interaction"). The detail pane shows the day's story as one timeline:
//  heartbeat pulses interleaved with visiting-agent activity, agent calls
//  folded into per-client VISITS (InteractionTimeline, M1K3Heartbeat — pure,
//  TDD'd). Surface census (principle 6): this destination (canonical) +
//  the menu-bar line and idle-card teaser (ambient) + Settings (consent).
//
//  Agent comms render only what the opt-in Agent Interaction Log holds
//  (OFF by default, capped 500); when the log is off, the screen OFFERS the
//  toggle where it matters instead of showing a silently lopsided feed.
//  Store reads run OFF the main actor (the ConstellationWindow rule).
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.8 (compiles +
//  mirrors the house window idioms; the rendered feel is ⌘R verify-owed).
//  Prior: none (new file).
//
//  Review: Kev + claude-fable-5, 2026-08-19, Confidence 0.85 — window →
//  destination promotion + the interaction timeline (visits foldered per
//  client via the new client_name capture). The fold is package-TDD'd;
//  this view is verify-at-⌘R.
//

import M1K3Heartbeat
import M1K3MCPLog
import SwiftUI

struct HeartbeatScreen: View {
    let env: AppEnvironment?

    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppEnvironment.heartbeatEnabledKey) private var heartbeatOn = false
    @AppStorage(AppEnvironment.conversationLogEnabledKey) private var agentLogOn = false
    @State private var days: [InteractionTimeline.Day] = []
    @State private var pulseCount = 0
    @State private var newestPulse: HeartbeatEntry?
    /// The structural filter (2026-08-30): chips over the timeline — only
    /// pulses where an agent visited, only the days something was learned.
    /// Shape, never content — see PulseTag.
    @State private var selectedTag: PulseTag?
    @State private var availableTags: [PulseTag] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .navigationTitle("Heartbeat")
        .task(id: refreshKey) { await refresh() }
    }

    /// Pulses AND captured calls both invalidate the timeline.
    private var refreshKey: [Int] {
        [env?.heartbeatRevision ?? 0, env?.mcpLogRevision ?? 0]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Heartbeat", systemImage: "waveform.path.ecg")
                    .symbolRenderingMode(.hierarchical)
                    .font(.pixelTitle)
                Text("\(pulseCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    Task { await clearPulses() }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(pulseCount == 0)
                .help("Clear every pulse (agent-call history is cleared in the Agent Log)")
            }
            // The honest-hold line: a stale latest pulse explains itself
            // (thermal / busy / quiet hours) instead of silently ageing.
            if let holdLine = currentHoldLine {
                Text(holdLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if heartbeatOn, !availableTags.isEmpty {
                tagChips
            }
        }
        .padding(16)
    }

    /// One chip per tag present in the loaded pulses; tap filters, tap again
    /// clears. A pulse filter only — agent visits keep their own rows in the
    /// Agent Log, and hiding them here would misread as deletion.
    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableTags, id: \.rawValue) { tag in
                    let isSelected = selectedTag == tag
                    Button {
                        selectedTag = isSelected ? nil : tag
                    } label: {
                        Text(tag.displayLabel)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? Color.accentColor : .secondary)
                    .help("Show only pulses tagged \(tag.displayLabel)")
                }
            }
        }
        .padding(.top, 4)
    }

    private var currentHoldLine: String? {
        // Only over real history: the no-pulses ContentUnavailableView
        // already explains the empty state (and the state starts empty before
        // the first store read — a hold line there would flash a wrong
        // claim, the PR #104 review catch).
        guard heartbeatOn, let newest = newestPulse else { return nil }
        let now = Date()
        return HeartbeatHoldLine.resolve(
            now: now,
            hour: Calendar.current.component(.hour, from: now),
            lastPulse: newest.createdAt,
            lastHold: env?.heartbeatLastHold
        )
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
        } else if days.isEmpty {
            ContentUnavailableView {
                Label("No pulses yet", systemImage: "waveform.path.ecg")
            } description: {
                Text("The first pulse lands within a couple of hours of the machine "
                    + "being awake — sooner if something's already happened today.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !agentLogOn {
                    agentCommsOffer
                }
                ForEach(filteredDays) { day in
                    Section {
                        ForEach(day.events) { event in
                            eventRow(event)
                        }
                    } header: {
                        Label(dayTitle(day.day), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// The consent, offered where it matters: without the Agent Interaction
    /// Log the timeline is silently pulse-only. Same key Settings → Advanced
    /// flips; the store self-gates live, no restart.
    private var agentCommsOffer: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Log agent conversations", isOn: $agentLogOn)
                Text("When the Agent Interaction Log is on, calls from connected agents "
                    + "fold into this timeline as visits — who called in, and what they "
                    + "used. Captured on this Mac only, newest 500 kept, off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    /// The timeline through the selected chip: pulses carrying the tag, days
    /// with none dropped. No selection = the whole timeline, visits included.
    private var filteredDays: [InteractionTimeline.Day] {
        guard let selectedTag else { return days }
        return days.compactMap { day in
            let pulses = day.events.filter { event in
                if case let .pulse(pulse) = event { return pulse.tags.contains(selectedTag) }
                return false
            }
            return pulses.isEmpty ? nil : InteractionTimeline.Day(day: day.day, events: pulses)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    @ViewBuilder
    private func eventRow(_ event: InteractionTimeline.Event) -> some View {
        switch event {
        case let .pulse(pulse):
            pulseRow(pulse)
        case let .visit(visit):
            visitRow(visit)
        }
    }

    private func pulseRow(_ pulse: HeartbeatEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(pulse.createdAt, format: .dateTime.hour().minute())
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

    /// A folded agent visit: summary line collapsed, per-call rows expanded.
    /// The full request/response transcript stays in the Agent Log window —
    /// the timeline carries shape (who, what tools, when), not payloads.
    private func visitRow(_ visit: InteractionTimeline.Visit) -> some View {
        DisclosureGroup {
            ForEach(visit.calls) { call in
                HStack {
                    Label(call.tool, systemImage: call.isError ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Spacer()
                    Text(call.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Button("Full transcript in the Agent Log") {
                openWindow(id: M1K3App.agentLogWindowID)
            }
            .font(.caption)
            .buttonStyle(.link)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .symbolRenderingMode(.hierarchical)
                    Text(visit.clientName ?? "An agent")
                        .font(.callout.bold())
                    Text("· \(visit.callCount) call\(visit.callCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if visit.errorCount > 0 {
                        Text("· \(visit.errorCount) error\(visit.errorCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(visitInterval(visit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(toolSummary(visit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func visitInterval(_ visit: InteractionTimeline.Visit) -> String {
        let start = visit.start.formatted(.dateTime.hour().minute())
        let end = visit.end.formatted(.dateTime.hour().minute())
        return start == end ? start : "\(start)–\(end)"
    }

    private func toolSummary(_ visit: InteractionTimeline.Visit) -> String {
        let counts = visit.toolCounts
        let shown = counts.prefix(3).map { count in
            count.count == 1 ? count.tool : "\(count.tool) ×\(count.count)"
        }
        let more = counts.count > 3 ? " · …" : ""
        return shown.joined(separator: " · ") + more
    }

    private func refresh() async {
        guard let env else { return }
        let pulseStore = env.heartbeatStore
        let logStore = env.conversationLog
        let (pulses, built) = await Task.detached(
            priority: .utility
        ) { () -> ([HeartbeatEntry], [InteractionTimeline.Day]) in
            let pulses = pulseStore.flatMap { (try? $0.recent()) } ?? []
            let calls = (logStore.flatMap { (try? $0.recent()) } ?? []).map { row in
                InteractionTimeline.AgentCall(
                    id: row.id, tool: row.tool, clientName: row.clientName,
                    isError: row.isError, timestamp: row.timestamp
                )
            }
            return (pulses, InteractionTimeline.build(pulses: pulses, calls: calls))
        }.value
        pulseCount = pulses.count
        newestPulse = pulses.first
        days = built
        availableTags = Set(pulses.flatMap(\.tags)).sorted()
        // A cleared or trimmed-away tag must not leave a phantom filter that
        // renders an empty timeline.
        if let selected = selectedTag, !availableTags.contains(selected) {
            selectedTag = nil
        }
    }

    private func clearPulses() async {
        guard let env, let store = env.heartbeatStore else { return }
        await Task.detached(priority: .utility) { try? store.clear() }.value
        env.heartbeatRevision += 1 // re-reads this screen + every other surface
    }
}
