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
//  Review: Kev + claude-opus-5.5, 2026-10-11 — in season (Halloween) one costume line under the wordmark
//  (SeasonalLook.greeting); opt-out in Settings ▸ Face. Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-5-5, 2026-10-14 — PhotosPicker beside the Files paperclip (#604): same
//  AttachmentStore path, gated on supportsImageInput. Confidence 0.8 (compile-verified; picking from
//  a real library is verify-by-launch).
//  Review: same day (2), #609 review — the picks land only if the brain still takes images after they load
//  (a brain switch mid-load discarded the pending set), and the picker caps pending images at 4.
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
//  Review: Kev + claude-opus-5-5, 2026-10-03 — the screengrab beat also pushes the plate's screen (`phoneRoute`:
//  Settings ▸ Documents / Memories) so App Preview footage needs no taps. Confidence 0.85 (verify-by-launch on the sim).
//  Review: Kev + claude-fable-5.1, 2026-10-09 — the navy gradient floor is the window's own field (`WindowField`,
//  shared with VoiceScreen; visionOS keeps the gradient there — challenger NO-GO on `Color.clear`); forced dark keeps
//  it near-black until light mode is allowed. Verify-by-launch.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (2) — the backdrop unmounts while the voice cover is presented (the cover
//  keeps this view mounted beneath it, so two RealityViews ran); VoiceScreen's full-bleed hero is the one.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (CI fold) — the costume line renders inline from
//  `SeasonalLook.greeting(for:)` (the shared SeasonalGreeting.swift is gone). Confidence 0.85.
//  Review: Kev + claude-opus-4-6, 2026-10-12 — PCC consent wiring: `privateCloudArming` state, `privateCloudPending`
//  sheet, `privateCloudControl`, `sendToPrivateCloud` helper, arming action in send(), PCC status task. The sheet
//  content extracted to `privateCloudConsentView` (the body's modifier chain hit the type-checker's limit).
//  Confidence 0.75 (compile-verified; verify-by-launch owed).
//  Review: Kev + claude-opus-4-6, 2026-10-12 — Three PCC fixes: (1) arming init reads
//  `selectedDefaultsKey` not the dead `privateCloudEnabledKey`; (2) `send()` defers draft clearing
//  until after PCC routing — `.askConsent` returns early so cancel/swipe-dismiss keeps the text;
//  consent `onSend` clears it; (3) arming persistence: `.onAppear` + `.onChange` handlers mirror
//  the Mac's `PersistingCloudPicker` (persist isOn/consent, reconcile on control changes).
//  Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-13 — the pick lives on `core.privateCloudArming` (AppCore
//  persists it) so Settings' brain list can arm it; nothing on iOS ever did, so the sheet never
//  opened. A cloud chip over the input bar says when the next message goes to PCC. Confidence 0.8.
//  Review: Kev + claude-fable-5.1, 2026-10-13 — #585 follow-ups: the send button no longer waits for the
//  local brain when the send goes to PCC (`PrivateCloudRung.sendReady`), and a send the core refuses
//  (`sendPrivateCloud` false) puts the draft back instead of dropping it. Confidence 0.8.
//  Review: Kev + claude-fable-5.1, 2026-10-13 (pre-push review fold) — `privateCloudServesNextSend` is false
//  in voice mode (the chip claimed PCC for a send that stayed local); a send the gate refuses goes LOCAL
//  before the draft is cleared (`privateCloudSendAllowed` is synchronous), like every other send PCC can't
//  honour — no draft juggling. Decline runs through `core.pickPrivateCloud(false)`. Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-13 — answers carry the Mac's row (MessageBubble): `rate(_:_:_:)` records into
//  the shared ChatSession store with the selected brain, and a first like counts toward the rating ask as on the
//  Mac; the speaker button reads aloud via `core.readAloud`. Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-12 — TestFlight 505, "Lil Waking seems to hang at 0%": the load row read
//  "Waking… Int(f*100)%" through the whole download (a started download under 1% read 0%). It reads the shared
//  `statusLine` (Downloading N% / <1%, then Waking), says to keep M1K3 open, and names a stall. Confidence 0.75.
//  Review: Kev + claude-opus-5.5, 2026-10-12 — while iOS carries the download, the line says the person can leave.
//  Review: Kev + claude-opus-5.5, 2026-10-12 — the Send button stops an auto-spoken answer too (`stoppable`).
//  Review: Kev + claude-opus-5.5, 2026-10-15 — doc only: `brainLoadRow`'s comment sits on it again (`stoppable` had
//  landed between them). Confidence 0.95.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — every image gate reads `core.imagesAccepted` (no image while Brain at
//  Home answers, which carries none) and one `onChange` discards queued images whenever that turns false; a refused
//  image names the answering brain. Confidence 0.75 (verify on the phone).
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — Offline AI Flight Club: the costume line also appears in Flight
//  Club's window while offline (`NetworkPathWatch.shared.isOffline`). Confidence 0.8 (verify on a device in Airplane Mode).
//  Review: Kev + claude-opus-5.5, 2026-10-27 — typed answer blocks (#717): a choices card is live on the newest
//  message only, while no turn responds (`acceptsChoices`), as on the Mac; an earlier or reloaded card stays
//  readable and never sends a stale option. Confidence 0.75 (verify on the phone).
//  Review: Kev + claude-opus-5.5, 2026-10-30 — Kev's iPhone round: the keyboard goes down on the gear or voice tap,
//  before the chat leaves (measured on his phone: composer 777 under the keyboard, 483 on top of it), and a failed
//  brain offers "Send a report" through the snag sheet. Confidence 0.8.

