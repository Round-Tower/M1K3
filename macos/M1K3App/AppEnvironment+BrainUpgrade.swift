//
//  AppEnvironment+BrainUpgrade.swift
//  M1K3App
//
//  Coordinator for the invitation-first background brain upgrade — now the
//  CAPABILITY LADDER: the offer targets the next rung for THIS Mac
//  (UpgradeTarget: mini → the recommended tier, lil → Big where comfortable),
//  and a "Maybe later" parks the offer instead of burying it — it re-arms
//  only when the small brain visibly struggles (StrugglePolicy: failed turn,
//  long-form ask on Mini, capped-out generation), and three dismissals is a
//  permanent answer (DismissalParkPolicy). Pressure tracks reality, never a
//  timer. All decisions live in the PURE, tested layer (BrainUpgradePolicy /
//  OfferEligibility / SwapSafety / CapabilityLadder, M1K3Inference); this
//  file only gathers live inputs and runs side effects.
//
//  The hard rules, enforced here:
//    · the fetch NEVER touches `modelLoad` or the live provider — it's a
//      disk-only BrainWeightsFetcher snapshot; the readiness gate must not
//      hide a working chat behind an invisible download
//    · no download without the user's tap on the nudge (the repo's signed
//      promise: "downloads only when you ask")
//    · the hot-swap fires only between turns with everything idle
//      (SwapSafety), through the ordinary `selectBrain(.lil)` path
//    · `selectBrain`/the picker route cancel the fetch synchronously first —
//      one writer to the Hub cache; the partial snapshot resumes elsewhere
//    · a fetch "success" is only believed after `isBrainDownloaded` confirms
//      weights on disk (the downloader falls back to a local partial on
//      offline/auth instead of throwing).
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.8 (side-effect glue
//  over 25 pinned transitions; download/swap behaviour is verify-by-launch —
//  named: nudge beat, Settings %, kill-mid-download resume, swap-at-idle toast).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5, 2026-07-03 (capability ladder) — Kev's call:
//  "we've built capabilities, we need to push people towards them." One-shot
//  terminal dismissal → struggle-earned re-offers; hardcoded Lil → the
//  UpgradeTarget rung (Big offered directly on 24GB+ Macs). Two persisted
//  ints replace the dismissal bool; the state machine is unchanged — the park
//  decision arrives through its existing recompute input.

import AppKit
import Foundation
import M1K3Inference
import M1K3MLX
import Network
import os

extension AppEnvironment {
    /// Persisted "Maybe later" count — DismissalParkPolicy turns it into the
    /// live park decision (terminal at three).
    nonisolated static let brainUpgradeDismissCountKey = "brainUpgrade.dismissCount"
    /// Felt struggles since the LAST dismissal — the currency that earns a
    /// re-offer (reset on every dismissal).
    nonisolated static let brainUpgradeStrugglesKey = "brainUpgrade.strugglesSinceDismissal"

    private static let upgradeLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

    /// User-intro earned moment (IntroductionOfferPolicy inputs): completed
    /// exchanges, and the single terminal dismissal.
    nonisolated static let introductionTurnsKey = "introduction.completedTurns"
    nonisolated static let introductionDismissedKey = "introduction.dismissed"

    /// The user-intro beat, same rhythm as the ladder: counted on every
    /// successful answer, offered once when earned. The brain nudge outranks
    /// it (one earned offer at a time — the reduction pass's bottom-slot rule),
    /// so the intro simply waits for a later turn when both qualify.
    func evaluateIntroductionOfferAfterAnswer() {
        let defaults = UserDefaults.standard
        let turns = defaults.integer(forKey: Self.introductionTurnsKey) + 1
        defaults.set(turns, forKey: Self.introductionTurnsKey)
        guard !introductionOffered,
              brainUpgrade != .offered,
              brainUpgrade != .staged(consented: false)
        else { return }
        let profile = (try? store.meta(key: Self.userProfileMetaKey)) ?? nil
        introductionOffered = IntroductionOfferPolicy.shouldOffer(
            profileIsSubstantial: IntroductionOfferPolicy.profileIsSubstantial(profile),
            completedTurns: turns,
            dismissed: defaults.bool(forKey: Self.introductionDismissedKey)
        )
    }

    /// Accepting is just "the floor is yours" — clear the card; ContentView
    /// focuses the input. Whatever they type is a real turn; auto-capture
    /// remembers it. No form, no second surface.
    func acceptIntroductionOffer() {
        introductionOffered = false
    }

    /// One dismissal is terminal — asking twice is creepy, not caring.
    /// Settings → About You remains the manual path.
    func dismissIntroductionOffer() {
        UserDefaults.standard.set(true, forKey: Self.introductionDismissedKey)
        introductionOffered = false
    }

    /// The rung the ladder currently offers on this Mac, or nil at the top.
    var brainUpgradeTarget: BrainTier? {
        UpgradeTarget.nextForThisMac(from: selectedBrain)
    }

    /// Whether the current offer is a struggle-earned RE-offer (drives the
    /// "That one stretched me" copy variant).
    var brainUpgradeIsReOffer: Bool {
        UserDefaults.standard.integer(forKey: Self.brainUpgradeDismissCountKey) > 0
    }

    // MARK: - State recompute (launch + any explicit brain change)

    /// Rebuild the machine from disk facts. State is never persisted, so this
    /// is the self-healing entry: quit mid-download → partial resumes on the
    /// next accepted fetch; failure → clean slate next launch.
    func recomputeBrainUpgradeState() {
        let defaults = UserDefaults.standard
        let target = brainUpgradeTarget
        let parked = DismissalParkPolicy.isParked(
            dismissals: defaults.integer(forKey: Self.brainUpgradeDismissCountKey),
            strugglesSinceLastDismissal: defaults.integer(forKey: Self.brainUpgradeStrugglesKey)
        )
        brainUpgrade = BrainUpgradePolicy.transition(brainUpgrade, on: .recomputed(
            targetInstalled: target.map { isBrainDownloaded($0) } ?? false,
            dismissed: parked,
            hasRung: target != nil
        ))
        // The ladder is terminal once the swap lands (.done, the sole .done entry
        // — via selectBrain's hook → here). Tear down the path monitor so it isn't
        // left running for the session with no consumer; a fresh offer re-arms it.
        if brainUpgrade == .done { stopBrainUpgradePathMonitor() }
    }

    // MARK: - The between-turns beat

    /// Called after EVERY typed turn (success or failure): count struggles
    /// (which can lift a park), then — on successful answers only — maybe
    /// raise the offer, or complete a consented staged swap now that the app
    /// is idle. Failures never trigger an offer on top of the error message;
    /// they just accrue toward the earned re-offer.
    func evaluateBrainUpgradeAfterAnswer(
        questionCharacters: Int,
        answerFailed: Bool,
        generationHitTokenCap: Bool
    ) {
        // Note on generationHitTokenCap: the metrics ride a detached stamp
        // task and record only the LAST generation of a multi-call agent turn
        // — both mean the signal can under-detect (reads false), never
        // over-detect. Fail-safe by construction; failed turns and long asks
        // carry the load. Documented, not fixed (re-plumbing chat.send's
        // return for a bonus signal isn't worth the churn).
        var justUnparked = false
        if StrugglePolicy.isStruggle(
            brain: selectedBrain,
            questionCharacters: questionCharacters,
            answerFailed: answerFailed,
            generationHitTokenCap: generationHitTokenCap
        ) {
            justUnparked = recordStruggle()
        }
        // Never offer on a failed turn — and never in the same breath as the
        // struggle that lifted a park (a capped/garbled answer READS like a
        // failure even when its status is success; the earned re-offer waits
        // for the NEXT clean answer).
        guard !answerFailed, !justUnparked else { return }
        startNetworkMonitorIfNeeded()
        let path = brainUpgradeNetworkPath
        let eligible = OfferEligibility.isEligible(
            target: brainUpgradeTarget,
            targetInstalled: brainUpgradeTarget.map { isBrainDownloaded($0) } ?? false,
            completedAnswers: 1, // this call IS an answer completion
            isResponding: chat.isResponding,
            freeDiskBytes: Self.freeDiskBytes(),
            networkExpensive: path?.isExpensive ?? false,
            networkConstrained: path?.isConstrained ?? false
        )
        brainUpgrade = BrainUpgradePolicy.transition(brainUpgrade, on: .answerCompleted(eligible: eligible))
        attemptAutoSwapIfStaged()
    }

    /// A felt limitation. Increments the persisted counter and, when it lifts
    /// the park, recomputes so the machine re-enters `idle` — the NEXT
    /// successful answer then raises the earned re-offer. Returns true when
    /// this exact struggle lifted the park (the caller skips offering on the
    /// same turn).
    private func recordStruggle() -> Bool {
        let defaults = UserDefaults.standard
        let struggles = defaults.integer(forKey: Self.brainUpgradeStrugglesKey) + 1
        defaults.set(struggles, forKey: Self.brainUpgradeStrugglesKey)
        guard brainUpgrade == .dismissed else { return false }
        let parked = DismissalParkPolicy.isParked(
            dismissals: defaults.integer(forKey: Self.brainUpgradeDismissCountKey),
            strugglesSinceLastDismissal: struggles
        )
        guard !parked else { return false }
        Self.upgradeLog.notice("brain upgrade re-armed after \(struggles) felt struggles")
        recomputeBrainUpgradeState()
        return true
    }

    // MARK: - User actions (the nudge card's two buttons)

    /// "Fetch {target}" — consent captured; the download starts now, invisibly.
    /// From an unconsented staged state this is the one-tap switch instead.
    func acceptBrainUpgrade() {
        let before = brainUpgrade
        brainUpgrade = BrainUpgradePolicy.transition(before, on: .userAccepted)
        switch brainUpgrade {
        case .fetching:
            runBrainUpgradeFetch(attempt: 1)
        case .staged(consented: true):
            attemptAutoSwapIfStaged()
        default:
            break
        }
    }

    /// "Maybe later" — parks the offer (persisted count, struggle counter
    /// reset). Re-arms only through felt struggles; three dismissals is a
    /// permanent answer. Settings/toolbar remain the manual path throughout.
    func dismissBrainUpgrade() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.brainUpgradeDismissCountKey) + 1,
                     forKey: Self.brainUpgradeDismissCountKey)
        defaults.set(0, forKey: Self.brainUpgradeStrugglesKey)
        brainUpgrade = BrainUpgradePolicy.transition(brainUpgrade, on: .userDismissed)
    }

    // MARK: - Fetch

    private func runBrainUpgradeFetch(attempt: Int) {
        guard let target = brainUpgradeTarget, let modelID = target.mlxModelID else { return }
        Self.upgradeLog.notice("background upgrade fetch start (attempt \(attempt)): \(modelID, privacy: .public)")
        // Strong-bind immediately in each closure (weak captures are mutable,
        // so a NESTED @Sendable closure referencing one trips Swift 6 strict
        // concurrency — the "captured var self" error).
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in
                self.brainUpgrade = BrainUpgradePolicy.transition(
                    self.brainUpgrade, on: .fetchProgressed(fraction: fraction)
                )
            }
        }
        // Inherits @MainActor (unstructured Task on an actor-isolated method):
        // the awaits suspend rather than block, and every state write below is
        // main-actor by construction. Holding self for the download's lifetime
        // is fine — AppEnvironment lives as long as the app.
        brainUpgradeFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await BrainWeightsFetcher().fetch(modelID: modelID, progress: progress)
                guard !Task.isCancelled else { return }
                // Believe disk, not the downloader's return (it falls back
                // to a local partial on offline/auth instead of throwing).
                if self.isBrainDownloaded(target) {
                    Self.upgradeLog.notice("background upgrade staged: \(modelID, privacy: .public)")
                    self.brainUpgrade = BrainUpgradePolicy.transition(self.brainUpgrade, on: .fetchSucceeded)
                    // The whole point of the background fetch is you've moved on —
                    // ping that it's downloaded (background-only, opt-in).
                    await self.maybeNotifyDownloadComplete(
                        modelName: target.displayName,
                        appActive: NSApplication.shared.isActive
                    )
                    self.attemptAutoSwapIfStaged()
                } else {
                    self.handleFetchFailure(attempt: attempt, transient: true,
                                            reason: "download incomplete (offline?)")
                }
            } catch is CancellationError {
                // Cancelled by selectBrain/the picker — state already recomputed.
            } catch {
                guard !Task.isCancelled else { return }
                let transient = (error as NSError).domain == NSURLErrorDomain
                self.handleFetchFailure(
                    attempt: attempt, transient: transient,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func handleFetchFailure(attempt: Int, transient: Bool, reason: String) {
        Self.upgradeLog.error("background upgrade fetch failed (attempt \(attempt)): \(reason, privacy: .public)")
        brainUpgrade = BrainUpgradePolicy.transition(
            brainUpgrade, on: .fetchFailed(attempts: attempt, transient: transient)
        )
        // Silent to the chat (the whoa is not interrupted by our retries);
        // Settings' brain section shows the failed row. Backoff then retry.
        // The sleeper is TRACKED (brainUpgradeRetryTask) so a manual brain
        // change cancels it — otherwise it could fire mid-picker-download and
        // become a second, invisible writer to the same Hub cache.
        guard BrainUpgradePolicy.shouldRetry(attempts: attempt, transient: transient) else { return }
        brainUpgradeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt) * 15))
            guard !Task.isCancelled else { return }
            guard let self, case .failed = brainUpgrade else { return }
            brainUpgrade = BrainUpgradePolicy.transition(brainUpgrade, on: .retryStarted)
            runBrainUpgradeFetch(attempt: attempt + 1)
        }
    }

    /// Synchronous cancel — called FIRST by selectBrain / routeToOnboarding-
    /// BrainPicker so there's exactly one writer to the Hub cache dir (the
    /// scheduled retry counts as a writer-to-be). The partial snapshot stays
    /// on disk and resumes wherever it's next wanted.
    func cancelBrainUpgradeFetch() {
        brainUpgradeFetchTask?.cancel()
        brainUpgradeFetchTask = nil
        brainUpgradeRetryTask?.cancel()
        brainUpgradeRetryTask = nil
    }

    // MARK: - Swap

    /// The payoff: consent was captured at the pitch, so once staged the swap
    /// fires automatically — but ONLY with the app fully idle (SwapSafety),
    /// between turns, through the ordinary selectBrain path (short from-disk
    /// load; the toast says what happened).
    func attemptAutoSwapIfStaged() {
        guard BrainUpgradePolicy.wantsAutoSwap(brainUpgrade) else { return }
        guard let target = brainUpgradeTarget else { return }
        guard SwapSafety.canSwap(
            isResponding: chat.isResponding,
            isVoiceModeActive: isVoiceModeActive,
            isListening: isListening,
            modelLoadActive: modelLoad.isActive
        ) else { return } // stay staged; the next answer completion retries
        Self.upgradeLog.notice("background upgrade: swapping to \(target.rawValue, privacy: .public) at idle")
        selectBrain(target) // its hook recomputes brainUpgrade → .done
        showBrainUpgradeNotice("\(target.displayName)'s awake — switched you over.")
    }

    /// Internal (not private): the voice earned-moment path reuses the same
    /// toast slot and MUST get the auto-clear — a directly-set notice would
    /// permanently mask the ingest banner behind it (review catch, 2026-07-03).
    func showBrainUpgradeNotice(_ text: String) {
        brainUpgradeNotice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.brainUpgradeNotice == text { self?.brainUpgradeNotice = nil }
        }
    }

    // MARK: - Inputs

    private func startNetworkMonitorIfNeeded() {
        guard brainUpgrade != .done else { return } // terminal — no offer left to inform
        guard brainUpgradePathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in self.brainUpgradeNetworkPath = path }
        }
        monitor.start(queue: DispatchQueue(label: "app.m1k3.brain-upgrade-path"))
        brainUpgradePathMonitor = monitor
    }

    /// Tear down the path monitor when the ladder is terminal — mirrors
    /// `cancelBrainUpgradeFetch` / `disarmThermalRecovery`. `startNetworkMonitorIfNeeded`
    /// re-arms it when a fresh offer becomes live.
    private func stopBrainUpgradePathMonitor() {
        brainUpgradePathMonitor?.cancel()
        brainUpgradePathMonitor = nil
    }

    private nonisolated static func freeDiskBytes() -> Int64 {
        // Measure on the volume the weights actually land on (Application
        // Support since 2026-07-31 — same volume as the old Caches base, but
        // one source of truth beats a coincidence).
        let url = ModelStoreLocation.llmBase()
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
