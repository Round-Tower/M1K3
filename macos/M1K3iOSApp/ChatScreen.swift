//
//  ChatScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  The spine: a real grounded chat over the shared `ChatSession` pipeline
//  (streaming, RAG, native tool-calling, documents-first). The pixel-face avatar
//  is the hero when the conversation is empty and shrinks to a compact dock once
//  it's underway (the Mac's hero→dock evolution). Nothing here is a mock — every
//  answer runs the same `AgentRAGResponder` the Mac app ships.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8 (compile-verified;
//  on-device streaming feel is Phase-B verify-owed). Prior: Unknown.
//  Review: claude-fable-5, 2026-07-18 — the Mac-feel pass: once a conversation
//  is underway the avatar no longer shrinks to a dock — it becomes the
//  full-bleed reactive ChatBackdrop (bloom/recede via the shared, TDD'd
//  ChatBackdropTreatment), matching the Mac's background-avatar mode. Follow-up
//  chips are wired tap-to-send, and autoscroll now also fires when chips land
//  (they arrive at .complete without a text change).
//  Review: claude-fable-5, 2026-07-29/30 — chat-is-the-app pass: nav title
//  dropped, New-chat + voice-mode toolbar, starter chips gated on the new
//  `brainReady` (canSend's draft requirement silently ate chip taps), backdrop
//  handoff to companions/None. 07-30: voice-mode button reuses !brainReady
//  (PR #82 review DRY nit).
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut (Kev's diff): the brain subtitle under the wordmark
//  and the empty-state headline/tagline are gone; the chips carry the invitation. Dead brainSubtitle removed with it.
//
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — M1K3_VOICE_AT_LAUNCH harness switch (enter voice mode when the brain is
//  ready) so a phone on the desk can be driven from the Mac via devicectl; inert otherwise.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — starter chips are drawn per blank canvas (StarterPrompts: shuffled
//  pool + recent memories); the readiness hint names the real alternative on a device without Lil (Brain at Home).
//  Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — readiness hint uses `localFallbackPhrase` — never "pick Mini" while
//  Mini is the selected brain (PR #234 review 12). Confidence now 0.8.

import M1K3Avatar
import M1K3Chat
import M1K3Inference
import SwiftUI

struct ChatScreen: View {
    @Environment(AppCore.self) private var core
    @State private var voiceLaunched = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true
    @AppStorage(CompanionDefaults.companionKey) private var companion = ""
    @State private var draft = ""
    @State private var starters: [String] = []
    @FocusState private var inputFocused: Bool

    private var chatting: Bool {
        !core.chat.messages.isEmpty
    }

    /// The "None" companion choice: no hero face, no live backdrop.
    private var avatarHidden: Bool {
        CompanionDefaults.hidesAvatar(companion)
    }

    /// The live avatar backdrop is on when chatting, unless the user opted out
    /// (the Appearance toggle or the None companion) or asked the OS for Reduce
    /// Transparency (a layered live scene is exactly what that setting asks us
    /// not to do — the Mac's glass swap, same spirit).
    private var backdropActive: Bool {
        chatting && avatarBackdrop && !avatarHidden && !reduceTransparency
    }

    /// Composing — keyboard up or a draft in hand; recedes the backdrop avatar.
    private var isComposing: Bool {
        inputFocused || !draft.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            transcript
            inputBar
        }
        .background(backdrop)
        // No navigation title — the wordmark lives in the empty-state hero; once
        // chatting, the transcript owns the screen (2026-07-29, Kev's call).
        #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
        #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        core.chat.startNewConversation()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    // startNewConversation no-ops on an empty transcript or a turn
                    // in flight — disable so the button never reads as broken.
                    .disabled(core.chat.messages.isEmpty || core.chat.isResponding)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        core.enterVoiceMode()
                    } label: {
                        Label("Voice mode", systemImage: "waveform")
                    }
                    .disabled(!brainReady)
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { core.voiceLoop != nil },
                set: { active in if !active { core.exitVoiceMode() } }
            )) {
                VoiceScreen()
            }
            // Harness switch for device field tests driven from the Mac: a launch
            // environment of M1K3_VOICE_AT_LAUNCH=1 enters voice mode as soon as
            // the brain is ready — devicectl can pass an environment, but it
            // cannot tap. The Mac's SelfTest env keys are the precedent. Inert
            // for every ordinary launch.
            // Blank canvas (first appearance and every New chat) → new chips.
            .task(id: chatting) {
                if !chatting { reshuffleStarters() }
            }
            .task(id: brainReady) {
                guard brainReady, !voiceLaunched, Self.voiceAtLaunch else { return }
                voiceLaunched = true
                core.enterVoiceMode()
            }
    }

    /// See the `.task(id: brainReady)` above — read once per process.
    private static let voiceAtLaunch = ProcessInfo.processInfo.environment["M1K3_VOICE_AT_LAUNCH"] == "1"

    // MARK: - Backdrop

    /// The gradient base is the iOS stand-in for the Mac's behind-window glass;
    /// once a conversation is underway the reactive avatar backdrop layers over
    /// it (ONE RealityView at a time — the hero hands off to the backdrop).
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.11), .black],
                startPoint: .top, endPoint: .bottom
            )
            if backdropActive {
                ChatBackdrop(core: core, isComposing: isComposing)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: backdropActive)
    }

    // MARK: - Hero avatar

    /// The big pixel face owns the empty state; once chatting it hands off to
    /// the full-bleed ChatBackdrop instead of shrinking to a dock (the Mac's
    /// background-avatar mode, which reads far better on a phone). The load /
    /// readiness rows stay inline in both states.
    private var hero: some View {
        VStack(spacing: 6) {
            if !chatting {
                if !avatarHidden {
                    AvatarSurface(controller: core.avatar)
                        .frame(height: 168)
                        .padding(.horizontal, 56)
                }
                Text("M1K3")
                    .font(.pixel(28))
                    .kerning(2)
                    .foregroundStyle(.white)
            }
            if core.brainLoad.isActive {
                brainLoadRow
            } else if let hint = readinessHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.spring(duration: 0.45), value: chatting)
    }

    /// A short human-readable reason the brain can't answer right now — otherwise
    /// the send button is silently disabled with no cross-reference to Settings.
    private var readinessHint: String? {
        guard !core.isReady else { return nil }
        switch core.selectedBrain.backing {
        case .appleFoundationModels:
            switch core.miniAvailability {
            case .available: return nil
            case .notReady: return "Apple Intelligence is still downloading on this device…"
            case let .blocked(userFixable):
                let alternative = core.brainMenu.localFallbackPhrase(verb: "pick") ?? "pair with your Mac"
                return userFixable
                    ? "Turn on Apple Intelligence in Settings — or \(alternative) in Settings."
                    : "This device can't run Apple Intelligence — \(alternative) in Settings."
            }
        case .mlx:
            if case let .failed(message) = core.brainLoad { return message }
            return "\(core.selectedBrain.displayName) isn't ready yet."
        }
    }

    private var brainLoadRow: some View {
        Group {
            if let fraction = core.brainLoad.fraction {
                ProgressView(value: fraction) {
                    Text("Waking \(core.selectedBrain.displayName)… \(Int(fraction * 100))%")
                        .font(.caption2)
                }
                .frame(maxWidth: 240)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waking \(core.selectedBrain.displayName)…").font(.caption2)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if core.chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(core.chat.messages) { message in
                        MessageBubble(
                            message: message,
                            scrimmed: backdropActive,
                            onSendFollowUp: { question in
                                // Same gate the starter chips use (brainReady) — chips
                                // carry their own prompt, so no draft dependency; chips
                                // on EARLIER turns stay tappable while a new answer
                                // streams (ChatSession would otherwise silently drop the
                                // send and the avatar epilogue would bloom the backdrop
                                // over the streaming text).
                                guard brainReady else { return }
                                Task { await core.send(question) }
                            }
                        )
                        .id(message.id)
                    }
                }
                // Mac-parity bump (Kev's catch, 2026-07-22): flat assistant turns
                // had zero inset of their own, so headings/code blocks sat right
                // at the column edge.
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: core.chat.messages.last?.text) {
                scrollToLatest(proxy)
            }
            // Chips land at .complete WITHOUT a text change — scroll for them too.
            .onChange(of: core.chat.messages.last?.followUps) {
                scrollToLatest(proxy)
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if let last = core.chat.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    /// The blank canvas is just the starter chips — no headline, no tagline
    /// (Kev's cognitive-load cut, 2026-09-03: the chips already say "ask").
    private var emptyState: some View {
        starterChips
            .padding(.top, 32) // one number: was 28 on the wrapper + 4 on the chips
    }

    /// Starter prompts for the blank canvas — the same tap-to-send path (and the
    /// same `canSend` gate) as the reply follow-up chips, so a tap while the brain
    /// is still warming is a no-op rather than an eaten message. Dimmed until ready
    /// so the readiness hint in the hero reads as the reason.
    private var starterChips: some View {
        M1K3GlassGroup(spacing: 8) {
            starterChipStack
        }
        .frame(maxWidth: 340)
        // brainReady, NOT canSend: the chips live on the EMPTY canvas (draft == ""),
        // and canSend requires a non-empty draft — so canSend would dim them by
        // default and swallow every tap even when the brain is warm and ready.
        .opacity(brainReady ? 1 : 0.5)
    }

    private var starterChipStack: some View {
        VStack(spacing: 8) {
            ForEach(starters, id: \.self) { prompt in
                Button { sendStarter(prompt) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                        Text(prompt)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .m1k3Glass(cornerRadius: 14)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A fresh draw every time the canvas goes blank: a shuffle of the pool with
    /// up to two of the newest memories woven in (StarterPrompts, pure + tested).
    private func reshuffleStarters() {
        var rng = SystemRandomNumberGenerator()
        starters = StarterPrompts.pick(memoryTitles: core.recentMemoryTitles(), using: &rng)
    }

    private func sendStarter(_ prompt: String) {
        // The chip carries its own prompt, so gate on brain readiness only — NOT
        // canSend (which requires a non-empty draft the empty canvas never has). Same
        // gate the reply follow-up chips use.
        guard brainReady else { return }
        Task { await core.send(prompt) }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        // One glass container for the whole row — the Mac inputRow's pattern, so
        // the field's glass and any neighbouring chips render/blend as a group.
        M1K3GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Ask M1K3…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($inputFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .m1k3Glass(cornerRadius: 22)
                    .onSubmit(send)
                Button(action: send) {
                    if core.chat.isResponding {
                        ProgressView().frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        brainReady
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ready to send a prompt that DOESN'T come from the input bar (starter +
    /// follow-up chips carry their own text). No `draft` dependency — the difference
    /// that makes canSend wrong for the chips.
    private var brainReady: Bool {
        !core.chat.isResponding && core.isReady
    }

    private func send() {
        // Guard on the SAME condition the Button uses — otherwise a Return key while
        // the brain is warming or a prior answer is streaming would clear `draft` and
        // then no-op in core.send/ChatSession.send, silently eating the message.
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        inputFocused = false
        Task { await core.send(text) }
    }
}
