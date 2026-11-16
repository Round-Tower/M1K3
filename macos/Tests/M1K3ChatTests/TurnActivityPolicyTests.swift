import M1K3Chat
import M1K3Inference
import M1K3LiveActivity
import Testing

/// The whole lifecycle decision behind the iPhone's Live Activity: start, update, end. The app
/// target performs the ActivityKit effect; every rule lives here.
struct TurnActivityPolicyTests {
    private func state(_ phase: TurnActivityPhase) -> TurnActivityState {
        TurnActivityState(phase: phase)
    }

    /// A policy with a turn running and an activity already on screen at `phase`.
    private func running(_ phase: TurnActivityPhase = .thinking) -> TurnActivityPolicy {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.progress(phase: phase, elapsed: TurnNotificationPolicy.longTurnThreshold, appActive: true, activitiesEnabled: true)
        return policy
    }

    // MARK: start

    @Test("starts at the same threshold the notification uses, in the foreground")
    func startsAtTheNotificationThreshold() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        let early = policy.progress(phase: .thinking, elapsed: TurnNotificationPolicy.longTurnThreshold - .milliseconds(1),
                                    appActive: true, activitiesEnabled: true)
        #expect(early == .none)
        let at = policy.progress(phase: .thinking, elapsed: TurnNotificationPolicy.longTurnThreshold,
                                 appActive: true, activitiesEnabled: true)
        #expect(at == .start(state(.thinking)))
    }

    @Test("starts with the phase the turn is in, a read included")
    func startsWithCurrentPhase() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        let action = policy.progress(phase: .reading, elapsed: .seconds(9), appActive: true, activitiesEnabled: true)
        #expect(action == .start(state(.reading)))
    }

    @Test("never starts in the background: ActivityKit only requests from the foreground")
    func noStartInBackground() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        #expect(policy.progress(phase: .thinking, elapsed: .seconds(30), appActive: false, activitiesEnabled: true) == .none)
    }

    @Test("never starts when the person turned Live Activities off")
    func noStartWhenDisabled() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        #expect(policy.progress(phase: .thinking, elapsed: .seconds(30), appActive: true, activitiesEnabled: false) == .none)
    }

    @Test("a turn that is not running starts nothing")
    func noStartWithoutATurn() {
        var policy = TurnActivityPolicy()
        #expect(policy.progress(phase: .thinking, elapsed: .seconds(30), appActive: true, activitiesEnabled: true) == .none)
    }

    @Test("one activity at a time: a running one is never started twice")
    func startsOnce() {
        var policy = running()
        #expect(policy.progress(phase: .thinking, elapsed: .seconds(20), appActive: true, activitiesEnabled: true) == .none)
    }

    // MARK: update

    @Test("a phase change updates, throttled to one per interval")
    func updatesAreThrottled() {
        var policy = running(.thinking) // sent at 8 s
        let tooSoon = policy.progress(phase: .answering, elapsed: .seconds(8) + .milliseconds(500),
                                      appActive: true, activitiesEnabled: true)
        #expect(tooSoon == .none)
        // The change is not lost: the next look past the interval sends it.
        let later = policy.progress(phase: .answering, elapsed: .seconds(8) + TurnActivityPolicy.minimumUpdateInterval,
                                    appActive: true, activitiesEnabled: true)
        #expect(later == .update(state(.answering)))
    }

    @Test("the same phase is never re-sent")
    func samePhaseIsQuiet() {
        var policy = running(.thinking)
        #expect(policy.progress(phase: .thinking, elapsed: .seconds(60), appActive: true, activitiesEnabled: true) == .none)
    }

    @Test("progress keeps updating while the app is in the background (an off-GPU turn on a grace task)")
    func updatesContinueInBackground() {
        var policy = running(.thinking)
        let action = policy.progress(phase: .answering, elapsed: .seconds(40), appActive: false, activitiesEnabled: true)
        #expect(action == .update(state(.answering)))
    }

    // MARK: end

    @Test("an answer finishing in the background says ready, and the card stays a while")
    func readyInBackground() {
        var policy = running(.answering)
        let action = policy.turnFinished(.answered, appActive: false)
        #expect(action == .end(final: state(.ready), dismissal: .after(TurnActivityPolicy.readyLingers)))
    }

    @Test("an answer finishing in the foreground ends at once: it is already on screen")
    func noReadyInForeground() {
        var policy = running(.answering)
        #expect(policy.turnFinished(.answered, appActive: true) == .end(final: nil, dismissal: .immediate))
    }

    @Test("failure, the user's stop and a new chat end at once", arguments: [
        TurnActivityPolicy.Outcome.failed, .stopped, .newChat,
    ])
    func endsAtOnce(outcome: TurnActivityPolicy.Outcome) {
        var policy = running(.answering)
        #expect(policy.turnFinished(outcome, appActive: false) == .end(final: nil, dismissal: .immediate))
    }

    @Test("a turn that finishes before the threshold had no activity, so there is nothing to end")
    func quickTurnIsSilent() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        #expect(policy.turnFinished(.answered, appActive: false) == .none)
    }

    // MARK: paused

    @Test("a Lil/Big turn stopped by the background exit shows Paused, not Answer ready")
    func pausedOnBackgroundStop() {
        var policy = running(.answering)
        let action = policy.stoppedByBackground()
        #expect(action == .end(final: state(.paused), dismissal: .after(TurnActivityPolicy.pausedLingers)))
    }

    @Test("the stop that follows the pause does not end the Paused card")
    func theStopAfterThePauseIsIgnored() {
        var policy = running(.answering)
        _ = policy.stoppedByBackground()
        // `chat.stopResponding()` makes the send return as a stopped turn, right after.
        #expect(policy.turnFinished(.stopped, appActive: false) == .none)
    }

    @Test("with no activity on screen there is nothing to pause")
    func nothingToPause() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        #expect(policy.stoppedByBackground() == .none)
    }

    // MARK: return and the next turn

    @Test("coming back to the app ends a lingering Ready or Paused card")
    func foregroundClearsLingering() {
        var ready = running(.answering)
        _ = ready.turnFinished(.answered, appActive: false)
        #expect(ready.appBecameActive() == .end(final: nil, dismissal: .immediate))

        var paused = running(.answering)
        _ = paused.stoppedByBackground()
        #expect(paused.appBecameActive() == .end(final: nil, dismissal: .immediate))
    }

    @Test("coming back mid-turn leaves the running card alone")
    func foregroundKeepsRunning() {
        var policy = running(.thinking)
        #expect(policy.appBecameActive() == .none)
    }

    @Test("a new turn clears a lingering card first: one activity at a time")
    func newTurnClearsLingering() {
        var policy = running(.answering)
        _ = policy.turnFinished(.answered, appActive: false)
        #expect(policy.turnBegan() == .end(final: nil, dismissal: .immediate))
        // And a fresh one can start once it passes the threshold.
        let action = policy.progress(phase: .thinking, elapsed: .seconds(9), appActive: true, activitiesEnabled: true)
        #expect(action == .start(state(.thinking)))
    }

    @Test("Paused, then the turn finishes ANSWERED anyway (the stop lost the race): the answer is real")
    func pausedThenAnsweredIsReadyOrGone() {
        // Away: the answer is ready, so the card says so rather than leaving a stale "Paused".
        var away = running(.answering)
        _ = away.stoppedByBackground()
        #expect(away.turnFinished(.answered, appActive: false)
            == .end(final: state(.ready), dismissal: .after(TurnActivityPolicy.readyLingers)))
        // In front: the answer is on screen, the card just goes.
        var front = running(.answering)
        _ = front.stoppedByBackground()
        #expect(front.turnFinished(.answered, appActive: true) == .end(final: nil, dismissal: .immediate))
    }

    // MARK: leaving the foreground mid-turn (scenePhase .inactive)

    @Test("leaving at 2 s, well under the 8 s rule, starts the card: nothing can start it once we are gone")
    func leavingEarlyStartsTheCard() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        let left = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        #expect(left.action == .start(state(.thinking)))
        #expect(left.reason == .started)
    }

    @Test("leaving at 10 s with the card already shown does not start a second")
    func leavingWithACardIsQuiet() {
        var policy = running(.answering)
        let left = policy.leavingForeground(phase: .answering, activitiesEnabled: true)
        #expect(left.action == .none)
        #expect(left.reason == .alreadyShown)
    }

    @Test("leaving with no turn running does nothing")
    func leavingIdleIsQuiet() {
        var policy = TurnActivityPolicy()
        let left = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        #expect(left.action == .none)
        #expect(left.reason == .noTurn)
    }

    @Test("Live Activities switched off: leaving starts nothing, and says why")
    func leavingWhenDisabled() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        let left = policy.leavingForeground(phase: .thinking, activitiesEnabled: false)
        #expect(left.action == .none)
        #expect(left.reason == .disabled)
    }

    @Test("a transient inactive (Control Center, a system alert) ends its card the moment the app is active again")
    func transientInactiveEndsTheCard() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        #expect(policy.appBecameActive() == .end(final: nil, dismissal: .immediate))
        // The turn then finishes in front: nothing left to end.
        #expect(policy.turnFinished(.answered, appActive: true) == .none)
    }

    @Test("pulling Control Center twice, then leaving for real, still gets a card")
    func leavingAgainAfterATransient() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        _ = policy.appBecameActive()
        let left = policy.leavingForeground(phase: .answering, activitiesEnabled: true)
        #expect(left.action == .start(state(.answering)))
    }

    @Test("a card started on the way out carries the turn through the background to Ready")
    func leavingCardReachesReady() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        #expect(policy.turnFinished(.answered, appActive: false)
            == .end(final: state(.ready), dismissal: .after(TurnActivityPolicy.readyLingers)))
    }

    @Test("a second inactive while the leaving-card is up starts nothing")
    func secondInactiveIsAlreadyShown() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        let again = policy.leavingForeground(phase: .answering, activitiesEnabled: true)
        #expect(again.action == .none)
        #expect(again.reason == .alreadyShown)
    }

    @Test("a new turn clears a leaving-card the last turn never ended, then starts its own")
    func newTurnClearsALeavingCard() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        #expect(policy.turnBegan() == .end(final: nil, dismissal: .immediate))
        #expect(policy.leavingForeground(phase: .reading, activitiesEnabled: true).action == .start(state(.reading)))
    }

    @Test("inactive, background, then back with the turn still running: the card goes, and does not return")
    func leavingThenReturningMidTurn() {
        var policy = TurnActivityPolicy()
        _ = policy.turnBegan()
        _ = policy.leavingForeground(phase: .thinking, activitiesEnabled: true)
        #expect(policy.appBecameActive() == .end(final: nil, dismissal: .immediate))
        #expect(policy.progress(phase: .answering, elapsed: .seconds(30), appActive: true, activitiesEnabled: true) == .none)
    }

    @Test("a card the user's 8 s rule started is NOT ended by a return to the app (the old behaviour stands)")
    func eightSecondCardSurvivesReturn() {
        var policy = running(.thinking)
        #expect(policy.appBecameActive() == .none)
    }

    @Test("a new chat while a turn is still running ends its card and the turn's later finish is quiet")
    func newChatDuringARunningTurn() {
        var policy = running(.answering)
        #expect(policy.turnFinished(.newChat, appActive: true) == .end(final: nil, dismissal: .immediate))
        #expect(policy.turnFinished(.stopped, appActive: true) == .none)
        // A paused card goes too.
        var paused = running(.answering)
        _ = paused.stoppedByBackground()
        #expect(paused.turnFinished(.newChat, appActive: false) == .end(final: nil, dismissal: .immediate))
    }

    @Test("a card the return to the app ended does not start again inside the same turn")
    func noRestartAfterReturn() {
        var policy = running(.answering)
        _ = policy.stoppedByBackground()
        _ = policy.appBecameActive()
        #expect(policy.progress(phase: .answering, elapsed: .seconds(30), appActive: true, activitiesEnabled: true) == .none)
    }

    @Test("a second turn on a clean policy ends nothing at the start")
    func cleanStart() {
        var policy = TurnActivityPolicy()
        #expect(policy.turnBegan() == .none)
    }

    @Test("after an end, the same policy runs the next turn from scratch")
    func reusableAfterEnd() {
        var policy = running(.answering)
        _ = policy.turnFinished(.stopped, appActive: true)
        #expect(policy.turnBegan() == .none)
        #expect(policy.progress(phase: .reading, elapsed: .seconds(9), appActive: true, activitiesEnabled: true)
            == .start(state(.reading)))
    }

    // MARK: the link to the existing routing

    @Test("the tap link opens the chat through the app's own DeepLink")
    func linkOpensChat() {
        #expect(DeepLink(url: TurnActivityLink.url) == .chat)
    }

    @Test("a turn is held on a background-task grace exactly when the background exit does not stop it")
    func graceIsTheComplementOfTheStop() {
        for turn in [true, false] {
            for gpu in [true, false] {
                let stops = BackgroundExitPolicy.stopsTurn(turnInFlight: turn, brainRunsOnThisDevicesGPU: gpu)
                let grace = BackgroundExitPolicy.wantsBackgroundGrace(turnInFlight: turn, brainRunsOnThisDevicesGPU: gpu)
                #expect(!(stops && grace), "turn \(turn) gpu \(gpu): never both")
                #expect(grace == (turn && !gpu))
            }
        }
    }
}
