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
//  Review: Kev + claude-fable-5.1, 2026-09-06 (2) — the readiness slot shows the #237 download offer as a button
//  before the plain hint. Confidence now 0.8 (unverified on a blocked device).
//  Review: Kev + claude-fable-5.1, 2026-09-07 — the brain-ready task also fires the screengrab beat (voice mode + the spoken hero
//  line for the store plates); M1K3_VOICE_AT_LAUNCH keeps precedence. Inert without the harness env.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — the send button is Send while idle and Stop while streaming (the
//  spinner it replaces said "wait"; the stop says you don't have to). Confidence now 0.85 (device-owed).
//  Review: Kev + claude-fable-5.1, 2026-09-15 — the rating ask: every completed turn re-checks the ledger and this screen alone calls requestReview.
//  Review: Kev + claude-fable-5.1, 2026-09-15 (2) — the ask needs an active scene (local review fold).
//  Review: Kev + claude-opus-5-5, 2026-09-25 — the backdrop IS the hero (Kev: "minimal and coherent"): the full-screen
//  avatar runs on the blank canvas too and recedes once chatting — one RealityView from launch to answer, no hand-off.
//  The 168 pt box is only the fallback (backdrop off / Reduce Transparency). Starter chips move to the thumb, above
//  the input bar; four on regular width. Verify-by-launch on the A12 iPad (idle cost + chip legibility). Confidence 0.75.
//  Review: Kev + claude-opus-5-5, 2026-09-25 (2) — #411 review fold: the chips' fade needed its own transaction (a Group
//  with `.animation(value: chatting)`); hero's animation is scoped to hero, so they popped. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-09-26 — one paperclip + one picker replace the image/file pair (the Mac's
//  change, shared `AttachmentRouting`); an image a blind brain can't take is named. Confidence 0.8 (device-owed).

