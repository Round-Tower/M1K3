//
//  WakeSetupCarousel.swift
//  M1K3App
//
//  "Set up the room while I wake" — the card carousel that replaces the dead
//  download/warming waits in HelloView. The user flips freely through optional
//  setup cards (about-you note, reading mode, voice, face) while the honest
//  progress bar + dial-up live at the bottom; the avatar backdrop wakes up AS
//  the bar fills (WakeAlertness), the caption speaks in M1K3's own voice
//  (WakeProgressCopy), and at 100% the payoff is a greeting, not a yank —
//  an engaged user taps through when THEY'RE ready (WakeSetupFlow.completion,
//  pure + pinned; the do-nothing user auto-advances exactly like before).
//
//  Every card is a Settings surface that also fits in a card — nothing here
//  is required, and skipping everything costs nothing.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.8 (flow/copy/ramp
//  ride tested policy; card layout, the pulse on the invite, and the greeting
//  beat are verify-by-⌘R). Prior: none (new file; the cards' actions are the
//  same seams Settings has always owned).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the NO-WAIT deck (`flow.userDrivenCompletion`): heading "Set
//  up the room", a plain primary "Start chatting →" / "Done →" (finishTitle) instead of the "I'm awake"
//  invite, no bar and no pulse; tapping it untouched skips the whole deck. Wait paths unchanged.
//  Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the polish pass (TestFlight 499): title, card, arrows and caption
//  share one Liquid Glass card (the progress footer stays outside it: the glass-on-progress-ticks layout crash);
//  pixel titles; round glass arrows in a GlassEffectContainer; Done / Start chatting and the invite are
//  content-sized glassProminent capsules; earcons on the card turn, the selections, the wake (BEFORE the
//  greeting, which waits ~0.6 s for it) and the done chord, then OnboardingVoiceLine's one line on the no-wait
//  deck. Confidence 0.65 (look and sound are verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push fold) — beside a live download bar the card is material
//  (`onboardingCard(nearLiveProgress:)`), and the footer's height is reserved: the stack is centred, so a footer
//  reflow on a tick would move the glass in the same layout pass — the banner crash class. Confidence 0.7.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold, round 2) — the rule, stated straight: NO TICKING
//  VIEW INSIDE GLASS and tick-stable geometry (body re-evaluation alone is fine). So the voice card shows a static
//  "Downloading…" line while Kokoro loads and the live voice bar sits OUTSIDE the glass in a reserved slot; the
//  download/warming footers are a fixed 96 pt (two-line caption); the card slot has a fixed minHeight (the
//  chevrons stay put); finish() is double-tap armoured and speaks only on the Full door; sleeps honour
//  cancellation; Return on the last card still engages. Confidence 0.7 (layout is verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (PR 2b) — the "My full kit" card closes the no-wait deck (Lil or Big, semantic
//  memory with a brain, Sharper ears, M1K3 Voice; `OnboardingKit` is the pure selection). One tap starts each ticked item
//  through `env.startDownload`; `finish` never waits on them. By the glass rule the rows carry STATIC status only and the
//  live bar sits in `kitLoadSlot`, a fixed 34 pt slot under the glass; rows are a fixed 44 pt; the card slot grew to 310.
//  Wait decks (`WakeSetupCard.waitDeck`) have no kit card. Confidence 0.65 (layout is verify-by-launch).

import M1K3Avatar
import M1K3Inference
import M1K3Voice
import SwiftUI

