//
//  MenuBarPopover.swift
//  M1K3App
//
//  The rich `.menuBarExtraStyle(.window)` surface: ask M1K3 a question and get a
//  grounded answer without ever opening the main window, see which brain is live
//  and what it's doing, and flip the everyday toggles (voice / web / MCP). The
//  ask reuses the headless pipeline via `env.menuBarAsk` (dedicated responder,
//  120s deadline, canary) — never the chat responder. Degrades gracefully while
//  the environment is still waking. VERIFY-BY-LAUNCH (SwiftUI + MainActor glue).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.7, Prior: Unknown

import AppKit
import M1K3Avatar
import M1K3Calls
import M1K3Chat
import SwiftUI

struct MenuBarPopover: View {
    let env: AppEnvironment?

    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppEnvironment.webSearchEnabledKey) private var webSearchEnabled = true
    /// First-run gate mirror: the popover mustn't open a side-door conversation
    /// before HelloView has run (Mini-first makes readiness instant).
    @AppStorage(AppEnvironment.hasChosenBrainKey) private var hasChosenBrain = false
    @State private var question = ""
    @State private var showRecordConsent = false
    @FocusState private var askFocused: Bool

    var body: some View {
        ZStack {
            // The pet as the WHOLE hero: the companion fills the popover and
            // reacts — blooming at idle/speaking, receding while you type or
            // read — via the same TDD'd ChatBackdropTreatment the main chat
            // backdrop uses (scrim, reduce-motion, low-power, hit-testing
            // and VoiceOver-hidden all inherited).
            if let env, hasChosenBrain {
                AvatarChatBackground(env: env, isTyping: composing(env))
            }
            content
        }
        .frame(width: 320)
        .frame(minHeight: heroHeight)
        .glassBackdrop()
    }

    /// Room for the pet when it's on stage; automatic (compact) while waking
    /// or pre-hello, where there is no backdrop to give room to.
    private var heroHeight: CGFloat? {
        env != nil && hasChosenBrain ? 400 : nil
    }

    /// Recede the backdrop whenever legibility matters more than the pet:
    /// composing a question, or an ask in flight / an answer on screen.
    private func composing(_ env: AppEnvironment) -> Bool {
        if !question.isEmpty { return true }
        switch env.menuBarAsk.state {
        case .idle: return false
        case .asking, .answer, .failed: return true
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let env {
                header(env)
                Divider()
                // Under Mini-first the environment can be READY before the user
                // has ever said hello — without this guard the first conversation
                // could happen in the menu bar while the main window still shows
                // HelloView (and the guided first action never fires).
                if hasChosenBrain {
                    askSection(env)
                    Divider()
                    toggles(env)
                    Divider()
                } else {
                    Button {
                        openWindow(id: M1K3App.mainWindowID)
                        NSApp.activate()
                    } label: {
                        Label("Say hello in the main window first", systemImage: "hand.wave")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Divider()
                }
            } else {
                Label("Waking M1K3…", systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    // Only exists while the env is nil, so it cycles exactly
                    // while waking — honest motion for a state with no spinner.
                    .symbolEffect(.variableColor.iterative)
                Divider()
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
    }

    // MARK: Header — brain · runtime · live activity (the pet is the backdrop)

    private func header(_ env: AppEnvironment) -> some View {
        let treatment = env.avatar.state.activity.glyphTreatment(isRecording: env.isRecording)
        return HStack(spacing: 9) {
            Image(nsImage: MenuBarGlyphStyle.pixelM.image(pointSize: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text(env.selectedBrain.displayName).font(.pixelTitle)
                Text(Self.runtimeLabel(env.selectedRuntime))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            activityBadge(env, treatment: treatment)
        }
    }

    @ViewBuilder
    private func activityBadge(_ env: AppEnvironment, treatment: GlyphTreatment) -> some View {
        let active = env.avatar.state.activity != .idle || env.isRecording
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.glyphDot(treatment.dotColorName) : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            // statusLabel carries the same recording-wins precedence as the
            // dot colour — the old displayName read "Idle" beside a red dot.
            Text(env.avatar.state.activity.statusLabel(isRecording: env.isRecording))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Ask — headless grounded answer, no main window

    private func askSection(_ env: AppEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Ask M1K3…", text: $question)
                    .textFieldStyle(.plain)
                    .focused($askFocused)
                    .onSubmit { submit(env) }
                Button { submit(env) } label: { Image(systemName: "return") }
                    .buttonStyle(.glass)
                    .disabled(trimmed.isEmpty || env.menuBarAsk.isBusy)
                    .accessibilityLabel("Ask M1K3")
            }
            answerView(env)
        }
        .onAppear { askFocused = true }
    }

    @ViewBuilder
    private func answerView(_ env: AppEnvironment) -> some View {
        switch env.menuBarAsk.state {
        case .idle:
            EmptyView()
        case .asking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            }
        case let .answer(_, text):
            VStack(alignment: .leading, spacing: 8) {
                ScrollView { Text(text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                Button("Continue in chat →") { continueInChat(env) }
                    .buttonStyle(.glass).font(.caption)
            }
        case let .failed(_, message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Quick toggles

    private func toggles(_ env: AppEnvironment) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                BarToggle(title: "Voice", systemImage: "waveform", isOn: env.isVoiceModeActive) {
                    if env.isVoiceModeActive { env.exitVoiceMode() } else { env.enterVoiceMode() }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                BarToggle(title: "Web", systemImage: "globe", isOn: webSearchEnabled) {
                    webSearchEnabled.toggle()
                }
                BarToggle(title: "MCP", systemImage: "powerplug", isOn: env.mcpHost.isRunning) {
                    env.mcpHost.setEnabled(!env.mcpHost.isEnabled)
                }
                BarToggle(
                    title: env.isRecording ? "Stop" : "Record",
                    systemImage: env.isRecording ? "stop.circle.fill" : "record.circle",
                    isOn: env.isRecording,
                    tint: .red
                ) {
                    recordTapped(env)
                }
                .accessibilityLabel(env.isRecording ? "Stop recording" : "Record call")
            }
            if showRecordConsent {
                recordConsentRow(env)
            }
        }
    }

    /// Inline consent — a confirmationDialog inside a menu-bar window can
    /// silently fail to present (the Form/leaf-Button macOS trap), so the
    /// popover asks in place. Same scopes and copy as the chat toolbar.
    private func recordConsentRow(_ env: AppEnvironment) -> some View {
        HStack(spacing: 8) {
            Text("Record this call?").font(.caption)
            Spacer()
            Button("Once") {
                showRecordConsent = false
                Task { await env.affirmConsentAndRecord(scope: .once) }
            }
            Button("Always") {
                showRecordConsent = false
                Task { await env.affirmConsentAndRecord(scope: .remembered) }
            }
            Button("Cancel") { showRecordConsent = false }
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .buttonStyle(.glass)
    }

    private func recordTapped(_ env: AppEnvironment) {
        switch CallRecordAction.resolve(
            isRecording: env.isRecording,
            isPreAuthorised: env.recordingPreAuthorised
        ) {
        case .stop:
            Task { await env.stopRecording() }
        case .start:
            Task { await env.startRecording() }
        case .requestConsent:
            showRecordConsent = true
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Open M1K3") { openMainWindow() }
            Spacer()
            SettingsLink { Text("Settings") }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private var trimmed: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(_ env: AppEnvironment) {
        let query = trimmed
        guard !query.isEmpty else { return }
        Task { await env.menuBarAsk.ask(query) }
    }

    private func continueInChat(_ env: AppEnvironment) {
        let query = currentQuestion(env)
        openMainWindow()
        env.menuBarAsk.reset()
        question = ""
        guard !query.isEmpty else { return }
        // Belt-and-suspenders: reset() drops the ask's busy flag before send()
        // flips chat.isResponding, so re-check before kicking off the chat turn.
        Task {
            guard !env.chat.isResponding else { return }
            await env.send(query)
        }
    }

    /// The question tied to the current answer (so "Continue in chat" re-asks the
    /// right thing even if the text field was edited after the answer landed).
    private func currentQuestion(_ env: AppEnvironment) -> String {
        switch env.menuBarAsk.state {
        case let .answer(question, _), let .failed(question, _), let .asking(question):
            question
        case .idle:
            trimmed
        }
    }

    private func openMainWindow() {
        NSApplication.shared.activate()
        openWindow(id: M1K3App.mainWindowID)
    }

    private static func runtimeLabel(_ runtime: RuntimeOption) -> String {
        switch runtime {
        case .appleFoundationModels: "Apple on-device"
        case .mlxGemma: "MLX · local"
        }
    }
}

/// A compact glass pill for the toggle row: icon over label, accent when on.
private struct BarToggle: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    /// The on-state colour — accent for ordinary toggles, red for recording
    /// (matching the glyph treatment's recording-wins red).
    var tint: Color = .accentColor
    let action: () -> Void

    /// Scales with the user's chosen text size (relative to the label below it)
    /// instead of a fixed 15pt, so Larger Text lifts the glyph along with the
    /// caption rather than leaving it stranded tiny beside grown text.
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 15

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: iconSize, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isOn ? tint : Color.secondary)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .help(isOn ? "\(title): on" : "\(title): off")
    }
}
