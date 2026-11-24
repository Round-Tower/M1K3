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
//  Review: Kev + claude-opus-5.5, 2026-11-03 — trust pass (Kev: "It's about trust"): a status line over the
//  composer says who answers and whether web search is on ("Lil · Web on", `ChatStatusLine`); a tap changes
//  either. It names Private Cloud when the next send goes there, so it replaces the cloud chip. One ＋ replaces
//  the paperclip and Photos buttons (Kev: "too cramped"): Files, Photos, then the same brain and web rows.
//  The brain rows mirror Settings ▸ Brain. Confidence 0.75 (verify-by-launch on the iPhone and the Duo).
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
//  Review: Kev + claude-opus-5.5, 2026-11-02 — the thumbs-down note is this screen's sheet (`noteTarget`), not a
//  transcript row's: the row left the lazy window under the keyboard and closed the note. Every brain takes the
//  tool route, and the face is built only while the chat is on screen (`chatOnScreen`): one built under Settings
//  never drew and came back black. Confidence 0.75.
//  Review: Kev + claude-fable-5.2, 2026-11-09 — #768: the eye beside the ＋ opens `LookScreen` (shown only when
//  `core.canLook`), and the attachment store is AppCore's, shared with the look. Confidence 0.7 (verify on the phone).
//  Review: Kev + claude-fable-5.2, 2026-11-10 (#768 follow-ups) — two actions under a look's answer: "Ask about this
//  photo" (the next send looks at the same stored frame, shown as a pill over the composer) and "Search the web for
//  this" (drafts a query INTO the composer; the user sends it). Confidence 0.6: untried in the hand.
//  Review: Kev + claude-fable-5.2, 2026-11-10 — Kev, in the hand: the eye "is cluttering the chat input space". It
//  moves to the top bar beside voice mode. Confidence 0.7.
//  Review: Kev + claude-fable-5.2, 2026-11-10 — Kev's screenshot: the two look actions wrapped and sat at different
//  heights. They read "Ask more" and "Search the web", one line each (VoiceOver keeps the long wording). Confidence 0.8.
//  Review: Kev + claude-fable-5.2, 2026-11-10 — the wordmark gains the brain's tag ("LIL M1K3"), typed on in the pixel
//  face when the brain changes (`BrainTagTypeOn`, still with Reduce Motion). Confidence 0.6 until Kev has seen it.
//  Review: Kev + claude-fable-5.2, 2026-11-13 — the status line over the composer is near-primary, not `.secondary`
//  (it failed Xcode's contrast audit over the thin material), and its separator dot is hidden from accessibility.
//  Measured by re-running the audit on a Simulator; the look is verify-on-device. Confidence 0.7.
//  Review: Kev + claude-fable-5.2, 2026-11-14 — quiet text moves from `.secondary` to `.readableSecondary`
//  (ReadableSecondary.swift), as on the Mac in #831. Not yet measured on the phone at the time of writing.
//  Review: Kev + claude-opus-5.5, 2026-11-14 — a send with files and no photos is a READ (`core.read`), and a read's
//  answers offer "Keep this". Compile-checked; owes a try in the hand.
//  Review: Kev + claude-opus-5.5, 2026-11-14 (the summoned pass on #833) — a read that cannot start hands the question
//  and the files back to the composer instead of dropping them. Compile-checked.
//  Review: Kev + claude-opus-5.5, 2026-11-16 — New chat tells the Live Activity (`turnActivity.turnFinished(.newChat)`).
//  Review: Kev + claude-opus-5.5, 2026-11-18 (Kev: remove the chat's splash-screen questions, they come out odd and
//  M1K3 quotes them oddly) — the blank canvas's starter chips are gone: a memory title trimmed into a chip was sent
//  as the person's words. The canvas is the face and the composer.
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: the String-typed readiness hint and the refused-image
//  line are String(localized:). English unchanged.
//  Review: claude-opus-5-5, 2026-11-21 — a failed answer offers "Send a report" (the brain report, "couldn't
//  answer", MLX's own messages included), gated like the brain-load one. Verify-by-launch. Confidence 0.75.
//  Review: Kev + claude-opus-5.5, 2026-11-22 — a staged file keeps the turn on this device, as on the Mac (ADR 0010):
//  `hasAttachments` counted images only, so with Private Cloud picked a file's text left with the question. One
//  `hasStagedAttachments` feeds the send, the label and the consent sheet's send, and the cloud question is the typed
//  draft alone, never the file-prefixed text. Only `sendToPrivateCloud` clears it, after its guards, and hands it
//  back on a refusal, as on the Mac (the first cut cleared first: on Kev's phone every consented send vanished).
//  Device try owed. Confidence 0.75.
//  Review: Kev + claude-opus-5-5, 2026-11-23 — share to M1K3 (#893 C): `sharedFiles` from RootView land through
//  `receiveSharedFiles()` → `attach(urls)`, the ＋ picker's path, in a new chat when this one has messages, waiting
//  out a turn in flight; never sent; iOS's Inbox copy is deleted once staged. Confidence 0.8 (verify on the phone).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — a shared file also waits behind the Private Cloud
//  consent sheet (it would have joined the send the sheet confirms), and staging sweeps Inbox leftovers a killed app
//  left. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#895 second pass) — staging deletes only its own Inbox copies (a batch
//  AirDrop's siblings are still on their way; RootView sweeps leftovers on background), and a shared file also
//  waits out a consented Private Cloud send still launching. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (1.6 follow-up: B meets C) — a shared .html/.md also opens beside the
//  chat (read before the Inbox copy goes; 2 MB cap, asked by size before the read; UTF-8 else Latin-1). Confidence
//  0.75 (device try owed).
//  Review: Kev + claude-opus-5-5, 2026-11-23 — 1.6 code beside the chat: every code card's Open button (via the
//  `openCodeBlock` environment) fills `core.artifact`, shown as a sheet in a compact window and a column beside the
//  chat in a regular one (ArtifactPresentation). Device try owed. Confidence 0.7.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#898 review: a waiting share looked lost) — a plain caption over the
//  composer while shared files wait out a reply or the Private Cloud sheet (`SharedFileIntake.waitingHint`), with
//  `doc.badge.clock`, an accessibility label and one announcement when it shows. It only tells: staging is
//  unchanged. Confidence 0.75 (compile-checked; device look owed).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — the hint hangs from a zero-height anchor on the
//  bar's top edge, on a fixed material capsule (an overlay, not a row: a row grew the bar mid-reply and jumped the
//  transcript), and it is announced again for each new wait reason. Confidence 0.75 (compile-checked; device look
//  owed).
//

