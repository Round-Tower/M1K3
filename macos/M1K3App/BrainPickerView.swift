//
//  BrainPickerView.swift
//  M1K3App
//
//  The standalone brain picker — the honest download UI (explicit Download
//  button, per-tier progress, Try-again/Use-Mini fallback). Reached only by
//  deep link now: Settings → "Change brain…" and the chat toolbar's brain
//  switcher (`routeToOnboardingBrainPicker()`, unchanged). First-run no longer
//  passes through here — HelloView is the one-screen hello, and Mini-first
//  means a stranger never meets a download bar (FirstRunBrainPolicy owns the
//  fallback when Apple Intelligence can't serve).
//
//  This file IS the former OnboardingView's brain step (git mv, 2026-07-03):
//  the four-step flow (You → Brain → Ears → Voice) collapsed to HelloView +
//  Settings — every cut step's action (enableWhisperKit, selectVoiceTier,
//  speakSample, the profile editor) already lived in Settings, so nothing was
//  lost, only relocated. It always completes on wake (the old `startAtBrain`
//  behaviour, now the only behaviour).
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.8,
//  Prior: Kev + claude-opus-4-8 2026-06-08 (single-step brain-only version)
//  Review: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.85 — added the
//  brain-only re-pick entry (startAtBrain) so "Change brain…" deep-links to the
//  brain step and completes on wake instead of restarting the whole flow.
//  Review: Kev + claude-fable-5, 2026-07-02, Confidence 0.85 — fixed the first-run
//  regression (ed711813 shipped opening on .speech); restored the live avatar as
//  the full-window reactive backdrop; step dots + spring transitions.
//  Review: Kev + claude-fable-5, 2026-07-03, Confidence 0.85 — the one-screen
//  collapse: OnboardingView → BrainPickerView. You/Ears/Voice steps, step dots
//  and the Step enum removed (HelloView + Settings own those beats); the brain
//  picker, wake/download screen, alreadyAwake guard and Use-Mini fallback kept
//  byte-equivalent. Look/feel verify-by-launch.
//  Review: Kev + claude-fable-5, 2026-08-30, Confidence 0.85 — background
//  downloads: a pick that needs weights no longer parks you on the progress
//  bar when the current brain can keep serving (stageDirectedBrainFetch +
//  toast + immediate completion; the upgrade ladder's fetch/swap machinery
//  does the rest). The blocking wake screen remains only for the
//  nothing-resident case. Verify-owed: the felt hand-back on ⌘R.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — cards iterate `BrainTier.offered(afm:)` (pocket in Mini's place when
//  Apple Intelligence is blocked); the failed-wake "Use Mini (built-in) instead" escape is hidden on a blocked Mac —
//  it would land on a brain that never answers. Confidence now 0.8 (verify-by-launch on a blocked Mac owed).

import M1K3Avatar
import M1K3Inference
import SwiftUI

struct BrainPickerView: View {
    @Environment(AppEnvironment.self) private var env
    let onComplete: () -> Void

