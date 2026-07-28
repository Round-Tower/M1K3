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
//

import M1K3Avatar
import M1K3Chat
import M1K3Inference
import SwiftUI

struct ChatScreen: View {
    @Environment(AppCore.self) private var core
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var chatting: Bool {
        !core.chat.messages.isEmpty
    }

    /// The live avatar backdrop is on when chatting, unless the user opted out
    /// or asked the OS for Reduce Transparency (a layered live scene is exactly
    /// what that setting asks us not to do — the Mac's glass swap, same spirit).
    private var backdropActive: Bool {
        chatting && avatarBackdrop && !reduceTransparency
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
        .navigationTitle("M1K3")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

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
                AvatarSurface(controller: core.avatar)
                    .frame(height: 168)
                    .padding(.horizontal, 56)
                Text("M1K3")
                    .font(.pixel(28))
                    .kerning(2)
                    .foregroundStyle(.white)
                Text(brainSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                return userFixable
                    ? "Turn on Apple Intelligence in Settings — or pick Lil in Settings."
                    : "This device can't run Apple Intelligence — pick Lil in Settings."
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

    private var brainSubtitle: String {
        switch core.selectedBrain.backing {
        case .appleFoundationModels: "Apple Intelligence"
        case .mlx: core.selectedBrain.mlxModelID?.contains("Qwen") == true ? "MLX · Qwen3-4B" : "MLX · local"
        }
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
                                // Same gate as the input bar (see send()) — chips on
                                // EARLIER turns stay tappable while a new answer
                                // streams; ChatSession would silently drop the send
                                // and the avatar epilogue would bloom the backdrop
                                // over the streaming text.
                                guard !core.chat.isResponding, core.isReady else { return }
                                Task { await core.send(question) }
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("Ask me anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Grounded in your documents and memories — on device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            starterChips
        }
        .padding(.top, 28)
    }

    /// Starter prompts for the blank canvas — the same tap-to-send path (and the
    /// same `canSend` gate) as the reply follow-up chips, so a tap while the brain
    /// is still warming is a no-op rather than an eaten message. Dimmed until ready
    /// so the readiness hint in the hero reads as the reason.
    private var starterChips: some View {
        VStack(spacing: 8) {
            ForEach(Self.starters, id: \.self) { prompt in
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
        .frame(maxWidth: 340)
        .opacity(canSend ? 1 : 0.5)
        .padding(.top, 4)
    }

    private static let starters = [
        "What can you help me with?",
        "Explain something simply",
        "What do you remember about me?",
    ]

    private func sendStarter(_ prompt: String) {
        guard canSend else { return }
        Task { await core.send(prompt) }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask M1K3…", text: $draft, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .m1k3Glass(cornerRadius: 20)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !core.chat.isResponding
            && core.isReady
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
