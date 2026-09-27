//
//  CallsView.swift
//  M1K3App
//
//  The calls drawer: import a transcript, browse the (encrypted-at-rest) call log,
//  read a call's summary + speaker-attributed transcript. Dumb glue over
//  AppEnvironment — all the work (parse → summarise → encrypt → index) lives in the
//  tested M1K3Calls package.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: claude-opus-4-8, 2026-06-21 — Record/Stop moved INTO this view (header +
//  empty state, routed through the tested CallRecordAction core) so recording lives
//  where calls live; was only in the main toolbar, hidden behind this sheet. Added a
//  live recording/transcribing banner with a ticking clock and the consent dialog.

import M1K3Calls
import SwiftUI
import UniformTypeIdentifiers

struct CallsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showImporter = false
    @State private var showConsentDialog = false
    @State private var selected: CallSession?
    /// Loaded once (and on count change) rather than decrypting the whole call log
    /// on every body re-render — the recording banner alone re-runs body often.
    @State private var calls: [CallSession] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if env.isRecording || env.isTranscribingCall { activityBanner }
            content
        }
        .task { calls = await env.calls() }
        .onChange(of: env.callCount) { _, _ in Task { calls = await env.calls() } }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await env.importCallTranscript(url: url) }
            }
        }
        .confirmationDialog("Record this call?", isPresented: $showConsentDialog, titleVisibility: .visible) {
            Button("Record once") { Task { await env.affirmConsentAndRecord(scope: .once) } }
            Button("Always allow") { Task { await env.affirmConsentAndRecord(scope: .remembered) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’re responsible for having consent from everyone on the call. "
                + "Recording is on-device only — audio never leaves this Mac.")
        }
        // Push, not a sheet: CallsView is a persistent sidebar destination now,
        // not a modal — a lone remaining sheet-of-a-non-modal-view would read
        // as an inconsistency. isPresented (not item:) deliberately — item:
        // requires Hashable, which would mean adding a conformance to
        // CallSession (M1K3Calls) that changes its equality semantics
        // app-wide for a purely-navigational need.
        .navigationDestination(isPresented: Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )) {
            if let selected { CallDetailView(call: selected) }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = env.lastCallStatus {
                HStack(spacing: 8) {
                    if env.isImportingCall { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Calls", systemImage: "phone.bubble")
                .symbolRenderingMode(.hierarchical)
                .font(.pixelTitle)
            Text("\(env.callCount)") // observable — re-renders the list after import/delete
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            recordButton
            Button {
                showImporter = true
            } label: {
                Label("Import transcript", systemImage: "doc.badge.plus")
            }
            .disabled(env.isImportingCall)
        }
        .padding(16)
    }

    /// Record / Stop — now lives WHERE calls live (it used to be only in the main
    /// toolbar, hidden behind this sheet). The action is resolved by the tested
    /// CallRecordAction core; first-time taps route through the consent dialog.
    private var recordButton: some View {
        Button(action: triggerRecordAction) {
            Label(env.isRecording ? "Stop" : "Record",
                  systemImage: env.isRecording ? "stop.circle.fill" : "record.circle")
                .contentTransition(.symbolEffect(.replace))
                .animation(.default, value: env.isRecording)
        }
        .tint(env.isRecording ? .red : nil)
        // Can't start a new recording mid-transcription (Stop only shows while
        // recording, when isTranscribingCall is false — so this never blocks Stop).
        .disabled(env.isTranscribingCall)
    }

    /// Route a record-control tap through the tested resolver: stop, start, or
    /// (first time) ask consent. Shared by the header button and the empty state.
    private func triggerRecordAction() {
        // Belt-and-braces: a tap that races the transcription window would otherwise
        // start a recording whose result is silently dropped by processRecording's
        // `guard !isTranscribingCall`.
        guard !env.isTranscribingCall else { return }
        switch CallRecordAction.resolve(isRecording: env.isRecording, isPreAuthorised: env.recordingPreAuthorised) {
        case .stop: Task { await env.stopRecording() }
        case .start: Task { await env.startRecording() }
        case .requestConsent: showConsentDialog = true
        }
    }

    /// Live indicator pinned under the header so a recording (or in-flight
    /// transcription) is visible whether the list is empty or full.
    private var activityBanner: some View {
        HStack(spacing: 8) {
            if env.isRecording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording")
                if let started = env.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(RecordingClock.label(seconds: Int(context.date.timeIntervalSince(started))))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else if env.isTranscribingCall {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if calls.isEmpty {
            ContentUnavailableView {
                Label("No calls yet", systemImage: "phone.bubble")
            } description: {
                Text("Tap Record to capture a call, or import a transcript (lines like "
                    + "“Speaker: …”). M1K3 summarises it, encrypts it at rest, and makes it "
                    + "searchable alongside your documents.")
            } actions: {
                Button(action: triggerRecordAction) {
                    Label("Record a call", systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .disabled(env.isTranscribingCall)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(calls) { call in
                    Button { selected = call } label: { CallRow(call: call) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { env.deleteCall(id: call.id) }
                        }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct CallRow: View {
    let call: CallSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(call.title).font(.body.weight(.medium))
                Spacer()
                Text(call.startedAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let gist = call.fullSummary?.overview ?? call.quickSummary?.overview, !gist.isEmpty {
                Text(gist).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("\(call.segments.count) lines").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

struct CallDetailView: View {
    let call: CallSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = call.fullSummary {
                    summarySection(summary)
                } else if let quick = call.quickSummary {
                    sectionCard("Summary") { Text(quick.overview) }
                }
                transcriptSection
            }
            .padding(16)
        }
        .navigationTitle(call.title)
    }

    private func summarySection(_ summary: CallSummary) -> some View {
        sectionCard("Summary") {
            VStack(alignment: .leading, spacing: 10) {
                if !summary.overview.isEmpty { Text(summary.overview) }
                if !summary.keyPoints.isEmpty {
                    bulletList("Key points", summary.keyPoints)
                }
                if !summary.actionItems.isEmpty {
                    bulletList("Action items", summary.actionItems)
                }
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(call.segments) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    if let speaker = segment.speaker {
                        Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                    Text(segment.text).font(.callout)
                }
            }
        }
    }

    private func bulletList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "circle.fill")
                    .labelStyle(BulletLabelStyle())
                    .font(.callout)
            }
        }
    }

    private func sectionCard(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // imageScale scales with Dynamic Type; a fixed point size did not.
            configuration.icon.imageScale(.small).foregroundStyle(.tint)
            configuration.title
        }
    }
}