struct WakeSetupCarousel: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var flow: WakeSetupFlow
    /// Determinate download fraction (brain weights), or nil for the AFM
    /// warming wait (indeterminate — the cycled warming lines carry it).
    let fraction: Double?
    /// The primary button's title in the NO-WAIT deck (`flow.userDrivenCompletion`): "Start
    /// chatting" on a first run, "Done" on a re-run. Unused on the wait paths.
    var finishTitle = "Done"
    /// A re-run of onboarding (picks the sign-off line). Unused on the wait paths.
    var isRerun = false
    /// True when the door chosen in this session was Full: the Private door ("All features off")
    /// gets the done chord but no spoken sign-off. Unused on the wait paths.
    var fullDoor = true
    let onComplete: () -> Void

    @State private var warmingTick = 0
    @State private var lastAlertness: WakeAlertness = .dozing
    @State private var hasGreeted = false
    @State private var hasFinished = false
    @State private var hasCommittedNote = false
    @State private var invitePulse = false
    /// The "My full kit" card's ticks and what the tap started. View state: the no-wait deck mounts the
    /// carousel once, so nothing remounts it (the wait decks have no kit card).
    @State private var kit = OnboardingKit()
    @AppStorage(ReadingMode.storageKey) private var readingMode: ReadingMode = .standard
    @AppStorage(AppEnvironment.voiceCompanionKey) private var voiceCompanion = CompanionDefaults.houseCompanion.id
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            // Title, card, arrows and caption share ONE glass surface. The progress footer is
            // deliberately outside it: a ticking view inside glass, or a tick that moves or resizes
            // it, is the known NSGenericException layout crash (ContentView's Mini banner).
            VStack(spacing: 18) {
                Text(flow.userDrivenCompletion ? "Set up the room" : "While I wake — set up the room")
                    .font(.pixel(28))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                card
                    // A fixed slot sized for the tallest card (the voice card), top-aligned: the
                    // centred stack never re-centres on a card turn, so the chevrons stay put.
                    .frame(maxWidth: 460, minHeight: Self.cardSlotHeight, alignment: .top)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                        value: flow.index
                    )

                navigation

                Text("All of this lives in Settings too — skip anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Glass, except beside a live download bar (see OnboardingGlass).
            .onboardingCard(nearLiveProgress: fraction != nil)

            // Outside the glass, in a reserved slot: the live Kokoro bar (voice card, re-run or no-wait).
            voiceLoadSlot

            // Outside the glass, in a fixed slot: the live bar for the kit the user asked for.
            if flow.cards.contains(.kit) { kitLoadSlot }

            // The download / warming branches reserve a FIXED height (below), so a caption that
            // wraps on some tick can't reflow the centred stack and move the card mid-download.
            progressFooter
                .padding(.top, 6)
        }
        .onChange(of: fraction ?? 0) { _, newValue in
            nudgeAlertness(fraction: newValue)
        }
        .onChange(of: flow.completion) { _, completion in
            if completion == .invite { greetOnce() }
        }
        .onAppear { nudgeAlertness(fraction: fraction ?? 0) }
    }

    /// The tallest card (the voice card: title, two tier rows, sample button, status line) plus
    /// slack for a wrapped tagline. The kit card (title, four fixed-height rows, button, caption) sets the
    /// height now. Cards shorter than this top-align inside it.
    private static let cardSlotHeight: CGFloat = 310
    /// Two caption lines, the bar or spinner, and the mute button.
    private static let footerHeight: CGFloat = 96

    // MARK: - Cards

    @ViewBuilder private var card: some View {
        switch flow.current {
        case .aboutYou: aboutYouCard
        case .readingMode: readingModeCard
        case .voice: voiceCard
        case .face: faceCard
        case .kit: kitCard
        }
    }

    private var aboutYouCard: some View {
        VStack(spacing: 12) {
            cardTitle("About you")
            // The draft binds into the FLOW (not local @State) so it survives
            // HelloView's phase switch remounting the carousel; setNote also
            // marks engagement. Return just moves on — the commit happens
            // exactly once, at completion.
            TextField(
                "Anything I should know? (optional)",
                text: Binding(get: { flow.note }, set: { flow.setNote($0) })
            )
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .onSubmit { turn(forward: true) }
            cardCaption("A line about you seeds my memory — \"I teach primary school\", "
                + "\"short answers, please\". It stays on this Mac, and you can edit it "
                + "any time in Settings → You.")
        }
    }

    private var readingModeCard: some View {
        VStack(spacing: 10) {
            cardTitle("How should my replies read?")
            ForEach(ReadingMode.allCases) { mode in
                Button {
                    env.soundEffects.play(.selectionTick)
                    readingMode = mode
                    flow.engage()
                } label: {
                    HStack(spacing: 10) {
                        SelectionRadio(isSelected: readingMode == mode)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName).font(.headline)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var voiceCard: some View {
        VStack(spacing: 10) {
            cardTitle("How should I sound?")
            ForEach(VoiceTier.allCases) { tier in
                Button {
                    env.soundEffects.play(.selectionTick)
                    env.selectVoiceTier(tier)
                    flow.engage()
                } label: {
                    HStack(spacing: 10) {
                        SelectionRadio(isSelected: env.selectedVoiceTier == tier)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.displayName).font(.headline)
                            Text(tier.tagline).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            // Static while Kokoro loads: the live bar is in `voiceLoadSlot`, OUTSIDE the glass.
            // The line is always laid out, so it never changes the card's height.
            Text(env.voiceLoad.isActive ? "Downloading M1K3 Voice…" : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 16)
            Button("Hear a sample") {
                flow.engage()
                Task { await env.speakSample() }
            }
            .buttonStyle(.glass)
        }
    }

    private var faceCard: some View {
        VStack(spacing: 12) {
            cardTitle("Pick my face")
            // Same roster rule as CompanionSettings: pixel face + constellation +
            // whichever creatures ship installed. The backdrop IS the live preview.
            Picker("Face", selection: $voiceCompanion) {
                Text("Pixel face").tag("")
                Text("Constellation").tag(AppEnvironment.voiceCompanionConstellation)
                ForEach(CompanionSpec.all.filter(CompanionAssets.isInstalled), id: \.id) { spec in
                    Text(spec.displayName).tag(spec.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .onChange(of: voiceCompanion) { _, _ in
                env.soundEffects.play(.selectionTick)
                flow.engage()
            }
            Button("Say hi") {
                flow.engage()
                sayHi()
            }
            .buttonStyle(.glass)
            cardCaption("I'm behind this card — that's the live preview.")
        }
    }

    // MARK: - The kit card ("My full kit")

    /// Fixed row height: a status line replacing a purpose line, or a wrapped failure, never moves the glass.
    private static let kitRowHeight: CGFloat = 44
    /// The kit's live-bar slot under the glass: the bar, one caption line.
    private static let kitSlotHeight: CGFloat = 34

    private var kitCard: some View {
        // Reading `downloadItems` re-evaluates this body on a download tick, which is fine; nothing in
        // here ticks. The rows show STATIC status; the live bar is `kitLoadSlot`, outside the glass.
        let items = env.downloadItems
        let rows = kit.rows(items: items)
        return VStack(spacing: 8) {
            cardTitle("My full kit")
            if kit.isChecking(items: items) {
                kitNote("Looking at what's already on this Mac…")
            } else if kit.hasNothingToOffer(items: items) {
                kitNote("You already have everything I can fetch here. Nothing to download.")
            } else {
                VStack(spacing: 4) {
                    ForEach(rows) { row in kitRow(row) }
                }
                kitAction(items: items)
                cardCaption("One-time downloads. None of your data goes with them.")
            }
        }
        .onAppear { env.refreshDownloads() }
    }

    private func kitNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder private func kitRow(_ row: OnboardingKit.Row) -> some View {
        let item = row.item
        let size = (item.sizeIsApproximate ? "~" : "") + item.bytes.formatted(.byteCount(style: .file))
        if row.status == .offer {
            Toggle(isOn: Binding(
                get: { row.ticked },
                set: { _ in
                    env.soundEffects.play(.selectionTick)
                    kit.toggle(item.kind)
                    flow.engage()
                }
            )) {
                kitRowLabel(name: item.name, size: size, detail: OnboardingKit.shortPurpose(item.kind))
            }
            .toggleStyle(.checkbox)
            .frame(height: Self.kitRowHeight, alignment: .top)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: kitStatusSymbol(row.status))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(row.status == .ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                kitRowLabel(name: item.name, size: size, detail: OnboardingKit.statusLine(row.status) ?? "")
            }
            .frame(height: Self.kitRowHeight, alignment: .top)
            .accessibilityElement(children: .combine)
        }
    }

    private func kitRowLabel(name: String, size: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(size).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kitStatusSymbol(_ status: OnboardingKit.Status) -> String {
        switch status {
        case .offer: "square"
        case .downloading, .preparing: "arrow.down.circle"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// The one primary tap, in a fixed 32 pt slot that holds either the button or its aftermath.
    private func kitAction(items: [DownloadItem]) -> some View {
        let list = kit.startList(items: items)
        let progress = kit.progress(items: items)
        return ZStack {
            if progress.total > 0 {
                Text(progress.isFinished ? "That's the kit. Finish whenever you like." : "Fetching in the background. Carry on, or finish.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                let total = kit.totalBytes(items: items).formatted(.byteCount(style: .file))
                let approx = kit.totalIsApproximate(items: items) ? "~" : ""
                Button(list.isEmpty ? "Get my kit" : "Get my kit (\(approx)\(total))") { getKit(items: items) }
                    .buttonStyle(.glass)
                    .disabled(list.isEmpty)
            }
        }
        .frame(height: 32)
    }

    /// Start every ticked item through the one download verb, then carry on: nothing here awaits a
    /// download, and `finish` never looks at them.
    private func getKit(items: [DownloadItem]) {
        let list = kit.startList(items: items)
        guard !list.isEmpty else { return }
        flow.engage()
        env.soundEffects.play(.selectionTick)
        kit.markStarted(list)
        for kind in list {
            env.startDownload(kind)
        }
    }

    /// The live kit bar, beneath the glass card in a fixed slot (always laid out, so it appearing moves
    /// nothing). It shows while a started item is still arriving; a failed or finished kit stops it.
    private var kitLoadSlot: some View {
        let progress = kit.progress(items: env.downloadItems)
        return ZStack {
            if progress.total > 0, !progress.isFinished {
                VStack(spacing: 4) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text("Fetching your kit · \(progress.ready) of \(progress.total) ready")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .frame(maxWidth: 240)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Fetching your kit, \(progress.ready) of \(progress.total) ready")
            }
        }
        .frame(height: Self.kitSlotHeight)
    }

    /// The live voice-load bar, beneath the glass card and always laid out (14 pt) so it appearing
    /// moves nothing. A nil fraction (preparing) is the indeterminate bar.
    private var voiceLoadSlot: some View {
        ZStack {
            if env.voiceLoad.isActive {
                ProgressView(value: env.voiceLoad.fraction)
                    .frame(maxWidth: 240)
                    .controlSize(.small)
                    .accessibilityLabel("Downloading M1K3 Voice")
            }
        }
        .frame(height: 14)
    }

    // MARK: - Navigation

    private var navigation: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                Button {
                    turn(forward: false)
                } label: {
                    Image(systemName: "chevron.left")
                        .imageScale(.large).fontWeight(.semibold)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                .disabled(!flow.canGoBack)
                .accessibilityLabel("Previous card")

                HStack(spacing: 6) {
                    ForEach(Array(flow.cards.enumerated()), id: \.offset) { position, _ in
                        Circle()
                            .fill(position == flow.index ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityLabel("Card \(flow.index + 1) of \(flow.cards.count)")

                Button {
                    turn(forward: true)
                } label: {
                    Image(systemName: "chevron.right")
                        .imageScale(.large).fontWeight(.semibold)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                .disabled(!flow.canAdvance)
                .accessibilityLabel("Next card")
            }
        }
    }

    /// One card turn, with its whoosh-tick — only when the deck actually moves, so a Return on the
    /// last card (or a disabled edge) stays silent.
    private func turn(forward: Bool) {
        // Return on the last card is still engagement (the old `.onSubmit { flow.advance() }`
        // marked it), even though the deck has nowhere to go.
        flow.engage()
        guard forward ? flow.canAdvance : flow.canGoBack else { return }
        env.soundEffects.play(.cardTurn)
        if forward { flow.advance() } else { flow.back() }
    }

    // MARK: - Progress footer (the persistent bottom strip)

    @ViewBuilder private var progressFooter: some View {
        switch flow.completion {
        case .invite where flow.userDrivenCompletion:
            // No wait: nothing is waking, so no "I'm awake" payoff and no pulse. One clear
            // button; tapping it without touching a card skips the whole deck.
            Button {
                finish(speakSignOff: fullDoor)
            } label: {
                Text("\(finishTitle) →")
                    .font(.headline)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
        case .invite:
            Button {
                // The ready greeting has already spoken; the chord is the whole sign-off.
                finish(speakSignOff: false)
            } label: {
                Text("\(WakeProgressCopy.readyLine(name: displayName)) →")
                    .font(.headline)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
            // The gentle pulse the no-yank rule promises: an invitation that
            // breathes, never a modal shove. Still under Reduce Motion.
            .scaleEffect(invitePulse ? 1.035 : 1.0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: invitePulse
            )
            .onAppear { invitePulse = true }
        case .autoComplete, .keepWaiting:
            if let fraction {
                VStack(spacing: 6) {
                    ProgressView(value: fraction).frame(maxWidth: 320)
                    Text(WakeProgressCopy.line(fraction: fraction, name: displayName))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    DialUpMuteButton()
                }
                .frame(height: Self.footerHeight, alignment: .top)
            } else {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(WakeProgressCopy.warmingLine(tick: warmingTick))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(height: Self.footerHeight, alignment: .top)
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(4)) } catch { return }
                        warmingTick += 1
                    }
                }
            }
        }
    }

    // MARK: - Beats

    /// The wake-up ramp: only poke the avatar when the ALERTNESS band changes,
    /// never per progress tick (setEmotion on every callback would thrash the
    /// face's animation state).
    private func nudgeAlertness(fraction: Double) {
        let alertness = WakeAlertness.at(fraction: fraction, ready: flow.brainReady)
        guard alertness != lastAlertness else { return }
        lastAlertness = alertness
        switch alertness {
        case .dozing: env.avatar.setEmotion(.sleepy)
        case .stirring: env.avatar.setEmotion(.neutral)
        case .alert: env.avatar.setEmotion(.thinking)
        case .awake: env.avatar.setEmotion(.excited)
        }
    }

    /// The 100% payoff, once: M1K3 speaks first, using the name if he has one.
    /// Only on the INVITE path — the do-nothing user gets today's silent
    /// auto-advance, exactly as before.
    private func greetOnce() {
        guard !hasGreeted else { return }
        hasGreeted = true
        env.avatar.setEmotion(.excited)
        // The chime first: earcons are muted the moment M1K3 speaks, so it must start (and mostly
        // ring out) before the greeting does. Only wait for it when it can actually sound.
        env.soundEffects.play(.wakeChime)
        let chimeLead: Duration = env.soundEffects.isEnabled ? .milliseconds(600) : .zero
        let greeting = WakeProgressCopy.readyLine(name: displayName)
        Task {
            do { try await Task.sleep(for: chimeLead) } catch { return }
            await env.speak(greeting)
        }
    }

    /// The deck's end: commit the note, the done chord, then (no-wait deck only) one short line in
    /// M1K3's own voice after the chord has landed. `onComplete` never waits on either; the line
    /// may continue into chat. The task holds `env`, not the view, so it outlives the sheet.
    private func finish(speakSignOff: Bool) {
        // A double-click must not play two chords or queue the line twice.
        guard !hasFinished else { return }
        hasFinished = true
        commitAboutNote()
        env.soundEffects.play(.doneChord)
        if speakSignOff {
            let env = env
            let line = OnboardingVoiceLine.line(isRerun: isRerun)
            Task { @MainActor in
                do { try await Task.sleep(for: OnboardingVoiceLine.delayAfterChord) } catch { return }
                guard OnboardingVoiceLine.shouldSpeak(
                    voiceLoad: env.voiceLoad, soundEffectsEnabled: env.soundEffects.isEnabled, fullDoor: fullDoor
                ) else { return }
                await env.speak(line)
            }
        }
        onComplete()
    }

    private func sayHi() {
        env.avatar.setEmotion(.excited)
        Task {
            do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
            if env.avatar.state.activity == .idle {
                env.avatar.resetToIdle()
            }
        }
    }

    /// The ONE commit point (review catch, PR #155): the invite CTA is the
    /// only writer, so edit-and-resubmit can never stack near-duplicate lines
    /// into the capped profile blob. The guard is just double-tap armour.
    private func commitAboutNote() {
        guard !hasCommittedNote else { return }
        let note = flow.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        hasCommittedNote = true
        env.appendToUserProfile(note)
    }

    private var displayName: String? {
        UserDefaults.standard.string(forKey: AppEnvironment.userDisplayNameKey)
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text).font(.pixelTitle)
    }

    private func cardCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}