import M1K3Avatar
import M1K3Chat
import M1K3Inference
import M1K3Screengrab
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatScreen: View {
    @Environment(AppCore.self) private var core
    /// The App Store rating sheet — asked only when the ledger says the
    /// moment is earned (ReviewPromptPolicy); the system may still decline.
    @Environment(\.requestReview) private var requestReview
    /// The ask is consumed only in an active scene — never spend the
    /// version's one chance on a backgrounded app.
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceLaunched = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true
    @AppStorage(CompanionDefaults.companionKey) private var companion = ""
    @State private var draft = ""
    @State private var starters: [String] = []
    @State private var showAttachmentImporter = false
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var pendingFiles: [FileAttachment] = []
    @State private var attachmentError: String?
    @FocusState private var inputFocused: Bool

    private var chatting: Bool {
        !core.chat.messages.isEmpty
    }

    /// The "None" companion choice: no hero face, no live backdrop.
    private var avatarHidden: Bool {
        CompanionDefaults.hidesAvatar(companion)
    }

    /// The live avatar backdrop is the whole experience's one avatar: the
    /// full-screen hero on the blank canvas, receding behind the transcript once
    /// chatting (2026-09-25, Kev: "minimal and coherent") — one RealityView from
    /// launch to answer, no hand-off. Off only when the user opted out (the
    /// Appearance toggle or the None companion) or asked the OS for Reduce
    /// Transparency (a layered live scene is exactly what that setting asks us
    /// not to do — the Mac's glass swap, same spirit); the boxed hero stands in.
    private var backdropActive: Bool {
        avatarBackdrop && !avatarHidden && !reduceTransparency
    }

    /// Composing — keyboard up or a draft in hand; recedes the backdrop avatar.
    private var isComposing: Bool {
        inputFocused || !draft.isEmpty || !pendingAttachments.isEmpty || !pendingFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            transcript
            // The blank canvas's chips sit at the thumb, over the scrim — the
            // creature owns the screen above them. The Group carries the
            // transaction: hero's animation is scoped to hero, so without this
            // the chips pop instead of fading on the first send (#411 review).
            Group {
                if !chatting {
                    starterChips
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: chatting)
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
            .alert(
                "Attachment Error",
                isPresented: Binding(
                    get: { attachmentError != nil },
                    set: { if !$0 { attachmentError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(attachmentError ?? "")
            }
            // One picker for images and files; AttachmentRouting sorts them.
            .fileImporter(
                isPresented: $showAttachmentImporter,
                allowedContentTypes: AttachmentRouting.contentTypes(
                    imagesAccepted: core.selectedBrain.supportsImageInput
                ),
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    attach(urls)
                }
            }
            .onChange(of: core.selectedBrain) {
                if !core.selectedBrain.supportsImageInput {
                    AttachmentStore.discard(pendingAttachments)
                    pendingAttachments = []
                }
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
            // Every completed turn re-asks the ledger; it answers yes once per
            // version, and only once the app has lived here a few days.
            .onChange(of: core.reviewLedger.completedTurns) { _, _ in
                askForRatingIfEarned()
            }
            .task(id: brainReady) {
                guard brainReady, !voiceLaunched else { return }
                if Self.voiceAtLaunch {
                    voiceLaunched = true
                    core.enterVoiceMode()
                } else if ScreengrabHarness.current.isActive {
                    // The App Store screengrab suite's per-plate beat (AppCore+Screengrab).
                    voiceLaunched = true
                    core.performScreengrabBeat()
                }
            }
    }

    /// See the `.task(id: brainReady)` above — read once per process.
    private static let voiceAtLaunch = ProcessInfo.processInfo.environment["M1K3_VOICE_AT_LAUNCH"] == "1"

    /// The rating ask, consumed HERE and nowhere else — this is the screen
    /// that can show the sheet. A short beat after the answer lands so the
    /// dialog never arrives on the last token.
    private func askForRatingIfEarned() {
        guard scenePhase == .active, core.reviewLedger.consumePromptIfDue() else { return }
        // Marked asked before the beat on purpose (see ContentView on the Mac).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            requestReview()
        }
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

    /// The wordmark over the full-screen backdrop avatar (the hero IS the
    /// backdrop). Only when the backdrop is off does the boxed face stand in —
    /// never both: one RealityView at a time. The load / readiness rows stay
    /// inline in both states.
    private var hero: some View {
        VStack(spacing: 6) {
            if !chatting {
                if !avatarHidden, !backdropActive {
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
            } else if let offer = core.pendingBrainDownloadOffer, !core.isReady {
                // #237: the consent moment — says the size, downloads only on the tap.
                Button("Download \(offer.displayName) (one-time, ~\(offer.approxDownloadMB ?? 0) MB)") {
                    core.acceptPendingBrainDownloadOffer()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
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
    /// one recent memory woven in (StarterPrompts, pure + tested) — four on the
    /// iPad's regular width, three on a phone.
    private func reshuffleStarters() {
        var rng = SystemRandomNumberGenerator()
        starters = StarterPrompts.pick(
            memoryTitles: core.recentMemoryTitles(),
            count: horizontalSizeClass == .regular ? 4 : 3,
            using: &rng
        )
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
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                pendingImagesStrip
            }
            if !pendingFiles.isEmpty {
                pendingFilesStrip
            }
            M1K3GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button { showAttachmentImporter = true } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .disabled(core.chat.isResponding || !core.isReady)
                    .accessibilityLabel("Attach")

                    TextField("Ask M1K3…", text: $draft, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .focused($inputFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .m1k3Glass(cornerRadius: 22)
                        .onSubmit(send)

                    Button {
                        if core.chat.isResponding { core.stopResponding() } else { send() }
                    } label: {
                        Image(systemName: core.chat.isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(core.chat.isResponding ? .red : .accentColor)
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.default, value: core.chat.isResponding)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !core.chat.isResponding)
                    .accessibilityLabel(core.chat.isResponding ? "Stop generating" : "Send")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var pendingImagesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments, id: \.url) { attachment in
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: attachment.url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 8))

                        Button {
                            AttachmentStore.discard([attachment])
                            pendingAttachments.removeAll { $0 == attachment }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var pendingFilesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingFiles) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                        Text(file.filename)
                            .font(.caption2)
                            .lineLimit(1)
                        Button {
                            pendingFiles.removeAll { $0 == file }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(file.filename)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
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
        guard canSend else { return }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingFiles.isEmpty {
            let fileContext = pendingFiles.map(\.contextBlock).joined(separator: "\n\n")
            text = text.isEmpty ? fileContext : fileContext + "\n\n" + text
        }
        let images = pendingAttachments
        draft = ""
        pendingAttachments = []
        pendingFiles = []
        inputFocused = false
        Task { await core.send(text, images: images) }
    }

    // MARK: - Attachments

    /// The one attach button's landing: images to the vision path, the rest to
    /// file-as-context; every failed file is named (never a silent drop).
    private func attach(_ urls: [URL]) {
        let route = AttachmentRouting.route(urls, imagesAccepted: core.selectedBrain.supportsImageInput)
        let refused = route.refusedImages.map {
            "\($0.lastPathComponent): \(core.selectedBrain.displayName) can't see images"
        }
        let failures = refused + attachImages(at: route.images) + attachFiles(at: route.files)
        if !failures.isEmpty {
            attachmentError = failures.joined(separator: "\n")
        }
    }

    private func attachImages(at urls: [URL]) -> [String] {
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try pendingAttachments.append(Self.attachmentStore.store(originalURL: url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func attachFiles(at urls: [URL]) -> [String] {
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let attachment = try FileTextExtractor.extract(from: url)
                pendingFiles.append(attachment)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private static let attachmentStore = AttachmentStore(
        directory: ScreengrabHarness.current.dataRoot(
            live: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        ).appendingPathComponent("attachments")
    )
}
