//
//  ContentView.swift
//  M1K3App
//
//  The chat surface: a streaming transcript grounded in the user's own knowledge,
//  a Liquid Glass input bar, drop-to-ingest, and a settings sheet for the runtime
//  picker. The view is intentionally dumb — it reads `env.chat.messages` and calls
//  package methods; all the stateful folding lives in the tested ChatSession.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-11 — voice-first mode: full-window body
//  swap to VoiceModeView, toolbar entry + ⌘⇧V, chat actions hidden while active.
//  Confidence 0.8.
//  Review: Kev + claude-opus-4-8, 2026-06-21 — voice-first MERGED into the chat:
//  the full-window body-swap is replaced by a bottom VoiceDock overlay
//  (safeAreaInset) over the still-visible transcript. The top avatar yields to the
//  dock's face, the input bar hides under voice, follow-latest pauses (scroll-back),
//  and chat actions stay reachable. Confidence 0.75 (layout/feel verify-at-⌘R).
//  Review: Kev + claude-opus-4-8, 2026-06-26 — the 06-21 dock was a regression in
//  use (avatar shrank to a 92pt corner card). Reverted to a FULL-WINDOW voice hero
//  (VoiceModeView) mounted as a full-window overlay: the avatar fills the window,
//  karaoke + controls float on glass. Confidence 0.75 (look verify-at-⌘R).

