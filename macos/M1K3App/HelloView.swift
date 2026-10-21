//
//  HelloView.swift
//  M1K3App
//
//  The ONE first-run screen. The old four-step wizard asked a stranger three
//  engine questions and (on a capable Mac) made them watch a multi-GB download
//  before M1K3 said a word. Now: live face, the privacy line, an optional name,
//  one tap — talking in seconds. Mini-first (Apple Foundation Models, instant,
//  zero download); every engine choice lives in Settings where it always also
//  lived. Defaults-with-disclosure: the caption says what was chosen and that
//  it's one click to change.
//
//  The only decision made here is FirstRunBrainPolicy's (pure, tested): AFM
//  available → Mini now; AFM warming → wait honestly, never download; AFM
//  blocked → the pocket fallback (LFM2, ~630 MB; Lil before 2026-09-06) with an
//  honest size and, when it's user-fixable,
//  the Apple Intelligence pointer. A re-run keeps a non-Mini brain untouched.
//
//  GAP-1 note: `selectBrain` no longer writes the first-run gate key — the
//  onComplete closure in M1K3App owns it — so this view's downloading/failed
//  states can't be swapped out from under themselves mid-fetch.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.85 (flow logic rides
//  tested policy; look/feel + the AFM-unavailable path are verify-by-launch).
//  Prior: none (new file; the wizard it replaces lives on as BrainPickerView).
//  Review: Kev + claude-fable-5, 2026-08-30, Confidence 0.8 — the waits came
//  alive: both the Lil download and the AFM warm now mount WakeSetupCarousel
//  ("set up the room while I wake") instead of a dead bar/spinner. Completion
//  rides WakeSetupFlow's pinned no-yank rule — an untouched deck auto-advances
//  on ready exactly as before; an engaged one gets the invite. The avatar
//  backdrop stays forward during the waits (it wakes as the bar fills — that's
//  the show). Failure UI unchanged. Feel is verify-by-⌘R.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — the fallback copy names the tier the policy chose (pocket: "Mini
//  M1K3, a one-time 630 MB download") instead of hard-coding Lil; the AFM-syncing escape hatch stays Lil explicitly
//  (Apple's Mini is still this Mac's Mini while it syncs). Confidence now 0.8 (copy verify-by-launch on a blocked
//  Mac).
//  Review: Kev + claude-fable-5.1, 2026-09-06 (2) — Try again retries `env.selectedBrain`, the tier that failed;
//  `startFallbackDownload` lost its default so no call site can drift between Lil and pocket (PR #234 review 8).
//  Confidence now 0.8.
//  Review: Kev + claude-opus-4-6, 2026-09-16 — two-door onboarding (#363): "Full experience" writes seven
//  defaults in one pass (OnboardingExperience, pure, 5 tests); "Private" keeps today's defaults. The single
//  "Say hello" button replaced by two vertically stacked buttons with captions. PCC per-message consent
//  unchanged. Confidence now 0.8 (flow logic tested; look/feel verify-by-launch).
//  Review: Kev + claude-opus-4-6, 2026-09-19 — PCC confirmed present in the MAS entitlements
//  (granted 2026-09-14, com.apple.developer.private-cloud-compute); caption is correct.
//  The stale file header comment ("No backend … the only state") predates the grant. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-09-23 — the hello card sits on a material panel: the
//  full-window fox ran through the "Private" door and the disclosure line (seen in the new
//  onboarding plate). Confidence 0.85 (verify-by-launch).
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#479) — "Everything stays on this Mac — no cloud" retired:
//  web search is on by default and PCC is a brain pick in the App Store lane. `privacyLine` names the
//  exits per lane (the DMG has no PCC backend). Pure copy, no seam; verify-by-launch. Confidence 0.8.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (PR #527 fold) — the DMG line names the lookups web search
//  makes (Wikipedia, page fetches carry a query out), matching the chat's egress clause.
//  Review: Kev + claude-opus-4-6, 2026-10-10 — #540 slice 1: symmetric doors (Private writes
//  the off-set, not break); Full calls real setters for calendar/location/notifications
//  (SensePermissionPolicy ceremony, reverts on deny); Return no longer commits Full; name
//  prefilled on re-run with profile "Name:" rewrite; AFM re-probed on scenePhase active;
//  captions lane-honest (no PCC on DMG, no Voice). Re-run is a sheet, not a gate-key flip.
//  Confidence 0.8 (flow logic tested; permission ceremony + sheet are verify-by-launch).
//  Open: the issue's "Currently: Full / Private / Custom" line for re-run (slice 2).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#544 bot pass) — the Full door's ceremony STORES each sense
//  (`SensePermissionPolicy.settledValue`; the first cut only wrote the `false` branches, so Full never turned
//  calendar or location on), and completion waits for it (`settling` disables the doors meanwhile) so the
//  system dialogs fire over a live hello, never a dismissed one. Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#544 pass 2) — the ceremony task is owned by the view and
//  cancelled on disappear; Cancel and interactive dismiss are gated while settling; the direct keys are
//  applied AFTER the ceremony, so a cancelled Full writes nothing.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — "Re-run onboarding… was slow, and I only saw the name page"
//  (TestFlight): (1) the setup deck on EVERY path — a `.setup` phase mounts WakeSetupCarousel with the brain
//  already ready (WakeSetupFlow(brainAlreadyReady:), completion is the tap) after a re-run or a first run on
//  `.keepCurrent`/`.useMini`; the wait phases are unchanged. (2) the first frame is light: AFM availability
//  reads off the main actor in a `.task` (doors wake when it lands), and the live backdrop mounts ~150 ms
//  after the card paints and fades in; OnboardingTrace breadcrumbs (ms since the Re-run tap) record where the
//  time goes. (3) the "Currently: Full / Private / Custom" line on a re-run (closes slice 1's Open).
//  Confidence 0.75 — flow rule + classifier + clock are tested; the speed win is a hypothesis until the
//  TestFlight log, and the sheet is verify-by-launch.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — a re-run's doors never wait on AFM (it
//  never reads it) and a first run's wake after 3 s if the probe hangs; the door copy is a placeholder until
//  AFM lands (no flip under the user); the already-loaded fallback edge shows the deck; the Mini-wait poll
//  reads off the main actor too; the backdrop sleep honours cancellation. Known, accepted: a first-run user
//  who quits mid-deck sees the hello again next launch (the gate flips on the deck's button). Confidence 0.75.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the polish pass (TestFlight 499): every phase centres
//  (`defaultScrollAnchor`, the dead spacers go), the hello card wears the shared Liquid Glass
//  `onboardingCard()` instead of a material panel, and a door tap plays `doorPick` BEFORE the Full door's
//  permission ceremony. Confidence 0.7 (look and sound are verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold, round 2) — sheet minHeight 640 -> 700 (the voice
//  card + nav + 96 pt footer), and `chosenExperience` (set in finishHello) gates the spoken sign-off to the Full door.
//  Confidence 0.7.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (PR 2b) — `privacyLine` is made by `NetworkCrossings`: it no longer says web
//  search is "the one thing that sends anything out" (the model downloads cross too), and still names the lookups. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (PR 2b) — the wait decks start from `WakeSetupCard.waitDeck` (no "My full kit"
//  card beside a download or warm); the no-wait deck keeps `WakeSetupFlow(brainAlreadyReady: true)` and gains the kit. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — K6 minHeight 700 -> 760 (the arithmetic is in the frame's comment; fits a
//  13" Air); K7 the no-wait deck names its cards (`WakeSetupCard.allCases`) now that the bare `WakeSetupFlow()` is the wait deck.
//  Confidence 0.65 (the heights are estimates; verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-21 — the backdrop passes `canSleep: false`: the chat backdrop now sleeps
//  after 90 s idle, and here the face waking as the bar fills is the show, however long the download takes.

