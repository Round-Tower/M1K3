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
    let onComplete: () -> Void

    @State private var warmingTick = 0
    @State private var lastAlertness: WakeAlertness = .dozing
    @State private var hasGreeted = false
    @State private var hasCommittedNote = false
    @State private var invitePulse = false
    @AppStorage(ReadingMode.storageKey) private var readingMode: ReadingMode = .standard
    @AppStorage(AppEnvironment.voiceCompanionKey) private var voiceCompanion = CompanionDefaults.houseCompanion.id
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            // Title, card, arrows and caption share ONE glass surface. The progress footer is
            // deliberately outside it: it re-renders on every download tick, and a glassEffect that
            // does is the known NSGenericException layout crash (ContentView's Mini banner).
            VStack(spacing: 18) {
                Text(flow.userDrivenCompletion ? "Set up the room" : "While I wake — set up the room")
                    .font(.pixel(28))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                card
                    .frame(maxWidth: 460)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                        value: flow.index
                    )

                navigation

                Text("All of this lives in Settings too — skip anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onboardingCard()

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

    // MARK: - Cards

    @ViewBuilder private var card: some View {
        switch flow.current {
        case .aboutYou: aboutYouCard
        case .readingMode: readingModeCard
        case .voice: voiceCard
        case .face: faceCard
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
            if let voiceFraction = env.voiceLoad.fraction {
                ProgressView(value: voiceFraction)
                    .frame(maxWidth: 240)
                    .controlSize(.small)
            }
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
                finish(speakSignOff: true)
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
                    DialUpMuteButton()
                }
            } else {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(WakeProgressCopy.warmingLine(tick: warmingTick))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(4))
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
            try? await Task.sleep(for: chimeLead)
            await env.speak(greeting)
        }
    }

    /// The deck's end: commit the note, the done chord, then (no-wait deck only) one short line in
    /// M1K3's own voice after the chord has landed. `onComplete` never waits on either; the line
    /// may continue into chat. The task holds `env`, not the view, so it outlives the sheet.
    private func finish(speakSignOff: Bool) {
        commitAboutNote()
        env.soundEffects.play(.doneChord)
        if speakSignOff {
            let env = env
            let line = OnboardingVoiceLine.line(isRerun: isRerun)
            Task { @MainActor in
                try? await Task.sleep(for: OnboardingVoiceLine.delayAfterChord)
                guard OnboardingVoiceLine.shouldSpeak(
                    voiceLoad: env.voiceLoad, soundEffectsEnabled: env.soundEffects.isEnabled
                ) else { return }
                await env.speak(line)
            }
        }
        onComplete()
    }

    private func sayHi() {
        env.avatar.setEmotion(.excited)
        Task {
            try? await Task.sleep(for: .seconds(1.8))
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