import M1K3Avatar
import M1K3Chat
import M1K3Inference
import M1K3Preview
import M1K3Voice
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    /// Which sidebar destination is showing. `.conversation(_)` is transient —
    /// picking a past conversation switches to it and snaps back to `.chat`
    /// (see the onChange in `body`). Not persisted: every launch opens on
    /// `.chat`, matching the app's existing "chat is the front door" rule.
    @State private var sidebarSelection: SidebarSelection? = .chat
    /// Sidebar column visibility, bridged to NavigationSplitViewVisibility
    /// (not directly UserDefaults-storable) — same persisted-Bool shape as
    /// `avatarDisplay` below.
    @AppStorage(AppEnvironment.sidebarVisibleKey) private var sidebarVisible = true
    /// The width-driven TRANSIENT sidebar state (auto-collapse on a narrow
    /// window); `sidebarVisible` above stays the user's persisted preference.
    /// **Optional, seeded nil**: until the first width-driven flip actually
    /// lands, `effectiveSidebarVisible` reads the persisted preference. A
    /// non-optional `true` seed made a persisted-HIDDEN sidebar render open
    /// then animate shut on every wide launch — the handoff read the stale
    /// seed the instant `windowWidth` became non-nil, before the deferred
    /// correction ran (2026-07-25 review finding).
    @State private var sidebarShown: Bool?
    /// Last observed window width — nil until the first layout pass.
    @State private var windowWidth: CGFloat?
    @State private var showImporter = false
    @State private var showAttachmentImporter = false
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var attachmentError: String?
    @State private var showConsentDialog = false
    @State private var isDropTargeted = false
    /// Set by the intro card's "Introduce yourself" — the floor is theirs.
    @FocusState private var inputFocused: Bool
    @AppStorage(AppEnvironment.avatarDisplayKey) private var avatarDisplay = AvatarDisplay.panel
    /// Auto-route on → M1K3 picks the brain → a manual toolbar pick would snap back
    /// next turn, so the switcher disables itself. Reactive so toggling Auto-route in
    /// Settings updates the chat toolbar live.
    @AppStorage(AppEnvironment.autoRouteBrainKey) private var autoRouteBrain = false
    /// First completed turn ever — flips the GreetingCard from the full
    /// first-session greeting to the quiet returning-user variant (a veteran's
    /// every new conversation must not replay "Nice to meet you").
    @AppStorage("greeting.firstTurnDone") private var greetingFirstTurnDone = false
    /// Voice mode's toolbar button stays LABELED ("Voice mode", not icon-only)
    /// until the first entry — the headline feature must not hide behind an
    /// unlabeled wave glyph for someone who's never found it.
    @AppStorage(AppEnvironment.hasEnteredVoiceModeKey) private var hasEnteredVoiceMode = false

    /// Readable measure for the chat column on large windows: transcript and
    /// input bar cap at this width and centre, instead of stretching edge to
    /// edge (~90+ chars/line reads badly, and worse in the dyslexia modes).
    private static let chatContentMaxWidth: CGFloat = 760

    /// Bridges the persisted preference + the width-driven transient state to
    /// NavigationSplitView's own visibility type. The 07-14 comment here
    /// claimed `.automatic` gives native narrow-window auto-collapse — it
    /// doesn't on macOS (that's iPhone/iPad size-class behaviour; a 560pt Mac
    /// window kept the sidebar pinned and clipped the labels), so the collapse
    /// is now hand-rolled via `SidebarAutoCollapse` (M1K3Preview, unit-pinned):
    /// crossing below the threshold collapses TRANSIENTLY (`sidebarShown`),
    /// crossing back restores the persisted preference (`sidebarVisible`), and
    /// explicit writes only persist while wide — a narrow-width `.detailOnly`
    /// echo must not clobber the user's real preference.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { effectiveSidebarVisible ? .automatic : .detailOnly },
            set: { setSidebar(visible: $0 != .detailOnly) }
        )
    }

    /// The persisted preference rules until the first width-driven flip seeds
    /// the transient state — so a persisted-hidden sidebar never flashes open
    /// while the deferred correction is in flight.
    private var effectiveSidebarVisible: Bool {
        sidebarShown ?? sidebarVisible
    }

    /// One write path for BOTH the binding's set and the toolbar toggle, so
    /// the transient/persisted split can't drift between them.
    private func setSidebar(visible: Bool) {
        sidebarShown = visible
        if SidebarAutoCollapse.persistsPreference(atWidth: windowWidth) {
            sidebarVisible = visible
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            switch sidebarSelection {
            case .documents:
                NavigationStack { DocumentsView() }
            case .memories:
                NavigationStack { MemoriesView() }
            case .calls:
                NavigationStack { CallsView() }
            default:
                // .chat, the transient .conversation(_) (see onChange below),
                // and nil all read as chat.
                chatDetail
            }
        }
        // A conversation row is a PICK, not a destination to linger on —
        // switch to it and immediately return the selection to .chat so the
        // sidebar highlight settles on "Chat", matching what's now showing.
        .onChange(of: sidebarSelection) { _, newValue in
            if case let .conversation(id) = newValue {
                env.chat.switchTo(id)
                sidebarSelection = .chat
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        // The hand-rolled narrow-window auto-collapse (see columnVisibility's
        // comment): edge-triggered on threshold CROSSINGS only, so a manual
        // re-open on a narrow window survives further resizing within the band.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            let firstLayout = windowWidth == nil
            let change = SidebarAutoCollapse.transition(
                from: windowWidth, to: newWidth, preferredVisible: sidebarVisible
            )
            windowWidth = newWidth
            guard let change else { return }
            if firstLayout {
                // First layout has no established NavigationSplitView tiling to
                // re-enter, so seed the transient state SYNCHRONOUSLY (matching
                // the preference already showing) — no animation, no flash, and
                // not the re-entrant re-tile the deferral below guards against.
                sidebarShown = change
                return
            }
            // Defer the column flip OUT of the layout pass this callback runs
            // in: toggling NavigationSplitView visibility re-tiles the
            // titlebar/sidebar (NSThemeFrame), and doing that re-entrantly
            // inside AppKit's display cycle is the NSGenericException
            // crash class caught on 07-25 (twice, EXC_BREAKPOINT via
            // _crashOnException during _updateSidebarPositionIfNeeded).
            Task { @MainActor in
                withAnimation(.snappy) { sidebarShown = change }
            }
        }
        // Voice-first as a FULL-WINDOW hero: the avatar fills the window with the
        // karaoke line + controls floating on glass, covering the chat while
        // active (the chat answer still lands in the transcript underneath). This
        // replaced the 06-21 bottom dock — Kev wanted the face full screen, not a
        // 92pt corner card. Mounted as an overlay (not a body-swap) so the toolbar
        // chrome stays reachable and the transition is a clean fade.
        .overlay {
            if env.isVoiceModeActive {
                VoiceModeView()
                    // Grow open from where the panel sat (top-anchored) instead of a
                    // flat cross-fade — the felt "hero zoom" without matchedGeometry's
                    // empty-frame trap: the hero is a FRESH RealityView that rebuilds
                    // its scene, so a matched-frame morph would zoom an empty rect and
                    // pop the face in after. A plain scale+opacity spring is robust
                    // (no namespace, no two-scenes), and the opacity masks the scene
                    // build during the grow. Collapses back on exit.
                    .transition(.scale(scale: 0.88, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: env.isVoiceModeActive)
        .background {
            // Ambient drifting orbs while capturing audio (recording / dictation)
            // or throughout voice-first mode, fading in over the glass. Sits
            // above the window glass, behind content. Global (not chat-scoped):
            // a call recording can be started from CallsView too, and stays in
            // flight while browsing elsewhere.
            if showsAmbientBackdrop {
                AudioCaptureBackdrop().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: showsAmbientBackdrop)
        .glassBackdrop()
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                Task { await env.ingest(url: url) }
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { DropHintView() } }
        .toolbar { toolbarContent }
        // A trailing side panel for quick review of links and files, beside the
        // conversation. Native macOS inspector — resizable, collapsible chrome.
        // State lives in env.review so chat-chips / MCP / the agent can drive it.
        .inspector(isPresented: Binding(
            get: { env.review.isPresented },
            set: { env.review.isPresented = $0 }
        )) {
            ReviewPanel(review: env.review)
                .inspectorColumnWidth(min: 320, ideal: 420, max: 720)
                // Fill the inspector to the WINDOW top: under .hiddenTitleBar the
                // column otherwise insets below the toolbar strip and the window
                // background shows as a black band above the panel.
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// The chat surface: avatar + transcript + input, plus everything only
    /// meaningful while actively chatting (the readiness gate, the fading top
    /// scrim, the avatar backdrop, top banners, the record-call consent
    /// dialog, image-attach/document importers). Extracted so the
    /// NavigationSplitView's other three destinations (Documents/Memories/
    /// Calls) don't inherit chat-only chrome.
    private var chatDetail: some View {
        VStack(spacing: 0) {
            avatarPanel
            transcript
                // Bottom chrome rides a safeAreaInset (not a VStack sibling) so
                // the transcript SCROLLS UNDER the bar and its material blurs
                // real content — the macOS bar idiom, matching the toolbar's
                // material above. followLatest's .bottom anchor automatically
                // lands above the inset.
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
        }
        .animation(.spring(duration: 0.35), value: showsBrainUpgradeNudge)
        .animation(.spring(duration: 0.35), value: avatarDisplay)
        // 480 to MATCH the window's own minWidth — the old 600 exceeded it, so
        // a 480-560pt window clipped the detail (the download bar overflowed
        // the window edge in Kev's 07-25 screenshots). The transcript/input
        // column is cap-and-centre (chatContentMaxWidth), so it degrades fine.
        .frame(minWidth: 480, minHeight: 520)
        // Readiness gate, narrowed 2026-07-25: the full blocking surface only
        // mounts when NOTHING can serve a turn (.blocked). While the selected
        // brain's weights download WITH Mini available, the gate is `.interim`
        // — Mini answers (InterimBrainPolicy routes the façade) and a slim
        // banner over the transcript carries the progress instead of a wall.
        // Turns still can't fire against still-downloading weights: the façade
        // override routes them to AFM until `modelLoad == .ready`.
        .overlay {
            if env.chatGate == .blocked {
                ModelGateView(
                    readiness: env.readiness,
                    brainName: env.downloadingBrainName,
                    switchToLil: env.isBrainDownloaded(.lil) && env.selectedBrain == .mini
                        ? { env.selectBrain(.lil) }
                        : nil
                ) { Task { await env.warmUpSelectedBrainOnLaunch() } }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: env.chatGate)
        // Warm the restored brain on launch so readiness can reach .ready without
        // the user firing the first turn (init's direct assignment skips the
        // didSet that would otherwise kick the load). Idempotent.
        .task { await env.warmUpSelectedBrainOnLaunch() }
        .background {
            // Opt-in: the avatar as a full-window backdrop behind the glass
            // bubbles. Standard chat mode only — voice mode has its own hero. It
            // recedes reactively while you read/type so text stays legible.
            if avatarDisplay == .background, !env.isVoiceModeActive {
                AvatarChatBackground(env: env, isTyping: !draft.isEmpty)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: avatarDisplay)
        // Faded top chrome, mirroring the bottom bar: a gradient-masked
        // material scrim over the titlebar region that dissolves downward —
        // no hard system band (toolbarBackground can't fade; this overlay
        // is the counterpart to bottomChrome's masked material). Hidden in
        // voice mode so the full-window hero keeps its clean edges.
        .overlay(alignment: .top) {
            if !env.isVoiceModeActive {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: 96)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black.opacity(0.6), location: 0.55),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        // The interim banner mounts AFTER the top scrim so it rides ABOVE the
        // fog band, not inside it — a later .overlay draws on top (2026-07-25
        // review finding: the banner was being drawn under the 96pt scrim).
        .overlay(alignment: .top) {
            if env.chatGate == .interim {
                InterimMiniBanner(load: env.modelLoad, brainName: env.downloadingBrainName)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .plainText, .text, .rtf],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                for url in urls {
                    Task { await env.ingest(url: url) }
                }
            }
        }
        .alert(
            "Couldn't attach image",
            isPresented: Binding(
                get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
        .fileImporter(
            isPresented: $showAttachmentImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                attachImages(at: urls)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The mic/speech recovery outranks ingest status — it's the only
            // way back from a denied grant (which used to fail silently).
            if let recovery = env.voicePermissionRecovery {
                VoicePermissionBanner(
                    recovery: recovery,
                    onOpenSettings: { env.openVoicePermissionSettings() },
                    onDismiss: { env.voicePermissionRecovery = nil }
                )
            }
            // The M1K3 Voice earned moment — raised only on LEAVING voice mode,
            // after the user has actually heard the everyday voice.
            else if env.voiceUpgradeOffered {
                VoiceUpgradeBanner(
                    onAccept: { env.acceptVoiceUpgrade() },
                    onDismiss: { env.dismissVoiceUpgrade() }
                )
            }
            // The swap toast ("Lil's awake") rides the same banner slot with
            // its own glyph.
            else if let notice = env.brainUpgradeNotice {
                IngestBanner(text: notice, busy: false, icon: "sparkles", iconColor: .accentColor)
            }
            // Suppressed while the GreetingCard is up — its hero zone shows the
            // same busy/indexed beat where the user is actually looking; two
            // simultaneous "Indexed" surfaces is noise. FAILURES pierce the
            // suppression: the card has no failure state, so without this a
            // failed drop would be silent (or revert to a stale "Got it").
            else if let status = env.lastIngestStatus,
                    !greetingCardVisible || env.lastIngestFailed
            {
                IngestBanner(text: status, busy: env.isIngesting)
            }
        }
        // The first completed turn retires the full first-session greeting.
        .onChange(of: env.chat.messages.isEmpty) { _, isEmpty in
            if !isEmpty { greetingFirstTurnDone = true }
        }
    }

    /// One flag for both consumers (card mount + banner suppression) so the
    /// conditions can't drift apart.
    private var greetingCardVisible: Bool {
        env.chat.messages.isEmpty
    }

    /// The nudge shows for a fresh offer AND for the rarer "Lil's already on
    /// disk but you're on Mini" one-tap switch (staged without this-session
    /// consent — e.g. downloaded once via the picker, then switched back).
    private var showsBrainUpgradeNudge: Bool {
        env.brainUpgrade == .offered || env.brainUpgrade == .staged(consented: false)
    }

    // MARK: - Avatar panel

    @ViewBuilder
    private var avatarPanel: some View {
        // The top panel yields to the voice dock's own avatar while voice is active
        // — one face on screen, never two.
        if avatarDisplay == .panel, !env.isVoiceModeActive {
            AvatarSurface(env: env)
                .frame(height: 200)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                // The hero, not decoration — a labeled image element (not hidden)
                // whose label tracks the same activity the visuals animate, so
                // VoiceOver hears "M1K3 — Thinking" etc. as the state changes.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(env.avatar.state.activity.accessibilityLabel)
                .accessibilityAddTraits([.isImage, .updatesFrequently])
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if env.chat.messages.isEmpty {
            VStack {
                Spacer()
                GreetingCard(
                    userName: UserDefaults.standard.string(forKey: AppEnvironment.userDisplayNameKey),
                    isFirstSession: !greetingFirstTurnDone,
                    isIngesting: env.isIngesting,
                    lastIngestedTitle: env.lastIngestedTitle,
                    onImport: { showImporter = true },
                    onSend: { text in Task { await env.send(text) } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(env.chat.messages, id: \.id) { message in
                            MessageView(
                                message: message,
                                onSpeak: { text in Task { await env.speak(text) } },
                                onOpenLink: { url in env.review.open(url: url) },
                                onSendFollowUp: { text in Task { await env.send(text) } },
                                contextWindow: env.selectedBrain.approximateContextTokens
                            )
                            .id(message.id)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: Self.chatContentMaxWidth)
                    .frame(maxWidth: .infinity) // centre the capped column
                }
                .onChange(of: env.chat.messages.last?.text) { followLatest(proxy) }
                // Follow the live reasoning too — during the think phase `text` is
                // empty, so without this the auto-expanded reasoning grows off the
                // bottom edge. Throttled upstream (~20Hz), so the follow eases.
                .onChange(of: env.chat.messages.last?.reasoning) { followLatest(proxy) }
            }
        }
    }

    // MARK: - Input

    /// The bottom bar band: earned-offer cards + the input row on one shared
    /// material, so the transcript blurs through as it scrolls beneath (the
    /// counterpart to the toolbar's material). Empty in voice mode — zero
    /// height, no band.
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            // The upgrade encore — after the first whoa, never before or during
            // (BrainUpgradePolicy gates the offer to between-turns moments).
            if showsBrainUpgradeNudge, !env.isVoiceModeActive, let target = env.brainUpgradeTarget {
                BrainUpgradeNudgeCard(
                    target: target,
                    currentBrainName: env.selectedBrain.displayName,
                    isStagedSwitch: env.brainUpgrade == .staged(consented: false),
                    isReOffer: env.brainUpgradeIsReOffer,
                    onAccept: { env.acceptBrainUpgrade() },
                    onDismiss: { env.dismissBrainUpgrade() }
                )
                .frame(maxWidth: Self.chatContentMaxWidth)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // The intro invitation shares the ONE bottom earned-offer slot —
            // the brain nudge outranks it (coordinator guarantees they never
            // both raise; this else-if is the belt to that suspender).
            else if env.introductionOffered, !env.isVoiceModeActive {
                IntroductionOfferCard(
                    onAccept: {
                        env.acceptIntroductionOffer()
                        inputFocused = true
                    },
                    onDismiss: { env.dismissIntroductionOffer() }
                )
                .frame(maxWidth: Self.chatContentMaxWidth)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // The input bar hides while voice owns the conversation — the dock
            // below IS the bottom chrome then, so there's no typed-vs-spoken clash.
            if !env.isVoiceModeActive {
                inputBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background {
            // Faded bar: the material dissolves upward through a gradient mask
            // (with a little bleed above the band) instead of cutting a hard
            // edge — messages melt into the blur as they scroll beneath.
            Rectangle()
                .fill(.ultraThinMaterial)
                .padding(.top, -28)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.6), location: 0.25),
                            .init(color: .black, location: 0.5),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                pendingAttachmentsStrip
            }
            inputRow
        }
    }

    /// Thumbnails of images staged for the next send, each removable. Only
    /// reachable on a vision-capable brain (the attach button gates), and
    /// cleared if the brain switches to one that can't see.
    private var pendingAttachmentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments, id: \.url) { attachment in
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: attachment.url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            pendingAttachments.removeAll { $0 == attachment }
                            // The staged copy is ours — removing the chip
                            // removes the file (privacy: nothing lingers).
                            AttachmentStore.discard([attachment])
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .accessibilityLabel("Remove attachment")
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: Self.chatContentMaxWidth)
        .frame(maxWidth: .infinity)
        .onChange(of: env.selectedBrain) {
            if !env.selectedBrain.supportsImageInput {
                AttachmentStore.discard(pendingAttachments)
                pendingAttachments = []
            }
        }
    }

    private var inputRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if env.isListening {
                    Text(env.liveTranscript.isEmpty ? "Listening…" : env.liveTranscript)
                        .foregroundStyle(env.liveTranscript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1 ... 5)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                } else {
                    TextField("Ask M1K3…", text: $draft, axis: .vertical)
                        .focused($inputFocused)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 5)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .onSubmit(send)
                }

                if env.selectedBrain.supportsImageInput {
                    Button { showAttachmentImporter = true } label: {
                        Image(systemName: "photo.badge.plus")
                            .imageScale(.large)
                            .fontWeight(.semibold)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(env.chat.isResponding || !env.isReady)
                    .help("Attach an image — Big can see it")
                    .accessibilityLabel("Attach image")
                }

                // New chat lives in the sidebar now (its toolbar pencil +
                // ⌘N) — a second identical pencil here was pure duplication
                // once the sidebar owned conversation lifecycle.
                if env.isListening {
                    // The bail-out: discard the dictation WITHOUT sending. The
                    // mic stays tap-to-send (muscle memory); this is the exit
                    // that never existed when the take goes wrong. Escape works.
                    Button { env.cancelDictation() } label: {
                        Image(systemName: "xmark")
                            .imageScale(.large)
                            .fontWeight(.semibold)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    .help("Discard dictation — nothing is sent")
                    .accessibilityLabel("Discard dictation")
                    .accessibilityHint("Stops listening without sending")
                    .transition(.scale.combined(with: .opacity))
                }

                Button { env.toggleDictation() } label: {
                    Image(systemName: env.isListening ? "mic.fill" : "mic")
                        .imageScale(.large)
                        .fontWeight(.semibold)
                        .frame(width: 22, height: 22)
                        // Same listening state as the voice-mode mic — same life:
                        // breathe while hot, smooth fill/outline swap. Breathe
                        // scales, so it sits out under Reduce Motion.
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.breathe, isActive: env.isListening && !reduceMotion)
                        .animation(.default, value: env.isListening)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(env.isListening ? .red : nil)
                .disabled(!env.canDictate && !env.isListening)
                .help(env.canDictate ? "Voice input — tap to speak, tap to send" : "Microphone unavailable")
                .accessibilityLabel("Voice input")
                .accessibilityValue(env.isListening ? "Listening" : "Off")
                .accessibilityHint("Dictate a message")

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .imageScale(.large)
                        .fontWeight(.semibold)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send")
            }
            .padding(16)
            .frame(maxWidth: Self.chatContentMaxWidth)
            .frame(maxWidth: .infinity) // centre with the transcript column
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !env.chat.isResponding
            && env.chatGate.canTakeTurn // open, or interim (Mini serving)
    }

    /// Cue for the ambient animated backdrop: audio capture (dictation / call
    /// recording) or the WHOLE of voice-first mode. The mode is one continuous
    /// audio conversation — gating per phase would fade the orbs out every time
    /// M1K3 starts speaking, which reads as the app going dead mid-sentence.
    private var showsAmbientBackdrop: Bool {
        env.isListening || env.isRecording || env.isVoiceModeActive
    }

    /// One spoken label for the toolbar status pill — the colour-coded dots carry
    /// no meaning to VoiceOver on their own.
    private var statusAccessibilityLabel: String {
        if env.isRecording { return "Recording in progress" }
        if env.modelLoad.isActive { return env.modelLoad.label(modelName: env.downloadingBrainName) }
        return "Model unavailable, runtime \(env.selectedRuntime.rawValue)"
    }

    /// Status earns its place only when it deviates from "ready and quiet":
    /// recording, a model download in flight, or an unavailable backend. When all
    /// is well it renders nothing — the runtime lives in Settings, not the chrome.
    @ViewBuilder
    private var statusIndicator: some View {
        if env.isRecording || env.modelLoad.isActive || !env.providerAvailable {
            statusContent
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(statusAccessibilityLabel)
        }
    }

    /// The status pill's content; the wrapper above gives it breathing room inside
    /// the toolbar's glass capsule so text/spinner aren't jammed against the edges.
    @ViewBuilder
    private var statusContent: some View {
        if env.isRecording {
            // "Tape is rolling": the pill only mounts while recording, so the
            // pulse runs its whole lifetime — the live-capture privacy signal.
            Label("Recording", systemImage: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse)
                .font(.caption)
                .foregroundStyle(.red)
        } else if env.modelLoad.isActive {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                // Minimal chrome: just the percentage while downloading; the
                // spinner alone carries "preparing" (there's no honest number).
                let compact = env.modelLoad.compactLabel
                if !compact.isEmpty {
                    Text(compact)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else if !env.providerAvailable {
            Label("Model unavailable", systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let images = pendingAttachments
        draft = ""
        pendingAttachments = []
        Task { await env.send(text, images: images) }
    }

    /// Copy picked images into the app's attachments store (security-scoped
    /// picker URLs are only readable inside the access window — the copy is
    /// what makes the attachment durable for the send and history replay).
    private func attachImages(at urls: [URL]) {
        // A swallowed copy failure (disk full, source vanished) reads as
        // "the picker ignored me" — the exact silent-failure class the
        // vision probe caught model-side. Accumulate so a multi-select
        // surfaces EVERY failed file, not just whichever failed last.
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
        if !failures.isEmpty {
            attachmentError = failures.joined(separator: "\n")
        }
    }

    /// Attachments live in the app container beside the other user data.
    private static let attachmentStore = AttachmentStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments")
    )

    /// Keep the newest turn pinned to the bottom as it streams (text or reasoning).
    /// Paused while voice is active so the transcript becomes the calm scroll-back
    /// record — the dock's karaoke is the live read — and the user can read earlier
    /// turns without being yanked to the bottom mid-utterance.
    private func followLatest(_ proxy: ScrollViewProxy) {
        guard !env.isVoiceModeActive, let last = env.chat.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Our own sidebar toggle, pulled OUT of the sidebar's collapsible
        // toolbar into the always-present window toolbar so show/hide is
        // reachable in both states (replaces the auto one removed above).
        // Removing the automatic toggle ALSO drops its ⌃⌘S binding, so we
        // re-bind the standard Toggle-Sidebar shortcut here on our button.
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(.snappy) { setSidebar(visible: !effectiveSidebarVisible) }
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Show or hide the sidebar (⌃⌘S)")
        }
        ToolbarItem(placement: .principal) {
            statusIndicator
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Voice mode + the chat-specific actions only make sense while the
            // chat destination is showing — Documents/Memories/Calls get just
            // the always-relevant items (Agent Log, Review panel, Settings).
            if isChatSelected {
                voiceModeButton
            }
            // The Review-panel toggle comes BEFORE the chat extras: the visible
            // toolbar cluster is width-capped and trailing items spill into the
            // ">>" overflow — where the panel's ONLY reveal affordance was
            // hiding (Kev's 07-25 report). Avatar/Record can live in overflow;
            // the right-hand nav's reveal button can't.
            alwaysToolbarItems
            if isChatSelected {
                chatToolbarItems
            }
        }
    }

    /// True for `.chat`, the transient `.conversation(_)` (see the onChange in
    /// `body`), and `nil` — false only for the three other destinations.
    private var isChatSelected: Bool {
        switch sidebarSelection {
        case .documents, .memories, .calls: false
        default: true
        }
    }

    private var voiceModeButton: some View {
        Button {
            if env.isVoiceModeActive {
                env.exitVoiceMode()
            } else {
                env.enterVoiceMode()
            }
        } label: {
            // Text + icon until the user has entered voice mode once — the
            // headline feature earns a label while it's undiscovered, then
            // steps back to the toolbar's default icon-only rendering.
            Group {
                let label = Label(
                    env.isVoiceModeActive ? "Leave voice mode" : "Voice mode",
                    systemImage: env.isVoiceModeActive ? "person.wave.2.fill" : "person.wave.2"
                )
                .contentTransition(.symbolEffect(.replace))
                .animation(.default, value: env.isVoiceModeActive)
                if hasEnteredVoiceMode {
                    label
                } else {
                    label.labelStyle(.titleAndIcon)
                }
            }
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        // Voice is a conversation, so it can take a turn whenever the chat can —
        // including the interim state where Mini serves while a heavier brain
        // downloads. Was `!env.isReady`, which denied voice exactly where the
        // interim bridge promises Mini can answer (2026-07-25 review finding);
        // now matches `canSend` (chatGate.canTakeTurn).
        .disabled(!env.isVoiceModeActive
            && (!env.canDictate || env.chat.isResponding || env.isListening
                || !env.chatGate.canTakeTurn))
        .help(env.isVoiceModeActive
            ? "Back to the chat (⌘⇧V)"
            : "Talk with M1K3 — hands-free conversation (⌘⇧V)")
    }

    /// Reachable from every sidebar destination, not just Chat. Settings and
    /// Agent Log moved to the sidebar's Workspace section (Kev's call — they
    /// were crowding the toolbar into its ">>" overflow); the Review panel
    /// stays toolbar-only since it isn't a sidebar destination (see
    /// SidebarView's own comment on why).
    private var alwaysToolbarItems: some View {
        Button { env.review.isPresented.toggle() } label: {
            Label("Review panel", systemImage: "sidebar.right")
        }
        .help("Open a side panel to review links and files (⌥⌘R)")
        .keyboardShortcut("r", modifiers: [.command, .option])
    }

    /// Brain hot-swap + the "currently using X" indicator. This intentionally
    /// REVERSES the older "runtime lives in Settings, not the chrome" choice
    /// (`statusIndicator` renders nothing when ready): the brain you're on is now
    /// visible at a glance and one tap to change — Kev's "easy optics on which
    /// we're using". The label reads the ONE live source (`env.selectedBrain`)
    /// composed with `env.modelLoad` so it never claims a brain that's still
    /// downloading. A switch to a downloaded tier (or Mini) is instant via
    /// `selectBrain` (transcript preserved); an un-downloaded tier routes to the
    /// onboarding brain step (the honest download UI) rather than silently pulling
    /// gigabytes from a single tap.
    /// Signed: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.8, Prior: Unknown
    private var brainSwitcher: some View {
        Menu {
            ForEach(BrainSwitcher.rows(
                active: env.selectedBrain,
                isDownloaded: { env.isBrainDownloaded($0) },
                isLocked: { !$0.isSelectableOnThisMac }
            )) { row in
                Button {
                    if row.needsDownload {
                        // Don't start a multi-GB pull from one toolbar tap — route to
                        // the onboarding brain step (the honest download UI). Same
                        // entry point Settings "Change brain…" uses.
                        env.routeToOnboardingBrainPicker()
                    } else {
                        env.selectBrain(row.tier)
                    }
                } label: {
                    Label(row.menuTitle, systemImage: row.isActive ? "checkmark" : row.tier.glyph)
                }
                .disabled(row.isLocked)
            }
        } label: {
            // The Menu label IS the persistent indicator. During a download it shows
            // "Big M1K3 · 34%" — deliberately the same figure the transient principal
            // statusIndicator shows; both read env.modelLoad, so they always agree.
            Label(
                BrainSwitcher.indicatorLabel(active: env.selectedBrain, load: env.modelLoad),
                systemImage: env.selectedBrain.glyph
            )
            .symbolRenderingMode(.hierarchical)
        }
        .disabled(autoRouteBrain)
        .help(autoRouteBrain
            ? "Auto-route is on — M1K3 picks the brain. Turn it off in Settings to choose manually."
            : "Switch brain — currently \(env.selectedBrain.displayName)")
    }

    /// The chat-specific actions — History/Documents/Memories/Calls moved to
    /// the sidebar (they're destinations now, not toolbar-button-behind-a-
    /// sheet), and Settings/Agent Log now live there too (the Workspace
    /// section). Only the Review panel stays in `alwaysToolbarItems`. What's
    /// left here is genuinely chat-only: which brain answers, how the avatar
    /// shows, importing a document, and starting/stopping a call recording.
    private var chatToolbarItems: some View {
        Group {
            brainSwitcher

            // One control for the avatar: panel / full-window background / off.
            Menu {
                Picker("Avatar", selection: $avatarDisplay) {
                    ForEach(AvatarDisplay.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Avatar", systemImage: avatarDisplay.systemImage)
            }
            .help("How M1K3's avatar appears: panel, full-window background, or off")

            // The Import toolbar button retired 2026-07-25 (Kev's call): drop-
            // to-ingest covers the whole window, the GreetingCard's drop zone
            // teaches it, and Documents keeps its own Import button for the
            // deliberate path. Fewer items also keeps the review-panel toggle
            // out of the ">>" toolbar overflow. `showImporter`/.fileImporter
            // stay — the GreetingCard buttons still drive them.

            Button {
                if env.isRecording {
                    Task { await env.stopRecording() }
                } else if env.recordingPreAuthorised {
                    Task { await env.startRecording() }
                } else {
                    showConsentDialog = true
                }
            } label: {
                Label(env.isRecording ? "Stop recording" : "Record call",
                      systemImage: env.isRecording ? "stop.circle.fill" : "record.circle")
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: env.isRecording)
            }
            .tint(env.isRecording ? .red : nil)
        }
    }
}

// MARK: - Supporting views

// EmptyChatView retired 2026-07-03 — GreetingCard (its own file) owns the
// empty-transcript slot now, with an actual guided affordance.

private struct DropHintView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
            .overlay {
                Label("Drop to ingest", systemImage: "tray.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    // A gentle beckon while the drag hovers — self-limiting, the
                    // view unmounts when the drag ends. Keep the delay ≥1.5s.
                    // Wiggle moves, so it sits out under Reduce Motion.
                    .symbolEffect(
                        .wiggle.down,
                        options: .repeat(.periodic(delay: 1.5)),
                        isActive: !reduceMotion
                    )
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            .padding(24)
            .allowsHitTesting(false)
    }
}

/// The global readiness gate: shown over the chat surface while the active brain
/// is still loading, failed to load, or can't run on this Mac. Swallows
/// interaction so a turn can't be fired before the model is warm. The window
/// toolbar (Settings) stays reachable as chrome above this overlay.
private struct ModelGateView: View {
    let readiness: AppReadiness
    let brainName: String
    /// Non-nil when Lil's weights are on disk — the `.unavailable` dead-end
    /// gains a one-tap way out (AFM turned off post-onboarding).
    var switchToLil: (() -> Void)?
    let retry: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            card
                .padding(28)
                .padding(40)
        }
        .contentShape(Rectangle()) // swallow taps to the gated surface beneath
    }

    @ViewBuilder
    private var card: some View {
        switch readiness {
        case let .loading(state):
            VStack(spacing: 16) {
                if let fraction = state.fraction {
                    // Unlabeled on purpose: the sibling Text(loadingLabel) below
                    // is the visible caption (109 review nit — was an empty closure).
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text(loadingLabel(state))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                DialUpMuteButton()
            }
        case let .failed(message):
            VStack(spacing: 14) {
                Label("Couldn’t load \(brainName)", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Try again", action: retry)
                        .buttonStyle(.borderedProminent)
                    SettingsLink { Text("Open Settings") }
                }
            }
        case .unavailable:
            VStack(spacing: 14) {
                Label("\(brainName) isn’t available here", systemImage: "questionmark.circle")
                    .font(.headline)
                Text("This Mac can’t run the selected brain. Choose a different one in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // The rescue: Apple Intelligence turned off AFTER first run,
                // but Lil's weights are already on disk — one tap out of the
                // dead end instead of a Settings expedition.
                if let switchToLil {
                    Button("Switch to Lil (already downloaded)", action: switchToLil)
                        .buttonStyle(.borderedProminent)
                }
                SettingsLink { Text("Open Settings") }
            }
        case .ready:
            EmptyView() // unreachable: the overlay is only mounted while !env.isReady
        }
    }

    /// Prefer the load state's own label (with %); fall back to a plain line when
    /// it has none (e.g. `.idle`, the instant before warm-up starts).
    private func loadingLabel(_ state: ModelLoadState) -> String {
        let label = state.label(modelName: brainName)
        return label.isEmpty ? "Loading \(brainName)…" : label
    }
}

/// The `.interim` gate's slim companion: the selected brain is still
/// downloading but Mini is serving, so instead of ModelGateView's full wall
/// this floats the progress over the top of the transcript and stays out of
/// the way. Copy is honest about WHO is answering — the turn quality changes
/// while Mini holds the fort.
private struct InterimMiniBanner: View {
    let load: ModelLoadState
    let brainName: String

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = load.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Mini’s answering while \(brainName) arrives")
                    .font(.callout.weight(.medium))
                Text(progressLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // .regularMaterial, NOT glassEffect: a Liquid Glass surface near the
        // titlebar that re-renders on every download-progress tick resonated
        // with NSThemeFrame's corner-inset updates — the NSGenericException
        // layout crash (3 instances, 07-25; master control soaked clean, this
        // banner is the branch's only glass near the chrome). Material gives
        // the same legibility without entering the glass/corner-inset cycle.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mini is answering while \(brainName) downloads. \(progressLine)")
    }

    private var progressLine: String {
        let label = load.label(modelName: brainName)
        return label.isEmpty ? "Getting \(brainName) ready…" : label
    }
}

/// The user-intro earned moment — a few real exchanges in, when M1K3 doesn't
/// know them yet. Accepting just hands over the floor (focuses the input):
/// the intro is a conversation memory auto-capture learns from, not a form.
/// One dismissal is terminal.
private struct IntroductionOfferCard: View {
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("I remember things — properly, on this Mac.")
                .font(.callout.weight(.semibold))
            Text("Tell me a bit about yourself and I'll keep what matters in mind.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Introduce yourself", action: onAccept)
                    .buttonStyle(.glassProminent)
                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

/// The M1K3 Voice earned moment — one line, two honest actions, shown only
/// after real spoken exchanges on the built-in voice (never mid-session).
private struct VoiceUpgradeBanner: View {
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("That was my everyday voice. Want to hear my proper one?")
                .font(.callout)
            Spacer()
            Button("Get M1K3 Voice", action: onAccept)
                .buttonStyle(.glassProminent)
            Button("Not now", action: onDismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// The capability ladder's invitation, in M1K3's voice. Three flavours: the
/// first offer (after the first answer), the struggle-earned re-offer ("that
/// one stretched me" — only shown when a past "Maybe later" was lifted by
/// felt limitations, never by a timer), and the one-tap switch for weights
/// already on disk. Consent lives HERE; the fetch is disk-only and invisible;
/// the swap is the payoff at the next idle moment.
private struct BrainUpgradeNudgeCard: View {
    /// The rung being offered (Lil on 16GB Macs, Big directly on 24GB+).
    let target: BrainTier
    let currentBrainName: String
    /// True for the one-tap switch (weights already on disk, no fetch needed).
    let isStagedSwitch: Bool
    /// True when a prior dismissal was lifted by felt struggles.
    let isReOffer: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var sizeText: String {
        guard let mb = target.approxDownloadMB else { return "" }
        return String(format: "%.1f GB", Double(mb) / 1000)
    }

    private var headline: String {
        if isStagedSwitch {
            "\(target.displayName)'s already here — my sharper brain is sitting on disk."
        } else if isReOffer {
            "That one stretched me."
        } else if target == .big {
            "That was \(currentBrainName) — and this Mac can run my full brain."
        } else {
            "That was \(currentBrainName), my quickest brain."
        }
    }

    private var pitch: String {
        if isStagedSwitch {
            "Want me to switch over? Takes a few seconds, everything stays on this Mac."
        } else {
            // ONE download pitch (reduction pass, 2026-07-03): the headlines
            // carry the flavour; two near-identical pitches were saying the
            // same thing twice.
            "\(target.displayName) is sharper — a \(sizeText) one-time fetch, "
                + "grabbed in the background while we keep talking."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.callout.weight(.semibold))
            Text(pitch)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(
                    isStagedSwitch ? "Switch to \(target.displayName)" : "Fetch \(target.displayName)",
                    action: onAccept
                )
                .buttonStyle(.glassProminent)
                Button("Maybe later", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        // No .accessibilityElement(children: .combine) here: it would merge the
        // accept/decline buttons into one opaque element — VoiceOver users must
        // be able to reach each independently (review catch, 2026-07-03).
    }
}

/// The mic/speech denial recovery — today's silent empty listen made loud and
/// fixable. Three short lines (dyslexia-friendly), one honest action. The copy
/// names the ACTUAL blocked grant (the policy distinguishes them for a reason —
/// telling a mic-granted user "the mic is blocked" would send them to fix the
/// wrong thing).
private struct VoicePermissionBanner: View {
    let recovery: VoicePermissionPolicy.Recovery
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("I can't hear you yet.")
                    .font(.callout.weight(.semibold))
                Text(recovery == .microphone
                    ? "Your Mac is blocking the mic. Flip M1K3 on in System Settings, then try me again."
                    : "Your Mac is blocking Speech Recognition for M1K3. Flip it on in System Settings, then try me again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings", action: onOpenSettings)
                .buttonStyle(.glassProminent)
            Button("Not now", action: onDismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct IngestBanner: View {
    let text: String
    let busy: Bool
    /// The idle glyph. Defaults to the ingest success tick; the brain-swap /
    /// voice-fetch toasts pass their own so a swap doesn't read as "document
    /// indexed" (reduction pass, 2026-07-03).
    var icon = "checkmark.circle.fill"
    var iconColor: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                // Insertion transition, not a Bool-keyed bounce (Bools
                // double-fire and the view is freshly inserted on the flip).
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .transition(.symbolEffect)
            }
            Text(text).font(.callout).lineLimit(2)
            Spacer()
        }
        .animation(.default, value: busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