import M1K3AgentTools
import M1K3Avatar
import M1K3Inference
import M1K3LogCore
import SwiftUI

// MARK: - Onboarding experience choice

struct HelloView: View {
    @Environment(AppEnvironment.self) private var env
    let onComplete: () -> Void
    var isRerun = false

    private enum Phase: Equatable {
        /// The one screen (copy adapts to AFM availability).
        case hello
        /// AFM assets still syncing — waiting, with an escape to the download.
        case waitingForMini
        /// Lil fallback downloading (`modelLoad` is the active selection's truth).
        case downloading
        /// The setup deck with NO wait: a re-run, or a first run whose brain is already
        /// ready. The user taps through (or straight past) it; nothing auto-advances.
        case setup
    }

    @State private var phase: Phase = .hello
    @State private var userName = ""
    @State private var afm: AFMAvailability = .available
    /// False until the off-main AFM read lands: the doors wait for it (their copy and the
    /// policy depend on it) rather than the first frame blocking on a daemon round-trip.
    @State private var afmKnown = false
    /// The live backdrop mounts AFTER the card is on screen (RealityView + USDZ load is the
    /// heaviest thing on this sheet); the card paints first, the face fades in behind it.
    @State private var backdropReady = false
    /// "Full" / "Private" / "Custom": where the seven experience keys stand now (re-run only).
    @State private var currentDoorLabel: String?
    /// The Full door's permission ceremony is running: doors and Cancel
    /// disabled, the sheet held. The task is owned here so a dismissal cancels
    /// it and nothing of the hello lands after the user walked away.
    @State private var settling = false
    @State private var ceremony: Task<Void, Never>?
    /// The wake-setup deck shown during both waits. Its completion rule (pure,
    /// pinned) owns the no-yank behaviour: an untouched deck auto-advances on
    /// ready exactly like the old spinner did; an engaged one waits for a tap.
    @State private var wakeFlow = WakeSetupFlow(cards: WakeSetupCard.waitDeck)
    /// The door applied in THIS session (set in `finishHello`): only Full gets the spoken sign-off.
    @State private var chosenExperience: OnboardingExperience?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch phase {
                case .hello: helloCard
                case .waitingForMini: waitingCard
                case .downloading: downloadingCard
                case .setup: setupCard
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82),
                value: phase
            )
        }
        // Content shorter than the window sits in the middle on every phase (hello, deck, waits);
        // taller content (a big text size) still scrolls from the top.
        .defaultScrollAnchor(.center, for: .alignment)
        // 760, by arithmetic (ESTIMATES: verify-by-launch). The no-wait deck on the kit card, top to bottom:
        //   window padding 2 x 32 .......................... 64
        //   glass: padding 2 x 30 = 60, title ~34, card slot 310, arrows ~44, caption ~15, 3 gaps x 18 = 54 ... 517
        //   voice-bar slot 14 + kit-bar slot 34 + Done button ~44 + its 6 pt top pad ............ 98
        //   3 gaps x 18 between glass, voice slot, kit slot, footer ................................ 54
        //                                                                                  total ~733
        // The old 700 left it ~33 pt short (the content scrolled). 760 gives ~27 pt of slack for a wrapped line, and
        // the slots stay reserved on every card (gating them per card would move the glass and the arrows on a turn).
        // A 13" MacBook Air is 1470x956 pt: minus the menu bar (~38), the title bar (~28) and a visible Dock (~70) that
        // leaves ~820 pt of window, so 760 fits with ~60 pt to spare.
        .frame(minWidth: 580, minHeight: 760)
        .background {
            // The live face is the room — same full-window reactive backdrop as
            // chat, mounted ONCE outside the phase switch (RealityView identity).
            // He stays FORWARD during the waits now: the carousel's whole
            // metaphor is the face waking up as the bar fills (WakeAlertness),
            // so receding him would hide the show.
            if backdropReady {
                AvatarChatBackground(env: env, isTyping: false, canSleep: false)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeIn(duration: 0.5), value: backdropReady)
        .glassBackdrop()
        .onAppear {
            OnboardingTrace.shared.markOnce("hello first onAppear")
            env.avatar.setEmotion(.happy)
            if isRerun {
                currentDoorLabel = OnboardingExperience.currentLabel(
                    for: OnboardingExperience.current(in: .standard)
                )
                if userName.isEmpty {
                    userName = UserDefaults.standard.string(
                        forKey: AppEnvironment.userDisplayNameKey
                    ) ?? ""
                }
            }
        }
        .task {
            // After the first frame: the AFM probe is a daemon call (seconds on a bad day), so it
            // reads OFF the main actor, and the doors wake when it lands.
            afm = await Self.readAFM()
            afmKnown = true
            OnboardingTrace.shared.markOnce("hello afm read (\(String(describing: afm)))")
        }
        .task {
            // A hung probe must not leave the first-run doors dead: after 3 s they wake on the
            // optimistic default and a late read still corrects `afm`.
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if !afmKnown {
                afmKnown = true
                OnboardingTrace.shared.markOnce("hello afm read timed out (3 s)")
            }
        }
        .task {
            // Let the card paint, then bring the face in behind it.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            backdropReady = true
            OnboardingTrace.shared.markOnce("hello backdrop mounted")
        }
        .onDisappear {
            env.avatar.resetToIdle()
            ceremony?.cancel()
            OnboardingTrace.shared.mark("hello disappeared")
            OnboardingTrace.shared.end()
        }
        .interactiveDismissDisabled(settling)
        .onChange(of: phase) { _, new in
            OnboardingTrace.shared.mark("phase -> \(String(describing: new))")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { afm = await Self.readAFM() }
        }
        .onChange(of: env.modelLoad) { _, state in
            guard case .ready = state, phase == .downloading else { return }
            // No yank: readiness only auto-advances a user who never touched
            // the setup deck (today's behaviour); an engaged one gets the
            // carousel's invite and taps through when ready.
            wakeFlow.markBrainReady()
            if wakeFlow.completion == .autoComplete { onComplete() }
        }
    }

    /// The availability read, off the main actor (see `AppEnvironment.readAFMAvailability`).
    private static func readAFM() async -> AFMAvailability {
        await Task.detached(priority: .userInitiated) { AppEnvironment.readAFMAvailability() }.value
    }

    // MARK: - The one screen

    /// The privacy line App Review reads first (#479), from the one `NetworkCrossings` list: model
    /// downloads and web search in both lanes, plus Private Cloud Compute in the App Store build.
    /// Web search is on by default, so "a switch", never "unless you turn it on".
    private var privacyLine: String {
        NetworkCrossings.helloPrivacyLine(for: NetworkCrossings.Lane(
            privateCloudBackendPresent: AppEnvironment.privateCloudBackend != nil
        ))
    }

    private var helloCard: some View {
        VStack(spacing: 18) {
            Text("M1K3")
                .font(.pixel(40))
                .kerning(2)
                .accessibilityAddTraits(.isHeader)

            Text(privacyLine)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            TextField("What'll I call you? (optional)", text: $userName)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 360)
                .accessibilityLabel("Your name, optional")

            VStack(spacing: 12) {
                experienceButton(
                    .fullExperience,
                    title: needsFallbackDownload ? "Full experience · download & go →" : "Full experience →",
                    caption: fullExperienceCaption,
                    prominent: true
                )
                experienceButton(
                    .privateByDefault,
                    title: needsFallbackDownload ? "Private · download & go →" : "Private →",
                    caption: "All features off. Discover them one by one in Settings.",
                    prominent: false
                )
            }
            .frame(maxWidth: 360)
            .padding(.top, 4)
            // The door titles and captions depend on `afm`; until it lands they render as
            // placeholders rather than painting one answer and flipping to another.
            .redacted(reason: doorsWaitingOnAFM ? .placeholder : [])

            if let currentDoorLabel {
                Text("Currently: \(currentDoorLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Currently set to \(currentDoorLabel)")
            }

            Text(disclosureCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if isRerun {
                Button("Cancel") { onComplete() }
                    .disabled(settling)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            if case .blocked(userFixable: true) = afm, needsFallbackDownload {
                Button("Or turn on Apple Intelligence in System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        // The words sit on a glass card, the face stays the room: the full-window fox
        // ran straight through the "Private" door and the disclosure line, which
        // read as noise in the onboarding plate (2026-09-23 readability pass).
        .onboardingCard()
    }

    /// True when the tested policy would answer this tap with the Lil download
    /// (AFM blocked, no heavier brain already chosen) — drives the honest CTA.
    private var needsFallbackDownload: Bool {
        if case .downloadFallback = FirstRunBrainPolicy.resolve(afm: afm, currentBrain: env.selectedBrain) {
            return true
        }
        return false
    }

    private var fullExperienceCaption: String {
        var parts = ["Notch HUD", "heartbeat", "senses"]
        if AppEnvironment.privateCloudBackend != nil {
            parts.append("Private Cloud Compute (asks per message)")
        }
        return parts.joined(separator: ", ") + " — all on."
    }

    private var disclosureCaption: String {
        switch FirstRunBrainPolicy.resolve(afm: afm, currentBrain: env.selectedBrain) {
        case let .keepCurrent(tier):
            return "Runs on \(tier.displayName), your chosen brain · change anytime in Settings."
        case .useMini, .waitForMini:
            return "Runs on Mini, Apple's on-device model · change anytime in Settings."
        case let .downloadFallback(tier, _):
            return "Apple Intelligence isn't available here, so I'll fetch my own brain — "
                + "\(tier.displayName) M1K3, a one-time \(Self.downloadSize(tier)) download. Still fully on this Mac."
        }
    }

    // MARK: - Setup (no wait: re-run, or a first run whose brain is ready)

    private var setupCard: some View {
        VStack(spacing: 16) {
            // The same deck as the waits, with the brain already ready: no bar, and
            // completion is the tap on the primary button (or past it, skipping everything).
            WakeSetupCarousel(
                flow: $wakeFlow,
                fraction: nil,
                finishTitle: WakeProgressCopy.finishLine(isRerun: isRerun),
                isRerun: isRerun,
                fullDoor: chosenExperience == .fullExperience,
                onComplete: onComplete
            )
        }
    }

    // MARK: - Waiting (AFM assets syncing)

    private var waitingCard: some View {
        VStack(spacing: 16) {
            // Same carousel, indeterminate progress source (O6): the AFM warm
            // is usually short, but it's the same dead wait without this.
            WakeSetupCarousel(flow: $wakeFlow, fraction: nil, onComplete: onComplete)
            // AFM is merely syncing here, so the offered Mini is still Apple's:
            // the escape hatch is Lil, not pocket.
            Button("Use a downloaded brain instead (Lil, \(Self.downloadSize(.lil)))") {
                startFallbackDownload(.lil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task {
            // Re-poll while visible; the moment AFM turns available the same
            // no-yank rule as the download path decides auto-advance vs invite.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if case .available = await Self.readAFM() {
                    env.selectBrain(.mini)
                    wakeFlow.markBrainReady()
                    if wakeFlow.completion == .autoComplete { onComplete() }
                    return
                }
            }
        }
    }

    // MARK: - Downloading (the Lil fallback)

    private var downloadingCard: some View {
        VStack(spacing: 20) {
            switch env.modelLoad {
            case .downloading, .idle, .preparing, .ready:
                // The wait IS the setup time (O1): cards up front, the honest
                // bar + dial-up at the bottom. `.preparing` (downloaded, still
                // loading into RAM) renders as the 99% home stretch rather
                // than a copy-less spinner; `.ready` holds the carousel's own
                // invite state (the no-yank onChange above owns completion).
                WakeSetupCarousel(
                    flow: $wakeFlow,
                    fraction: downloadFraction,
                    onComplete: onComplete
                )
            case .failed:
                VStack(spacing: 10) {
                    Label(env.modelLoad.label(modelName: env.selectedBrain.displayName),
                          systemImage: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    // The tier that failed, never a default: the escape hatch may have
                    // picked Lil while the policy picks pocket (PR #234 review 8).
                    Button("Try again") { startFallbackDownload(env.selectedBrain) }
                        .buttonStyle(.glass)
                    if case .blocked(userFixable: true) = afm {
                        Button("Or turn on Apple Intelligence in System Settings") {
                            openSystemSettings()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The carousel's determinate progress source. `.preparing` is the
    /// post-download RAM load — no honest fraction exists, so show the home
    /// stretch (99% caps below 100 by construction; the ready line owns 100).
    private var downloadFraction: Double {
        switch env.modelLoad {
        case let .downloading(fraction): fraction
        case .preparing, .ready: 0.99
        case .idle, .failed: 0
        }
    }

    @ViewBuilder
    private func experienceButton(
        _ experience: OnboardingExperience, title: String, caption: String, prominent: Bool
    ) -> some View {
        let label = VStack(spacing: 4) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)

        if prominent {
            Button { sayHello(experience: experience) } label: { label }
                .buttonStyle(.glassProminent)
                .disabled(settling || doorsWaitingOnAFM)
        } else {
            Button { sayHello(experience: experience) } label: { label }
                .buttonStyle(.bordered)
                .disabled(settling || doorsWaitingOnAFM)
        }
    }

    /// First run only: the doors' copy and the brain policy read `afm`. A re-run doesn't.
    private var doorsWaitingOnAFM: Bool {
        !afmKnown && !isRerun
    }

    // MARK: - Actions

    private func sayHello(experience: OnboardingExperience = .fullExperience) {
        guard !settling else { return }
        // At the tap, before the Full door's permission ceremony: the click lands with the
        // finger, not after the system sheets.
        env.soundEffects.play(.doorPick)
        guard experience == .fullExperience else {
            finishHello(experience: experience)
            return
        }
        // The ceremony is awaited BEFORE anything is written: the system
        // dialogs fire over this hello (sheet or window), never over a
        // dismissed one, and a Cancel mid-way (the sheet's Esc is blocked,
        // the button disabled, but the view can still go away) leaves the
        // store exactly as it was.
        settling = true
        ceremony = Task { @MainActor in
            await settleFullPermissions()
            settling = false
            guard !Task.isCancelled else { return }
            finishHello(experience: experience)
        }
    }

    private func finishHello(experience: OnboardingExperience) {
        // Direct keys after the ceremony, so a cancelled Full never half-applies
        // (Full's apply skips the three senses the ceremony just stored).
        experience.apply(to: .standard)
        chosenExperience = experience
        // Name first, brain second — the gate key flips in onComplete, and the
        // profile write must land before any window swap. On a re-run, rewrite
        // the profile's "Name:" line (not just seed it) so the system prompt
        // and the greeting stay in sync.
        env.saveFirstRunName(userName, rewriteProfile: isRerun)
        env.avatar.setEmotion(.excited)
        if isRerun {
            showSetupDeck()
            return
        }
        switch FirstRunBrainPolicy.resolve(afm: afm, currentBrain: env.selectedBrain) {
        case let .keepCurrent(tier):
            env.selectBrain(tier)
            showSetupDeck()
        case .useMini:
            env.selectBrain(.mini)
            showSetupDeck()
        case .waitForMini:
            env.selectBrain(.mini)
            phase = .waitingForMini
        case let .downloadFallback(tier, _):
            startFallbackDownload(tier)
        }
    }

    /// The deck with no wait (#540 defect 1): the brain is ready, so the flow starts ready and
    /// completion is the user's tap. Every path without a download or warm lands here.
    private func showSetupDeck() {
        wakeFlow = WakeSetupFlow(cards: WakeSetupCard.allCases, brainAlreadyReady: true)
        phase = .setup
    }

    /// "630 MB" / "2.2 GB" from the tier's own figure — one source for every copy line.
    private static func downloadSize(_ tier: BrainTier) -> String {
        tier.approxDownloadMB.map(BrainTier.downloadSizeLabel(megabytes:)) ?? "small"
    }

    private func startFallbackDownload(_ tier: BrainTier) {
        phase = .downloading
        // selectBrain drives the honest modelLoad bar; this IS the active
        // selection now, so using modelLoad here is correct (unlike the
        // background upgrade, which must never touch it).
        if env.selectBrain(tier) {
            // Already loaded — no transition is coming, so this is a no-wait path: the deck.
            showSetupDeck()
        }
    }

    /// Run the three permission-required keys through real setters in
    /// sequence so the system prompts fire during onboarding, not mid-chat,
    /// and STORE each outcome: granted (before or now) → on, anything else → off.
    /// A cancelled ceremony stores nothing it has not already stored.
    @MainActor
    private func settleFullPermissions() async {
        let calendar = await Self.settle(
            status: ContextSenseAuth.calendarStatus, request: ContextSenseAuth.requestCalendar
        )
        guard !Task.isCancelled else { return }
        UserDefaults.standard.set(calendar, forKey: AppEnvironment.contextCalendarEnabledKey)
        let location = await Self.settle(
            status: ContextSenseAuth.locationStatus, request: ContextSenseAuth.requestLocation
        )
        guard !Task.isCancelled else { return }
        UserDefaults.standard.set(location, forKey: AppEnvironment.contextLocationEnabledKey)
        // Heartbeat notifications: the setter stores the authorization answer itself.
        await env.setHeartbeatNotifications(true)
    }

    /// One sense through the pane's two steps, asking macOS only when the
    /// policy says to; the stored value is the policy's, not this view's.
    @MainActor
    private static func settle(
        status: SensePermissionStatus, request: @MainActor () async -> SensePermissionStatus
    ) async -> Bool {
        let answer: SensePermissionStatus? = if case .request = SensePermissionPolicy.onToggle(
            enabled: true, status: status
        ) { await request() } else { nil }
        return SensePermissionPolicy.settledValue(before: status, answer: answer)
    }

    private func openSystemSettings() {
        // No verified deep link for the Apple Intelligence pane — open System
        // Settings itself rather than guess a pane id that could dead-end.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