import M1K3Avatar
import M1K3Chat
import M1K3Diagnostics
import M1K3Inference
import M1K3LanguageModel
import M1K3Preview
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
    /// Files shared to M1K3 from another app (RootView's `onOpenURL`), staged here and never sent (#893 C).
    @Binding var sharedFiles: [URL]
    /// A consented Private Cloud send between the sheet closing and `isResponding`: a shared file waits it out, since
    /// opening a new chat under it would leave the send aimed at the old conversation (#895 second pass).
    @State private var privateCloudSending = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true
    @AppStorage(CompanionDefaults.companionKey) private var companion = CompanionDefaults.houseCompanion.id
    @AppStorage(CompanionDefaults.seasonalLooksKey) private var seasonalLooks = true
    @State private var draft = ""
    @State private var showAttachmentImporter = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// The ＋ menu's Photos row presents the picker; a PhotosPicker can't live inside a Menu.
    @State private var showPhotoPicker = false
    @State private var showLook = false
    /// The composer is asking about the last look's photo (#768): the next send is a look at that stored frame.
    @State private var aboutPhoto = false
    /// Sends are more questions about the last read's text ("Ask more" under it), until the pill's ✕.
    @State private var aboutText: String?
    /// The eyes are drafting a search query for the composer.
    @State private var draftingSearch = false
    @AppStorage(AppCore.webSearchEnabledKey) private var webSearchEnabled = true
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var pendingFiles: [FileAttachment] = []
    @State private var attachmentError: String?
    @AppStorage(ChatEgressConsent.defaultsKey) private var privateCloudConsent = false
    @State private var privateCloudPending: PendingPrivateCloudSend?
    @AppStorage(PersistedAgeBandProvider.defaultsKey) private var ageBandRaw: String?
    @State private var brainFailureDraft: SnagDraft?
    @State private var showSettings = false
    /// The window's width, for where an opened page shows (ArtifactPresentation).
    @State private var windowWidth: CGFloat = 0
    /// On screen, not covered by a pushed screen (Settings). The face is built only then:
    /// one built under Settings never got a drawable, failed 60 frames a second, and stayed
    /// black when the chat came back (Kev's phone, 2026-11-02).
    @State private var chatOnScreen = true
    /// The answer whose thumbs-down note is open (`AnswerNoteSheet`).
    @State private var noteTarget: NoteTarget?
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
    /// unmount what is beneath it — ONE RealityView at a time. Settings too
    /// (`chatOnScreen`): it has its own preview.
    private var backdropMounted: Bool {
        backdropActive && core.voiceLoop == nil && chatOnScreen
    }

    /// Composing — keyboard up or a draft in hand; recedes the backdrop avatar.
    private var isComposing: Bool {
        inputFocused || !draft.isEmpty || !pendingAttachments.isEmpty || !pendingFiles.isEmpty
    }

    /// A regular-width window (iPad) shows the opened code beside the chat; a compact one (iPhone) as a sheet.
    private var artifactPresentation: ArtifactPresentation {
        ArtifactPresentation.style(isRegularWidth: horizontalSizeClass == .regular, width: Double(windowWidth))
    }

    /// The sheet's binding: only where the column does not fit, so a wide window never shows both. A page opened
    /// from voice mode (or the look camera), which cover this screen, waits for the cover to close and then
    /// presents: a sheet raised under a full-screen cover would never show, or show late.
    private var artifactSheet: Binding<CodeArtifact?> {
        Binding(
            get: { artifactPresentation == .sheet && core.voiceLoop == nil && !showLook ? core.artifact : nil },
            set: { if $0 == nil { core.closeArtifact() } }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                hero
                transcript
                inputBar
            }
            if artifactPresentation == .besideChat, let artifact = core.artifact {
                Divider()
                ArtifactView(artifact: artifact, onClose: { core.closeArtifact() })
                    .id(artifact.id)
                    .frame(width: 380)
                    .background(.regularMaterial)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: core.artifact?.id)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .environment(\.openCodeBlock) { language, code in
            core.openCodeBlock(language: language, code: code)
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
                        core.turnActivity.turnFinished(.newChat)
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    // startNewConversation no-ops on an empty transcript or a turn
                    // in flight — disable so the button never reads as broken.
                    .disabled(core.chat.messages.isEmpty || core.chat.isResponding)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The eye (#768) opens the Look screen. Up here beside voice mode, not in the composer
                    // row, which it crowded (Kev, 2026-11-10). Only when the answering brain sees on this device.
                    if core.canLook {
                        Button {
                            inputFocused = false
                            showLook = true
                        } label: {
                            Label("Look", systemImage: "eye")
                        }
                        .disabled(core.chat.isResponding || !core.isReady)
                        .accessibilityHint("Opens the camera so M1K3 can see what you point it at")
                    }
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
            .fullScreenCover(isPresented: $showLook) {
                LookScreen()
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
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $pickedPhotos,
                maxSelectionCount: max(1, Self.photoLimit - pendingAttachments.count),
                matching: .images
            )
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
            .onChange(of: core.reviewLedger.completedTurns) { _, _ in
                askForRatingIfEarned()
            }
            // A shared file waits out a turn in flight, then lands in a new chat's composer.
            .onChange(of: sharedFiles, initial: true) { _, _ in receiveSharedFiles() }
            .onChange(of: core.chat.isResponding || privateCloudPending != nil || privateCloudSending) { _, _ in
                receiveSharedFiles()
            }
            // VoiceOver hears the waiting hint when it shows, and again each time the reason changes.
            .onChange(of: sharedFileWaitReason, initial: true) { _, reason in
                if reason != nil, let sharedFileHintText {
                    AccessibilityNotification.Announcement(sharedFileHintText).post()
                }
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
            .sheet(item: artifactSheet) { artifact in
                ArtifactView(artifact: artifact, onClose: { core.closeArtifact() })
                    .id(artifact.id)
                    .presentationDetents([.large])
            }
            .sheet(item: $noteTarget) { target in
                AnswerNoteSheet(
                    existingComment: target.existing,
                    onFeedback: { verdict, comment in rate(target.message, verdict, comment) },
                    onClose: { noteTarget = nil }
                )
            }
            .sheet(item: $brainFailureDraft) { draft in
                SnagReportSheet(draft: draft, onDone: { brainFailureDraft = nil })
            }
            .sheet(item: $privateCloudPending) { pending in
                privateCloudConsentView(pending)
            }
            .onAppear { core.privateCloudArming.controlChanged(privateCloudControl) }
            .onAppear { chatOnScreen = true }
            .onDisappear { chatOnScreen = false }
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
                guard core.privateCloudSendAllowed(), !hasStagedAttachments else { send(); return }
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

    /// The answer a thumbs-down note is for, with the note saved so far.
    private struct NoteTarget: Identifiable {
        let message: ChatMessage
        let existing: String?
        var id: ChatMessage.ID {
            message.id
        }
    }

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
                if !avatarHidden, !backdropActive, chatOnScreen {
                    AvatarSurface(controller: core.avatar)
                        .frame(height: 168)
                        .padding(.horizontal, 56)
                }
                // "LIL M1K3": the brain that is in, typed on in the wordmark's own face (Kev, 2026-11-10).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    let elsewhere = core.homeBrainActive || privateCloudServesNextSend
                    if let tag = BrainWordmark.tag(for: core.selectedBrain, elsewhere: elsewhere) {
                        BrainTagTypeOn(tag: tag)
                    }
                    Text("M1K3")
                        .font(.pixel(28))
                        .kerning(2)
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("M1K3, \(core.answeringBrainName)")
                .accessibilityAddTraits(.isHeader)
                // In season, M1K3 greets in costume (opt-out in Settings ▸ Face).
                if let line = SeasonalLook.greeting(for: SeasonalLook.now(enabled: seasonalLooks, offline: NetworkPathWatch.shared.isOffline)) {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.readableSecondary)
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
            case .notReady:
                return String(
                    localized: "Apple Intelligence is still getting ready on this device. It can take a while after it's turned on…"
                )
            case let .blocked(userFixable):
                let alternative = core.brainMenu.localFallbackPhrase(verb: "pick")
                    ?? String(localized: "pair with your Mac", comment: "Fills %@ in “… — or %@ in Settings.”")
                return userFixable
                    ? String(
                        localized: "Turn on Apple Intelligence in Settings — or \(alternative) in Settings.",
                        comment: "%@ is what else to do, a verb phrase such as “pick Lil” or “pair with your Mac”"
                    )
                    : String(
                        localized: "This device can't run Apple Intelligence — \(alternative) in Settings.",
                        comment: "%@ is what else to do, a verb phrase such as “pick Lil” or “pair with your Mac”"
                    )
            }
        case .mlx:
            if case let .failed(message) = core.brainLoad { return message }
            return String(
                localized: "\(core.selectedBrain.displayName) isn't ready yet.",
                comment: "%@ is a brain's name (Lil, Big, Mini): keep it untranslated"
            )
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
                            .foregroundStyle(.readableSecondary)
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

    /// A failed answer's report, for the age bands #708's reports are offered to (nil hides the button).
    private func failureReport(for message: ChatMessage) -> (() -> Void)? {
        guard case let .failed(reason) = message.status,
              AgeAppropriateness.fieldReportAllowed(for: AgeBand(persisted: ageBandRaw)) else { return nil }
        return {
            Task {
                brainFailureDraft = await core.brainFailureDraft(
                    shown: reason, happened: BrainFailureReport.Happened.couldNotAnswer
                )
            }
        }
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
                            onFeedback: { verdict, comment in rate(message, verdict, comment) },
                            onNeedsWork: {
                                noteTarget = NoteTarget(
                                    message: message, existing: core.chat.feedbackComments[message.id]
                                )
                            },
                            onSpeak: { core.readAloud($0) },
                            onKeep: core.chat.readSource(answeredBy: message.id).map { source in
                                { await core.keep(source) }
                            },
                            onReportFailure: failureReport(for: message),
                            onSendFollowUp: { question in
                                // Gate on brainReady, not canSend: a follow-up chip carries
                                // its own prompt, so no draft dependency; chips
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
                    if core.canAskAboutLastLook, !core.chat.isResponding {
                        lookActions
                    }
                    if core.chat.lastRead != nil, !core.chat.isResponding, aboutText == nil {
                        readActions
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

    /// What can follow a look (#768), under its answer. Both are the user's own act: asking again looks at the
    /// same stored photo on this device, and the search action only DRAFTS a query into the composer.
    private var lookActions: some View {
        HStack(spacing: 8) {
            Button {
                aboutPhoto = true
                inputFocused = true
            } label: {
                Label("Ask more", systemImage: "eye")
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityLabel("Ask about this photo")
            .accessibilityHint("Your next message is answered by looking at this photo again, on this device")
            if webSearchEnabled {
                Button {
                    draftSearch()
                } label: {
                    Label(draftingSearch ? "Drafting…" : "Search the web", systemImage: "globe")
                        .lineLimit(1)
                        .fixedSize()
                }
                .disabled(draftingSearch)
                .accessibilityLabel("Search the web for this")
                .accessibilityHint("Writes a search for you to read and send. Nothing is sent until you send it")
            }
            Spacer(minLength: 0)
        }
        // One line each, the same height, from the leading edge: the long labels wrapped on the phone
        // (Kev, 2026-11-10).
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.footnote)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// The eyes name what is in the photo as a short search, into the composer. The user sends it or doesn't.
    private func draftSearch() {
        guard !draftingSearch else { return }
        draftingSearch = true
        Task {
            defer { draftingSearch = false }
            guard let text = await core.draftLookSearch() else {
                attachmentError = String(localized: "M1K3 couldn't name anything in the photo to search for.")
                return
            }
            aboutPhoto = false
            draft = text
            inputFocused = true
        }
    }

    /// Under the newest read: the next question goes to the same text.
    private var readActions: some View {
        HStack(spacing: 8) {
            Button {
                aboutText = core.chat.lastRead?.source.title
                inputFocused = true
            } label: {
                Label("Ask more", systemImage: "doc.text.magnifyingglass")
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityLabel("Ask more about this text")
            .accessibilityHint("Your next message is answered from this text again, on this device")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.footnote)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// Over the composer while the next send is a question about the last read's text.
    private func aboutTextPill(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .accessibilityHidden(true)
            Text("Asking about “\(title)”")
                .lineLimit(1)
            Button {
                aboutText = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop asking about this text")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 6)
    }

    /// Shown over the composer while the next send is a question about the last look's photo.
    private var aboutPhotoPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
            Text("Asking about the photo")
            Button {
                aboutPhoto = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop asking about the photo")
        }
        .font(.footnote)
        .foregroundStyle(.readableSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 6)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if let last = core.chat.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            statusLine
                .padding(.bottom, 6)
            if aboutPhoto, core.canAskAboutLastLook {
                aboutPhotoPill
                    // The pill's promise ends with the look it points at (another turn, another chat).
                    .onDisappear { aboutPhoto = false }
            }
            // The pill holds its own title: `lastRead` is nil while a follow-up streams, and the
            // chain must survive that. It ends on its ✕, an ordinary send, or another conversation.
            if let aboutText {
                aboutTextPill(aboutText)
                    .onChange(of: core.chat.activeConversationID) { self.aboutText = nil }
            }
            if !pendingAttachments.isEmpty {
                pendingImagesStrip
            }
            if !pendingFiles.isEmpty {
                pendingFilesStrip
            }
            M1K3GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    addMenu

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
        // A shared file waiting out a reply or the Private Cloud sheet says so, just above the bar it will land in.
        // An overlay hung from the bar's top edge, not a row in it: a row would grow the bar mid-reply and shrink
        // (jump) the transcript above it.
        // A zero-height anchor on the bar's top edge; the hint hangs from it, upward (an `alignmentGuide` on the
        // conditional child was not honoured on the Mac, where the hint drew inside the band).
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    if let sharedFileHintText {
                        sharedFileHint(sharedFileHintText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    /// Who answers the next message and whether web search is on, over the composer; a tap
    /// changes either (Kev, 2026-11-03: "It's about trust"). Names Private Cloud Compute
    /// when the next send really goes there, as the chip it replaces did.
    private var statusLine: some View {
        let line = statusFacts
        return Menu {
            brainAndWebItems
        } label: {
            HStack(spacing: 6) {
                if let symbol = line.brainSymbol {
                    Image(systemName: symbol)
                }
                Text(line.brainText)
                Text("·").foregroundStyle(.readableSecondary).accessibilityHidden(true)
                Image(systemName: ChatStatusLine.webSymbol)
                    .opacity(line.webSearchOn ? 1 : 0.4)
                Text(line.webText)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.readableSecondary)
            }
            .font(.caption)
            // Not `.secondary`: over the thin material it measured under the contrast floor
            // (Xcode's audit, 2026-11-13), and this line is the one that says where a message goes.
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.accessibilityLabel)
        .accessibilityHint("Changes the brain or web search")
    }

    /// What the line says: the answering brain and the web state that applies (switch AND age band).
    private var statusFacts: ChatStatusLine {
        ChatStatusLine(
            brainName: core.answeringBrainName,
            privateCloudNext: privateCloudServesNextSend,
            webSearchOn: webSearchEnabled,
            ageBand: AgeBand(persisted: ageBandRaw)
        )
    }

    /// One ＋ for everything you add to a message: Files, Photos, then the brain and web switches.
    private var addMenu: some View {
        Menu {
            Section {
                Button { showAttachmentImporter = true } label: {
                    Label("Files", systemImage: "paperclip")
                }
                if core.imagesAccepted {
                    // Out of process: no photo-library prompt, no usage string.
                    Button { showPhotoPicker = true } label: {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(pendingAttachments.count >= Self.photoLimit)
                }
            }
            .disabled(core.chat.isResponding || !core.isReady)
            brainAndWebItems
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
    }

    /// The brain picker and the web switch, shared by the status line and the ＋ menu. The same
    /// rows as Settings ▸ Brain: this device's tiers, Home once a Mac is paired, and Private Cloud.
    @ViewBuilder
    private var brainAndWebItems: some View {
        Section("Brain") {
            ForEach(core.brainMenu.options) { option in
                switch option {
                case let .tier(tier):
                    Button {
                        core.pickPrivateCloud(false)
                        core.selectBrain(tier)
                    } label: {
                        Label(
                            tier.displayName,
                            systemImage: brainChecked(tier: tier) ? "checkmark" : tier.glyph
                        )
                    }
                case .brainAtHome:
                    if core.homeBrain != nil {
                        Button {
                            core.pickPrivateCloud(false)
                            core.selectHomeBrain()
                        } label: {
                            Label("Home", systemImage: brainChecked(tier: nil) ? "checkmark" : "house")
                        }
                    }
                }
            }
            if privateCloudPickerRow != .hidden {
                Button {
                    core.pickPrivateCloud(true)
                } label: {
                    Label(
                        PrivateCloudRung.menuTitle(privateCloudPickerRow),
                        systemImage: core.privateCloudArming.isOn ? "checkmark" : PrivateCloudLabel.symbolName
                    )
                }
                .disabled(privateCloudPickerRow != .ready)
            }
        }
        .disabled(core.chat.isResponding)
        // A menu shows no section footer, so the destination rides the toggle's subtitle. The toggle
        // shows the state that applies: off and disabled when the age band withholds web tools.
        let facts = statusFacts
        Section {
            Toggle(isOn: Binding(get: { facts.webSearchOn }, set: { webSearchEnabled = $0 })) {
                Label {
                    Text("Web search")
                    Text(facts.webLockedByAge ? "Not available" : "Searches go to \(EgressFacts.searchProvider)")
                } icon: {
                    Image(systemName: ChatStatusLine.webSymbol)
                }
            }
            .disabled(facts.webLockedByAge)
        }
    }

    /// The checkmark rule Settings uses: Private Cloud wins, then Home, then the selected tier.
    /// `tier` nil asks about Home.
    private func brainChecked(tier: BrainTier?) -> Bool {
        guard !core.privateCloudArming.isOn else { return false }
        guard let tier else { return core.homeBrainActive }
        return !core.homeBrainActive && core.selectedBrain == tier
    }

    /// Settings' Private Cloud row state, so the two pickers can't disagree.
    private var privateCloudPickerRow: PrivateCloudRung.Control {
        PrivateCloudRung.pickerControl(core.privateCloudState(consent: nil))
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
                                .foregroundStyle(.readableSecondary)
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
        // A question about the last look's photo is a look: on this device, never Private Cloud, never a tool.
        // So is one whose words name the picture straight after a look ("is there a person in the photo?").
        // Never when the next send is Private Cloud's by the user's choice: only the pill overrides that.
        let namesIt = LookAftermath.namesThePicture(draft) && !LookAftermath.asksToSearch(draft)
            && !privateCloudServesNextSend
        if aboutPhoto || namesIt, core.canAskAboutLastLook, !core.isLooking,
           pendingAttachments.isEmpty, pendingFiles.isEmpty
        {
            let question = draft
            clearDraft()
            Task { await core.lookAgain(question) }
            return
        }
        aboutPhoto = false
        // "Ask more" under a read: the question goes to the same text, on this phone, before any
        // Private Cloud arming (a read never leaves the device). STICKY (Kev, 2026-11-14): the pill
        // stays for a chain of questions until its ✕, a new attachment, or the read is no longer last.
        if aboutText != nil, core.chat.lastRead != nil, pendingAttachments.isEmpty, pendingFiles.isEmpty,
           core.reader.readContextTokens > 0
        {
            let question = draft
            clearDraft()
            Task {
                // Could not start (the brain changed under the pill): the question comes back, unsent.
                let started = await core.readAgain(question)
                if !started, draft.isEmpty, pendingFiles.isEmpty, pendingAttachments.isEmpty { draft = question }
            }
            return
        }
        aboutText = nil
        // Prose files asked ABOUT are READ (instructions only, on this phone, display-only) rather than
        // prepended to a chat turn that carries the persona, the tools and the history. Code, a
        // "write"/"draft"/"translate" ask, or a brain that can't read here (Brain at Home) keeps the chat turn.
        if pendingAttachments.isEmpty, core.reader.readContextTokens > 0,
           ReadRoute.reads(files: pendingFiles, draft: draft)
        {
            let question = draft
            let files = pendingFiles
            clearDraft()
            Task {
                // Cleaning a long file is real work: off the main actor.
                let source = await Task.detached(priority: .userInitiated) { ReadSource(files: files) }.value
                if let source {
                    // Could not start (the brain changed, a turn in flight): the words and the files
                    // come back to the composer, never silently dropped (the summoned pass).
                    if await !core.read(question, source: source), draft.isEmpty, pendingFiles.isEmpty {
                        draft = question
                        pendingFiles = files
                    }
                } else {
                    await core.send(question)
                }
            }
            return
        }
        let onDevice = ChatSession.onDeviceMessageIDs(core.chat.messages)
        // Voice mode answers on-device (ADR 0010); typed sends in voice never go to PCC.
        let action: PrivateCloudArming.Action = core.voiceLoop != nil ? .local : core.privateCloudArming.action(
            control: privateCloudControl, hasAttachments: hasStagedAttachments, onDeviceMessages: onDevice
        )
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingFiles.isEmpty {
            let fileContext = pendingFiles.map(\.contextBlock).joined(separator: "\n\n")
            text = text.isEmpty ? fileContext : fileContext + "\n\n" + text
        }
        switch action {
        case .askConsent:
            privateCloudPending = PendingPrivateCloudSend(
                consent: core.chat.privateCloudConsent(for: draft), onDeviceShown: onDevice
            )
            return
        case let .sendDirect(includeConversation) where core.privateCloudSendAllowed():
            sendToPrivateCloud(core.chat.privateCloudConsent(for: draft), includeConversation: includeConversation)
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
            control: privateCloudControl, hasAttachments: hasStagedAttachments
        )
    }

    /// Images and files alike: neither ever rides a Private Cloud turn (ADR 0010).
    private var hasStagedAttachments: Bool {
        !pendingAttachments.isEmpty || !pendingFiles.isEmpty
    }

    private func sendToPrivateCloud(_ consent: PrivateCloudTurn.Consent, includeConversation: Bool) {
        // The session refuses both silently, so they are checked while the words are still in the box:
        // a sheet that outlived its chat, and an answer still arriving.
        guard consent.conversationID == nil || consent.conversationID == core.chat.activeConversationID,
              !core.chat.isResponding
        else { return }
        let words = draft
        clearDraft()
        privateCloudSending = true
        Task {
            let sent = await core.sendPrivateCloud(consent, includeConversation: includeConversation)
            privateCloudSending = false
            if !sent, draft.isEmpty { draft = words }
        }
    }

    // MARK: - Attachments

    /// The one attach button's landing: images to the vision path, the rest to
    /// file-as-context; every failed file is named (never a silent drop).
    private func attach(_ urls: [URL]) {
        let route = AttachmentRouting.route(urls, imagesAccepted: core.imagesAccepted)
        let refused = route.refusedImages.map {
            String(
                localized: "\($0.lastPathComponent): \(core.answeringBrainName) can't see images",
                comment: "%1$@ is a file name, %2$@ the answering brain's name (kept untranslated)"
            )
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

    /// A file shared from another app (AirDrop, Files, Share → Open in): staged through the ＋ picker's own
    /// `attach`, so it takes the same route and the same on-device rules (ADR 0010), in a new chat when this one
    /// has messages. Never sent: the person reads what landed and sends it themselves (#893 C).
    private func receiveSharedFiles() {
        guard !sharedFiles.isEmpty else { return }
        switch SharedFileIntake.step(
            isResponding: core.chat.isResponding,
            hasMessages: !core.chat.messages.isEmpty,
            consentPending: privateCloudPending != nil || privateCloudSending
        ) {
        case .wait:
            return
        case .newChatThenStage:
            core.chat.startNewConversation()
            core.turnActivity.turnFinished(.newChat)
        case .stageHere:
            break
        }
        let urls = sharedFiles
        sharedFiles = []
        attach(urls)
        // A page (html, markdown) also opens beside the chat, read now: iOS's copy goes below.
        if let page = urls.lazy.compactMap(Self.sharedPageText).first {
            core.openSharedPage(filename: page.filename, text: page.text)
        }
        // iOS's copy in Documents/Inbox has been read into the composer (text) or the attachment store (images), so
        // it goes. Only these: a batch's siblings may still be on their way (RootView sweeps leftovers on background).
        for url in urls where SharedFileIntake.isSystemInboxCopy(url, documents: URL.documentsDirectory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// What the hint over the composer says while shared files wait, or nil when none do. The phone's `step` does
    /// not wait on voice (the voice cover hides this screen), so `inVoice` is false; a consented send still
    /// launching reads as the reply it starts.
    private var sharedFileHintText: String? {
        SharedFileIntake.waitingHint(count: sharedFiles.count, reason: sharedFileWaitReason)
    }

    /// Why shared files wait, or nil when none do. VoiceOver hears the hint again each time this changes.
    private var sharedFileWaitReason: SharedFileIntake.WaitReason? {
        guard !sharedFiles.isEmpty else { return nil }
        return SharedFileIntake.waitReason(
            isResponding: core.chat.isResponding || privateCloudSending,
            inVoice: false,
            consentPending: privateCloudPending != nil
        )
    }

    /// A plain caption, not glass (the caller sets it on a fixed material capsule): it only tells, and nothing in it
    /// ticks.
    private func sharedFileHint(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "doc.badge.clock")
        }
        .font(.footnote)
        .foregroundStyle(.readableSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// A shared file's name and text when it could be a page (the policy decides), capped like the composer's read.
    private static func sharedPageText(_ url: URL) -> (filename: String, text: String)? {
        guard CodeArtifact.Language(fileExtension: url.pathExtension)?.isRenderable == true else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The size is asked first: a huge page is never read on the main actor just to be refused.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= sharedPageByteCap,
              let data = try? Data(contentsOf: url)
        else { return nil }
        // Older pages are often Latin-1 / Windows-1252; Latin-1 decodes any bytes, so such a page still opens.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return (url.lastPathComponent, text)
    }

    /// The largest shared page opened beside the chat; a bigger one still stages in the composer, truncated.
    private static let sharedPageByteCap = 2_000_000

    private static let attachmentStore = AppCore.attachmentStore
}

/// The brain's tag beside the wordmark, typed on a letter at a time whenever it changes, with a block
/// cursor that goes once the word is whole. Smaller and dimmer than the wordmark on purpose. Reduce
/// Motion shows the word at once.
private struct BrainTagTypeOn: View {
    let tag: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    var body: some View {
        let done = step >= tag.count
        // The whole tag, hidden, holds the width: the wordmark beside it does not shift while it types.
        Text(tag + "▮")
            .font(.pixel(14))
            .hidden()
            .overlay(alignment: .leading) {
                Text(BrainWordmark.typed(tag, step: reduceMotion ? tag.count : step)
                    + (done || reduceMotion ? "" : "▮"))
                    .font(.pixel(14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .task(id: "\(tag)-\(reduceMotion)") {
                step = 0
                guard !reduceMotion else { return }
                // A beat before the first letter, so it reads as M1K3 naming its brain.
                try? await Task.sleep(for: .milliseconds(350))
                for next in 1 ... max(1, tag.count) {
                    guard !Task.isCancelled else { return }
                    step = next
                    try? await Task.sleep(for: .milliseconds(110))
                }
            }
    }
}