import M1K3Avatar
import M1K3Chat
import M1K3Inference
import M1K3LanguageModel
import M1K3Screengrab
import PhotosUI
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
    /// The screengrab harness's push (RootView's stack path); untouched otherwise.
    @Binding var screengrabPath: [ScreengrabRoute]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true
    @AppStorage(CompanionDefaults.companionKey) private var companion = CompanionDefaults.houseCompanion.id
    @AppStorage(CompanionDefaults.seasonalLooksKey) private var seasonalLooks = true
    @State private var draft = ""
    @State private var starters: [String] = []
    @State private var showAttachmentImporter = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var pendingFiles: [FileAttachment] = []
    @State private var attachmentError: String?
    @AppStorage(ChatEgressConsent.defaultsKey) private var privateCloudConsent = false
    @State private var privateCloudPending: PendingPrivateCloudSend?
    @AppStorage(PersistedAgeBandProvider.defaultsKey) private var ageBandRaw: String?
    @State private var brainFailureDraft: SnagDraft?
    @State private var showSettings = false
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

    /// The backdrop's RealityView is unmounted while the voice cover is up: the
    /// cover (VoiceScreen) carries its own full-bleed hero, and the cover does not
    /// unmount what is beneath it — ONE RealityView at a time.
    private var backdropMounted: Bool {
        backdropActive && core.voiceLoop == nil
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
                        inputFocused = false
                        core.enterVoiceMode()
                    } label: {
                        Label("Voice mode", systemImage: "waveform")
                    }
                    .disabled(!brainReady)
                    Button {
                        // Before the push, not after it: a keyboard that went down while the chat
                        // was leaving cost this screen its keyboard avoidance on the way back, on
                        // iOS 27.2, and the next one covered the composer (Kev, 10-30).
                        inputFocused = false
                        showSettings = true
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
                attachmentErrorMessage
            }
            .fileImporter(
                isPresented: $showAttachmentImporter,
                allowedContentTypes: AttachmentRouting.contentTypes(
                    imagesAccepted: core.imagesAccepted
                ),
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    attach(urls)
                }
            }
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task { await attachPhotos(items) }
            }
            // A blind brain, or Brain at Home (which carries no image), discards the queued images.
            .onChange(of: core.imagesAccepted) {
                if !core.imagesAccepted {
                    AttachmentStore.discard(pendingAttachments)
                    pendingAttachments = []
                }
            }
            .task(id: chatting) {
                if !chatting { reshuffleStarters() }
            }
            .onChange(of: core.reviewLedger.completedTurns) { _, _ in
                askForRatingIfEarned()
            }
            .task(id: brainReady) {
                guard brainReady, !voiceLaunched else { return }
                if Self.voiceAtLaunch {
                    voiceLaunched = true
                    core.enterVoiceMode()
                } else if ScreengrabHarness.current.isActive {
                    voiceLaunched = true
                    core.performScreengrabBeat()
                    screengrabPath = ScreengrabHarness.current.phoneRoute
                }
            }
            .navigationDestination(isPresented: $showSettings) { SettingsScreen() }
            .navigationDestination(for: ScreengrabRoute.self) { route in
                switch route {
                case .settings: SettingsScreen()
                case .documents: DocumentsScreen()
                case .memories: MemoriesScreen()
                case .pairing: BrainPairingScreen()
                }
            }
            .sheet(item: $brainFailureDraft) { draft in
                SnagReportSheet(draft: draft, onDone: { brainFailureDraft = nil })
            }
            .sheet(item: $privateCloudPending) { pending in
                privateCloudConsentView(pending)
            }
            .onAppear { core.privateCloudArming.controlChanged(privateCloudControl) }
            .onChange(of: privateCloudControl) { _, newValue in
                core.privateCloudArming.controlChanged(newValue)
            }
            .task { await core.refreshPrivateCloudStatus() }
    }

    private func privateCloudConsentView(_ pending: PendingPrivateCloudSend) -> some View {
        PrivateCloudConsentSheet(
            consent: pending.consent,
            onSend: { includeConversation in
                privateCloudPending = nil
                core.privateCloudArming.consented(
                    includeConversation: includeConversation, seen: pending.onDeviceShown
                )
                guard core.privateCloudSendAllowed() else { send(); return }
                clearDraft()
                sendToPrivateCloud(pending.consent, includeConversation: includeConversation)
            },
            onCancel: {
                privateCloudPending = nil
                core.pickPrivateCloud(false)
            }
        )
    }

    /// See the `.task(id: brainReady)` above — read once per process.
    private static let voiceAtLaunch = ProcessInfo.processInfo.environment["M1K3_VOICE_AT_LAUNCH"] == "1"

    /// A rating from an answer's row (MessageBubble): into the shared store the Mac
    /// uses, and, on the transition INTO liked, toward the rating ask (the Mac's rule:
    /// a re-tapped thumb is one opinion, not two).
    private func rate(_ message: ChatMessage, _ verdict: FeedbackVerdict, _ comment: String?) {
        let wasLiked = core.chat.feedbackVerdicts[message.id] == .good
        core.chat.recordFeedback(
            messageID: message.id, verdict: verdict, comment: comment, brain: core.answeringBrainName
        )
        if verdict == .good, !wasLiked {
            core.reviewLedger.recordDelight()
            askForRatingIfEarned()
        }
    }

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

    /// The base is the shared `WindowField` (the window's own `.background` on iOS,
    /// the deep gradient on visionOS) — the iOS counterpart of the Mac's behind-window
    /// glass, and the same floor VoiceScreen sits on. Once a conversation is underway the reactive avatar
    /// backdrop layers over it (ONE RealityView at a time — the hero hands off to the backdrop).
    private var backdrop: some View {
        ZStack {
            WindowField()
            if backdropMounted {
                ChatBackdrop(core: core, isComposing: isComposing)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: backdropMounted)
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
                // In season, M1K3 greets in costume (opt-out in Settings ▸ Face).
                if let line = SeasonalLook.greeting(for: SeasonalLook.now(enabled: seasonalLooks, offline: NetworkPathWatch.shared.isOffline)) {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .colorScheme(.dark)
                        .padding(.horizontal, 24)
                }
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
                if let shown = core.brainFailureShown,
                   AgeAppropriateness.fieldReportAllowed(for: AgeBand(persisted: ageBandRaw))
                {
                    Button("Send a report") {
                        Task { brainFailureDraft = await core.brainFailureDraft(shown: shown) }
                    }
                    .font(.caption)
                }
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

    /// The Send button's Stop face: while an answer generates, and while one is read aloud (chat auto-speak).
    private var stoppable: Bool {
        core.chat.isResponding || core.isSpeakingAnswer
    }

    /// "Downloading Lil… 3%" while the bytes come ("<1%" once they start, never a frozen "0%"), "Waking Lil…" for the
    /// load after them. While downloading, a line under the bar says to keep M1K3 open, and names a stall (TestFlight
    /// 505: "Lil Waking seems to hang at 0%"). The screen stays on meanwhile (RootView).
    private var brainLoadRow: some View {
        let name = core.selectedBrain.displayName
        return Group {
            if let fraction = core.brainLoad.fraction, fraction < 1 {
                VStack(spacing: 4) {
                    ProgressView(value: fraction) {
                        Text(core.brainLoad.statusLine(modelName: name))
                            .font(.caption2)
                    }
                    .frame(maxWidth: 240)
                    // A clock for the stall check only; the bar moves on its own.
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text(core.brainStall.isStalled(at: context.date)
                            ? "Still downloading. Keep M1K3 open and on Wi-Fi."
                            : core.brainDownloadContinues
                            ? "\(name) keeps downloading if you leave M1K3."
                            : "Keep M1K3 open while \(name) downloads.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(core.brainLoad.statusLine(modelName: name)).font(.caption2)
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
                            verdict: core.chat.feedbackVerdicts[message.id],
                            existingComment: core.chat.feedbackComments[message.id],
                            onFeedback: { verdict, comment in rate(message, verdict, comment) },
                            onSpeak: { core.readAloud($0) },
                            onSendFollowUp: { question in
                                // Same gate the starter chips use (brainReady) — chips
                                // carry their own prompt, so no draft dependency; chips
                                // on EARLIER turns stay tappable while a new answer
                                // streams (ChatSession would otherwise silently drop the
                                // send and the avatar epilogue would bloom the backdrop
                                // over the streaming text).
                                guard brainReady else { return }
                                Task { await core.send(question) }
                            },
                            acceptsChoices: message.id == core.chat.messages.last?.id && !core.chat.isResponding
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
            if privateCloudServesNextSend {
                Label(PrivateCloudLabel.text, systemImage: "cloud.fill")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 6)
                    .accessibilityLabel("Your next message goes to Apple's Private Cloud Compute")
            }
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

                    if core.imagesAccepted {
                        // Out of process: no photo-library prompt, no usage string.
                        PhotosPicker(
                            selection: $pickedPhotos,
                            maxSelectionCount: max(1, Self.photoLimit - pendingAttachments.count),
                            matching: .images
                        ) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(.plain)
                        .disabled(core.chat.isResponding || !core.isReady
                            || pendingAttachments.count >= Self.photoLimit)
                        .accessibilityLabel("Attach from Photos")
                    }

                    TextField("Ask M1K3…", text: $draft, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .focused($inputFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .m1k3Glass(cornerRadius: 22)
                        .onSubmit(send)

                    Button {
                        if stoppable { core.stopResponding() } else { send() }
                    } label: {
                        Image(systemName: stoppable ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(stoppable ? .red : .accentColor)
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.default, value: stoppable)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !stoppable)
                    .accessibilityLabel(core.chat.isResponding ? "Stop generating" : core.isSpeakingAnswer ? "Stop speaking" : "Send")
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
        !core.chat.isResponding
            && PrivateCloudRung.sendReady(localBrainReady: core.isReady, servesPrivateCloud: privateCloudServesNextSend)
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
        let hasAttachments = !pendingAttachments.isEmpty
        let onDevice = ChatSession.onDeviceMessageIDs(core.chat.messages)
        // Voice mode answers on-device (ADR 0010); typed sends in voice never go to PCC.
        let action: PrivateCloudArming.Action = core.voiceLoop != nil ? .local : core.privateCloudArming.action(
            control: privateCloudControl, hasAttachments: hasAttachments, onDeviceMessages: onDevice
        )
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingFiles.isEmpty {
            let fileContext = pendingFiles.map(\.contextBlock).joined(separator: "\n\n")
            text = text.isEmpty ? fileContext : fileContext + "\n\n" + text
        }
        switch action {
        case .askConsent:
            privateCloudPending = PendingPrivateCloudSend(
                consent: core.chat.privateCloudConsent(for: text), onDeviceShown: onDevice
            )
            return
        case let .sendDirect(includeConversation) where core.privateCloudSendAllowed():
            clearDraft()
            sendToPrivateCloud(core.chat.privateCloudConsent(for: text), includeConversation: includeConversation)
        case .sendDirect, .local:
            // A send PCC can't honour right now stays on this device, like an
            // attachment or an outage — never dropped.
            let images = pendingAttachments
            clearDraft()
            Task { await core.send(text, images: images) }
        }
    }

    private func clearDraft() {
        draft = ""
        pendingAttachments = []
        pendingFiles = []
        inputFocused = false
    }

    private var attachmentErrorMessage: Text {
        Text(attachmentError ?? "")
    }

    private var privateCloudControl: PrivateCloudRung.Control {
        PrivateCloudRung.control(core.privateCloudState(consent: privateCloudConsent))
    }

    /// Only when the next typed send really leaves: not with an image staged or PCC out.
    private var privateCloudServesNextSend: Bool {
        core.voiceLoop == nil && core.privateCloudArming.servesNextSend(
            control: privateCloudControl, hasAttachments: !pendingAttachments.isEmpty
        )
    }

    private func sendToPrivateCloud(_ consent: PrivateCloudTurn.Consent, includeConversation: Bool) {
        Task { await core.sendPrivateCloud(consent, includeConversation: includeConversation) }
    }

    // MARK: - Attachments

    /// The one attach button's landing: images to the vision path, the rest to
    /// file-as-context; every failed file is named (never a silent drop).
    private func attach(_ urls: [URL]) {
        let route = AttachmentRouting.route(urls, imagesAccepted: core.imagesAccepted)
        let refused = route.refusedImages.map {
            "\($0.lastPathComponent): \(core.answeringBrainName) can't see images"
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

    /// The Photos picker's landing: bytes in, a stored copy out, the same
    /// `ImageAttachment` the Files importer yields. Every failure is named.
    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        guard core.imagesAccepted else { return }
        var failures: [String] = []
        var stored: [ImageAttachment] = []
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    failures.append(String(localized: "A photo couldn't be read."))
                    continue
                }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension
                try stored.append(Self.attachmentStore.store(data: data, fileExtension: ext))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        // The brain can change while the picks load: a brain without image input
        // discards the pending set, so these must not land after it did.
        guard core.imagesAccepted else {
            AttachmentStore.discard(stored)
            return
        }
        pendingAttachments.append(contentsOf: stored)
        if !failures.isEmpty {
            attachmentError = failures.joined(separator: "\n")
        }
    }

    /// The Photos picker's ceiling on images pending in one message.
    private static let photoLimit = 4

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