    @State private var selectedBrain: BrainTier = .recommendedForThisMac
    /// "Let M1K3 choose" (auto-route) selected instead of a specific tier. When
    /// true the explicit tier cards show unselected and the button hands the pick
    /// to M1K3 (ADR 0001). Restored from the saved auto-route flag on appear.
    @State private var autoSelected = false
    @State private var isWakingBrain = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Computed, not stored: the badge must land on pocket when Apple
    /// Intelligence is blocked (PR #234 review 1).
    private var recommended: BrainTier {
        BrainTier.recommended(
            forPhysicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            afm: env.afmAvailability
        )
    }

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    var body: some View {
        // ScrollView: the brain cards (plus header and button) outgrow
        // the window on smaller screens — the download button must never be
        // clipped behind a resize.
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                header(
                    title: "Brain",
                    subtitle: isWakingBrain ? "Configuring M1K3's mainframe" : "Pick a brain"
                )

                if isWakingBrain { brainAwakening } else { brainPicker }
                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82),
                value: isWakingBrain
            )
        }
        .frame(minWidth: 580, minHeight: 640)
        .background {
            // The LIVE face is the room, not a picture on the wall: the same
            // full-window reactive backdrop the chat uses, mounted ONCE outside
            // any conditional so the RealityView keeps a stable identity.
            // `isTyping` maps to the download/waking screen — M1K3 steps back
            // while he's working so the progress copy reads.
            AvatarChatBackground(env: env, isTyping: isWakingBrain)
        }
        .glassBackdrop()
        .onAppear {
            // Highlight the brain you're already running — or the Auto card if
            // auto-route is the live choice.
            selectedBrain = env.selectedBrain
            autoSelected = UserDefaults.standard.bool(forKey: AppEnvironment.autoRouteBrainKey)
            env.avatar.setEmotion(.thinking)
        }
        .onDisappear { env.avatar.resetToIdle() }
        .onChange(of: env.modelLoad) { _, state in
            if case .ready = state, isWakingBrain {
                isWakingBrain = false
                onComplete()
            }
        }
    }

    /// Title + subtitle over the live backdrop.
    private func header(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.pixel(40))
                .kerning(2)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
    }

    private var brainPicker: some View {
        VStack(spacing: 16) {
            AutoBrainCard(isSelected: autoSelected) { autoSelected = true }

            // One Mini per Mac: AFM's when it can serve, pocket when it is blocked.
            ForEach(BrainTier.offered(afm: env.afmAvailability)) { tier in
                BrainCard(
                    tier: tier,
                    isSelected: !autoSelected && selectedBrain == tier,
                    isRecommended: tier == recommended,
                    isLocked: !tier.isSelectableOnThisMac,
                    isDownloaded: env.isBrainDownloaded(tier)
                ) {
                    autoSelected = false
                    selectedBrain = tier
                }
            }

            Button(action: wakeBrain) {
                Text(brainButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 4)
        }
    }

    /// Quiet by design (Kev's ⌘R call): no tier glyph, no "Waking up…" title —
    /// the receded avatar backdrop already says who's working. A download shows
    /// its honest progress bar; everything else is just the spinner.
    private var brainAwakening: some View {
        VStack(alignment: .center, spacing: 20) {
            Spacer()

            switch env.modelLoad {
            case let .downloading(fraction):
                VStack(spacing: 6) {
                    Spacer()
                    ProgressView(value: fraction).frame(maxWidth: 320)
                    Text(env.modelLoad.label(modelName: selectedBrain.displayName))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    DialUpMuteButton()
                    Spacer()
                }
            case .failed:
                VStack(spacing: 10) {
                    Label(env.modelLoad.label(modelName: selectedBrain.displayName),
                          systemImage: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Try again") { wakeBrain() }
                        .buttonStyle(.glass)
                    // Only where Apple's Mini can actually serve — on a blocked
                    // Mac the escape would land on a brain that never answers.
                    if !env.afmAvailability.isBlocked {
                        Button("Use Mini (built-in) instead") {
                            selectedBrain = .mini
                            isWakingBrain = false
                            env.selectBrain(.mini)
                            onComplete()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            case .idle, .ready, .preparing:
                ProgressView().controlSize(.large)
            }

            Spacer()
        }
    }

    /// The wake button's label tracks the selection: auto hands the pick to M1K3,
    /// an un-fetched tier offers a download, a ready tier wakes in place.
    private var brainButtonTitle: String {
        if autoSelected { return "Let M1K3 choose →" }
        return selectedBrain.requiresDownload && !env.isBrainDownloaded(selectedBrain)
            ? "Download \(selectedBrain.displayName) →"
            : "Wake up \(selectedBrain.displayName) →"
    }

    private func wakeBrain() {
        // Resolve the concrete tier WITHOUT waking it first — the background
        // path below must decide before selectBrain starts a blocking load.
        let picked = autoSelected ? env.resolvedAutoRouteTier() : selectedBrain

        // Background path: the pick needs a download, but the CURRENT brain can
        // keep serving while it lands. Stage the fetch through the upgrade
        // machinery (the pick IS the consent — it stages consented and
        // hot-swaps at the next idle moment) and hand the room straight back
        // instead of parking the user on a progress bar.
        if picked.requiresDownload, !env.isBrainDownloaded(picked), env.isReady {
            UserDefaults.standard.set(autoSelected, forKey: AppEnvironment.autoRouteBrainKey)
            selectedBrain = picked
            let serving = env.selectedBrain.displayName
            env.stageDirectedBrainFetch(picked)
            env.showBrainUpgradeNotice(
                "I'll keep us on \(serving) while \(picked.displayName) downloads — switching the moment it's ready."
            )
            onComplete()
            return
        }

        // Blocking path — nothing resident to serve meanwhile (or no download
        // needed): the original wake. Auto-route: M1K3 resolves the concrete
        // brain for this Mac, then drives the SAME download/wake path as a
        // manual pick.
        let alreadyAwake: Bool
        if autoSelected {
            let resolved = env.enableAutoRouteForOnboarding()
            selectedBrain = resolved.tier
            alreadyAwake = resolved.alreadyAwake
        } else {
            // A specific pick is sovereign — turn auto-route off so it isn't
            // overridden on the next turn (matters on a re-pick where auto-route
            // was previously on).
            UserDefaults.standard.set(false, forKey: AppEnvironment.autoRouteBrainKey)
            alreadyAwake = env.selectBrain(selectedBrain)
        }
        // Already loaded → selectBrain no-opped and modelLoad will NEVER
        // transition to .ready (it already is), so the waking screen's onChange
        // would spin forever. Complete now. Common case: the launch warm-up made
        // the picked brain ready before the user got here.
        if alreadyAwake || !selectedBrain.requiresDownload {
            onComplete()
        } else {
            isWakingBrain = true
        }
    }
}
