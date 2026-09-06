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
//  blocked → the pocket fallback (LFM2, ~630 MB; Lil before 2026-09-06) with an honest size and, when it's user-fixable,
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

import M1K3Avatar
import M1K3Inference
import SwiftUI

struct HelloView: View {
    @Environment(AppEnvironment.self) private var env
    let onComplete: () -> Void

    private enum Phase: Equatable {
        /// The one screen (copy adapts to AFM availability).
        case hello
        /// AFM assets still syncing — waiting, with an escape to the download.
        case waitingForMini
        /// Lil fallback downloading (`modelLoad` is the active selection's truth).
        case downloading
    }

    @State private var phase: Phase = .hello
    @State private var userName = ""
    @State private var afm: AFMAvailability = .available
    /// The wake-setup deck shown during both waits. Its completion rule (pure,
    /// pinned) owns the no-yank behaviour: an untouched deck auto-advances on
    /// ready exactly like the old spinner did; an engaged one waits for a tap.
    @State private var wakeFlow = WakeSetupFlow()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch phase {
                case .hello: helloCard
                case .waitingForMini: waitingCard
                case .downloading: downloadingCard
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82),
                value: phase
            )
        }
        .frame(minWidth: 580, minHeight: 640)
        .background {
            // The live face is the room — same full-window reactive backdrop as
            // chat, mounted ONCE outside the phase switch (RealityView identity).
            // He stays FORWARD during the waits now: the carousel's whole
            // metaphor is the face waking up as the bar fills (WakeAlertness),
            // so receding him would hide the show.
            AvatarChatBackground(env: env, isTyping: false)
        }
        .glassBackdrop()
        .onAppear {
            afm = env.afmAvailability
            env.avatar.setEmotion(.happy)
        }
        .onDisappear { env.avatar.resetToIdle() }
        .onChange(of: env.modelLoad) { _, state in
            guard case .ready = state, phase == .downloading else { return }
            // No yank: readiness only auto-advances a user who never touched
            // the setup deck (today's behaviour); an engaged one gets the
            // carousel's invite and taps through when ready.
            wakeFlow.markBrainReady()
            if wakeFlow.completion == .autoComplete { onComplete() }
        }
    }

    // MARK: - The one screen

    private var helloCard: some View {
        VStack(spacing: 18) {
            Text("M1K3")
                .font(.pixel(40))
                .kerning(2)
                .accessibilityAddTraits(.isHeader)

            Text("Your local AI companion. Everything stays on this Mac — no cloud, no account.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            TextField("What'll I call you? (optional)", text: $userName)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 360)
                .accessibilityLabel("Your name, optional")
                .onSubmit(sayHello)

            Button(action: sayHello) {
                Text(needsFallbackDownload ? "Download & say hello →" : "Say hello →")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: 360)
            .padding(.top, 4)

            Text(disclosureCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if case .blocked(userFixable: true) = afm, needsFallbackDownload {
                Button("Or turn on Apple Intelligence in System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// True when the tested policy would answer this tap with the Lil download
    /// (AFM blocked, no heavier brain already chosen) — drives the honest CTA.
    private var needsFallbackDownload: Bool {
        if case .downloadFallback = FirstRunBrainPolicy.resolve(afm: afm, currentBrain: env.selectedBrain) {
            return true
        }
        return false
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

    // MARK: - Waiting (AFM assets syncing)

    private var waitingCard: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)
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
            Spacer(minLength: 20)
        }
        .task {
            // Re-poll while visible; the moment AFM turns available the same
            // no-yank rule as the download path decides auto-advance vs invite.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if case .available = env.afmAvailability {
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
            Spacer(minLength: 20)
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
            Spacer(minLength: 20)
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

    // MARK: - Actions

    private func sayHello() {
        // Name first, brain second — the gate key flips in onComplete, and the
        // profile write must land before any window swap.
        env.saveFirstRunName(userName)
        env.avatar.setEmotion(.excited)
        switch FirstRunBrainPolicy.resolve(afm: afm, currentBrain: env.selectedBrain) {
        case let .keepCurrent(tier):
            env.selectBrain(tier)
            onComplete()
        case .useMini:
            env.selectBrain(.mini)
            onComplete()
        case .waitForMini:
            env.selectBrain(.mini)
            phase = .waitingForMini
        case let .downloadFallback(tier, _):
            startFallbackDownload(tier)
        }
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
            // Already loaded (re-run edge) — no transition coming; finish now.
            onComplete()
        }
    }

    private func openSystemSettings() {
        // No verified deep link for the Apple Intelligence pane — open System
        // Settings itself rather than guess a pane id that could dead-end.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
