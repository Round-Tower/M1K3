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
    let onComplete: () -> Void

    @State private var warmingTick = 0
    @State private var lastAlertness: WakeAlertness = .dozing
    @State private var hasGreeted = false
    @State private var hasCommittedNote = false
    @State private var invitePulse = false
    @AppStorage(ReadingMode.storageKey) private var readingMode: ReadingMode = .standard
    @AppStorage(AppEnvironment.voiceCompanionKey) private var voiceCompanion = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            Text("While I wake — set up the room")
                .font(.title3)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.tertiary)

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
            .onSubmit { flow.advance() }
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
            .onChange(of: voiceCompanion) { _, _ in flow.engage() }
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
        HStack(spacing: 16) {
            Button {
                flow.back()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.glass)
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
                flow.advance()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.glass)
            .disabled(!flow.canAdvance)
            .accessibilityLabel("Next card")
        }
    }

    // MARK: - Progress footer (the persistent bottom strip)

    @ViewBuilder private var progressFooter: some View {
        switch flow.completion {
        case .invite:
            Button {
                commitAboutNote()
                onComplete()
            } label: {
                Text("\(WakeProgressCopy.readyLine(name: displayName)) →")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: 360)
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
        Task { await env.speak(WakeProgressCopy.readyLine(name: displayName)) }
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
        Text(text).font(.headline)
    }

    private func cardCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}
