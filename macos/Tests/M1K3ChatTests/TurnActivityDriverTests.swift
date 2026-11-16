import M1K3Chat
import M1K3Inference
import M1K3LiveActivity
import Testing

/// The effect half of the Live Activity, against fakes of ActivityKit and UIApplication's background tasks:
/// every grace path ends its task exactly once, the expiry ends it before the handler returns, and an
/// on-device (Lil/Big) turn never holds a grace.
@MainActor
struct TurnActivityDriverTests {
    /// One log for both fakes, so the ORDER of card writes and task ends is assertable.
    final class Log {
        var events: [String] = []
    }

    final class FakeEffects: TurnActivityEffects {
        let log: Log
        var appIsActive = true
        /// True while the scene is `.inactive` (a Control Center pull): in front, but not active.
        var isInactive = false
        var appIsInForeground: Bool {
            appIsActive || isInactive
        }

        var activitiesEnabled = true
        init(_ log: Log) {
            self.log = log
        }

        func endStaleCards() async {
            log.events.append("card.stale")
        }

        func start(_ state: TurnActivityState) {
            log.events.append("card.start.\(state.phase.rawValue)")
        }

        func update(_ state: TurnActivityState) async {
            log.events.append("card.update.\(state.phase.rawValue)")
        }

        func end(final: TurnActivityState?, dismissal _: TurnActivityPolicy.Dismissal) async {
            log.events.append("card.end.\(final?.phase.rawValue ?? "none")")
        }
    }

    final class FakeClock {
        var now = ContinuousClock.now
        func advance(_ by: Duration) {
            now += by
        }
    }

    final class FakeNotifier: TurnNotifying {
        let log: Log
        init(_ log: Log) {
            self.log = log
        }

        func post(_ notice: TurnNoticePolicy.Notice) async {
            log.events.append("notice.\(notice)")
        }

        func requestPermissionIfUndecided() async {
            log.events.append("notice.ask")
        }

        func clearDelivered() async {
            log.events.append("notice.clear")
        }
    }

    final class FakeTasks: BackgroundTaskHosting {
        let log: Log
        var refuse = false
        private var next = 100
        private(set) var handlers: [Int: @MainActor () -> Void] = [:]
        private(set) var begun: [String] = []
        private(set) var ended: [Int] = []
        init(_ log: Log) {
            self.log = log
        }

        func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int? {
            guard !refuse else { return nil }
            next += 1
            begun.append(name)
            handlers[next] = onExpiry
            log.events.append("task.begin.\(name)")
            return next
        }

        func end(_ token: Int) {
            ended.append(token)
            log.events.append("task.end")
        }

        func expire(_ token: Int) {
            handlers[token]?()
        }
    }

    @MainActor
    private struct Rig {
        let log = Log()
        let effects: FakeEffects
        let tasks: FakeTasks
        let notifier: FakeNotifier
        let clock = FakeClock()
        let driver: TurnActivityDriver
        init() {
            let log = log
            let effects = FakeEffects(log)
            let tasks = FakeTasks(log)
            self.effects = effects
            let notifier = FakeNotifier(log)
            self.tasks = tasks
            self.notifier = notifier
            let clock = clock
            driver = TurnActivityDriver(
                effects: effects, tasks: tasks, notifier: notifier, sampleInterval: .seconds(3600),
                clock: { clock.now }
            )
        }

        /// A turn running with its card on screen, the app then sent to the background.
        func runningCard(_ phase: TurnActivityPhase = .thinking) {
            driver.turnBegan(kind: .answer) { phase }
            driver.sample(elapsed: TurnNotificationPolicy.longTurnThreshold)
            effects.appIsActive = false
        }
    }

    // MARK: Grace begins and ends exactly once

    @Test("an off-GPU turn leaving the app holds one grace task, however often it is asked")
    func graceBeginsOnce() async {
        let rig = Rig()
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        await rig.driver.settled()
        #expect(rig.tasks.begun == ["app.m1k3.turn"])
    }

    @Test("completion in the background: the card says ready, THEN the task ends, once")
    func graceEndsAfterTheReadyCard() async {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        let events = rig.log.events
        let ready = events.firstIndex(of: "card.end.ready")
        let end = events.firstIndex(of: "task.end")
        #expect(ready != nil && end != nil && ready! < end!)
        #expect(rig.tasks.ended.count == 1)
    }

    @Test("failure and the user's stop end the grace once each", arguments: [
        TurnActivityPolicy.Outcome.failed, .stopped,
    ])
    func graceEndsOnFailureAndStop(outcome: TurnActivityPolicy.Outcome) async {
        let rig = Rig()
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(outcome)
        await rig.driver.settled()
        #expect(rig.tasks.ended.count == 1)
        #expect(rig.log.events.contains("card.end.none"))
    }

    @Test("returning to the app ends the grace at once, and a later finish does not end it twice")
    func graceEndsOnReturn() async {
        let rig = Rig()
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.appBecameActive()
        #expect(rig.tasks.ended.count == 1) // synchronous: no await yet
        rig.effects.appIsActive = true
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(rig.tasks.ended.count == 1)
    }

    @Test("expiry ends the task BEFORE the handler returns, and writes Paused best-effort")
    func expiryEndsSynchronously() async throws {
        let rig = Rig()
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        let token = try #require(rig.tasks.handlers.keys.first)
        rig.tasks.expire(token)
        #expect(rig.tasks.ended == [token]) // no await: ended inside the handler
        await rig.driver.settled()
        #expect(rig.log.events.contains("card.end.paused"))
        // The turn finishing afterwards must not end the already-ended task again.
        rig.driver.turnFinished(.stopped)
        await rig.driver.settled()
        #expect(rig.tasks.ended == [token])
    }

    @Test("iOS refusing the task is survivable: no token, nothing to end")
    func refusedTask() async {
        let rig = Rig()
        rig.tasks.refuse = true
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(rig.tasks.ended.isEmpty)
    }

    @Test("a turn backgrounded before the threshold still gets its grace (there is just no card)")
    func graceWithoutACard() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .thinking }
        rig.effects.appIsActive = false
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(rig.tasks.begun == ["app.m1k3.turn"])
        #expect(rig.tasks.ended.count == 1)
        #expect(!rig.log.events.contains { $0.hasPrefix("card.start") })
    }

    @Test("a turn the driver does not follow (voice) never holds a grace")
    func untrackedTurnHoldsNothing() {
        let rig = Rig()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        #expect(rig.tasks.begun.isEmpty)
    }

    // MARK: Lil/Big and the Paused write

    @Test("Lil/Big (a brain on this GPU) never begin a grace")
    func onDeviceBrainsGetNoGrace() async {
        let rig = Rig()
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        #expect(!rig.tasks.begun.contains("app.m1k3.turn"))
    }

    @Test("the Paused write has its own short task, begun first and ended after the card changed")
    func pausedHasItsOwnTask() async throws {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        let events = rig.log.events
        let begin = events.firstIndex(of: "task.begin.app.m1k3.turn.paused")
        let paused = events.firstIndex(of: "card.end.paused")
        let end = events.firstIndex(of: "task.end")
        #expect(begin != nil && paused != nil && end != nil)
        #expect(try #require(begin) < paused! && paused! < end!)
        #expect(rig.tasks.ended.count == 1)
    }

    @Test("the Paused task's own expiry gives it back")
    func pausedTaskExpiry() throws {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        let token = try #require(rig.tasks.handlers.keys.first)
        rig.tasks.expire(token)
        #expect(rig.tasks.ended == [token])
    }

    @Test("no card on screen: no Paused card, but the stopped answer still earns its notice, on a short task")
    func noCardStillNotifies() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .thinking }
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        #expect(rig.log.events.contains("notice.paused"))
        #expect(!rig.log.events.contains { $0.hasPrefix("card.end") })
        #expect(rig.tasks.begun == ["app.m1k3.turn.paused"])
        #expect(rig.tasks.ended.count == 1)
    }

    @Test("a turn the driver does not follow (voice) stopped by the exit raises nothing")
    func untrackedStopIsQuiet() async {
        let rig = Rig()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        #expect(rig.tasks.begun.isEmpty)
        #expect(!rig.log.events.contains { $0.hasPrefix("notice") })
    }

    @Test("no turn in flight: neither a grace nor a Paused card")
    func idleLeavesNothing() {
        let rig = Rig()
        rig.driver.leavingForBackground(turnInFlight: false, brainRunsOnThisDevicesGPU: false)
        rig.driver.leavingForBackground(turnInFlight: false, brainRunsOnThisDevicesGPU: true)
        #expect(rig.tasks.begun.isEmpty)
    }

    // MARK: The notification

    @Test("an answer landing in the background posts one notice, before the grace task ends")
    func answerNoticeInsideTheGrace() async {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        let events = rig.log.events
        let notice = events.firstIndex(of: "notice.answerReady")
        let end = events.firstIndex(of: "task.end")
        #expect(notice != nil && end != nil && notice! < end!)
        #expect(events.filter { $0.hasPrefix("notice.") }.count == 1)
    }

    @Test("a read says it finished reading")
    func readNotice() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .read) { .reading }
        rig.effects.appIsActive = false
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(rig.log.events.contains("notice.readFinished"))
    }

    @Test("in the foreground there is no notice, and a LONG answer then asks for permission")
    func foregroundAsksNotNotifies() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .answering }
        rig.clock.advance(TurnNotificationPolicy.longTurnThreshold)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(rig.log.events.contains("notice.ask"))
        #expect(!rig.log.events.contains { $0.hasPrefix("notice.answer") || $0 == "notice.paused" })
    }

    @Test("a quick answer in the foreground neither notifies nor asks")
    func quickAnswerIsSilent() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .answering }
        rig.clock.advance(.seconds(2))
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(!rig.log.events.contains { $0.hasPrefix("notice.") })
    }

    @Test("failure and the user's stop raise no notice")
    func noNoticeForFailureOrStop() async {
        for outcome in [TurnActivityPolicy.Outcome.failed, .stopped] {
            let rig = Rig()
            rig.runningCard()
            rig.driver.turnFinished(outcome)
            await rig.driver.settled()
            #expect(!rig.log.events.contains { $0.hasPrefix("notice.") })
        }
    }

    @Test("a Paused stop, then the stop that follows it: one Paused notice, and no false 'ready'")
    func pausedThenTheStopIsQuiet() async {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        rig.driver.turnFinished(.stopped) // the stop that follows the pause: quiet
        await rig.driver.settled()
        #expect(rig.log.events.filter { $0 == "notice.paused" }.count == 1)
        #expect(!rig.log.events.contains("notice.answerReady"))
    }

    @Test("Paused, then the answer lands anyway (the stop lost the race): Paused first, then Ready")
    func pausedThenAnsweredNotifiesReady() async {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        let events = rig.log.events
        let paused = events.firstIndex(of: "notice.paused")
        let ready = events.firstIndex(of: "notice.answerReady")
        #expect(paused != nil && ready != nil && paused! < ready!)
        #expect(events.contains("card.end.ready"))
    }

    @Test("grace expiry, then the turn answers after all: Paused, then Ready")
    func expiredThenAnswered() async throws {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        try rig.tasks.expire(#require(rig.tasks.handlers.keys.first))
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        let events = rig.log.events
        let paused = events.firstIndex(of: "notice.paused")
        let ready = events.firstIndex(of: "notice.answerReady")
        #expect(paused != nil && ready != nil && paused! < ready!)
        #expect(rig.tasks.ended.count == 1)
    }

    @Test("a turn landing while the scene is merely inactive posts no notice and asks for no permission")
    func inactiveIsNotBackground() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .answering }
        rig.clock.advance(.seconds(20))
        rig.effects.appIsActive = false
        rig.effects.isInactive = true
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(!rig.log.events.contains { $0.hasPrefix("notice.") })
        // The card is in front too: it ends, rather than lingering as Ready.
        #expect(!rig.log.events.contains("card.end.ready"))
    }

    @Test("a second inactive while the leaving-card is up starts nothing")
    func secondInactiveIsQuiet() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .thinking }
        #expect(rig.driver.leavingForeground() == .started)
        #expect(rig.driver.leavingForeground() == .alreadyShown)
        await rig.driver.settled()
        #expect(rig.log.events.filter { $0.hasPrefix("card.start") }.count == 1)
    }

    @Test("inactive, background, back with the turn still running: the card goes, the grace is given back")
    func leaveAndReturnMidTurn() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .answering }
        rig.driver.leavingForeground()
        rig.effects.appIsActive = false
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.effects.appIsActive = true
        rig.driver.appBecameActive()
        await rig.driver.settled()
        #expect(rig.log.events.contains("card.end.none"))
        #expect(rig.tasks.ended.count == 1)
        rig.driver.sample(elapsed: .seconds(30))
        await rig.driver.settled()
        #expect(rig.log.events.filter { $0.hasPrefix("card.start") }.count == 1)
    }

    @Test("grace expiry tells the person the answer paused")
    func expiryNotifies() async throws {
        let rig = Rig()
        rig.runningCard()
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        try rig.tasks.expire(#require(rig.tasks.handlers.keys.first))
        await rig.driver.settled()
        #expect(rig.log.events.contains("notice.paused"))
    }

    @Test("coming back clears the delivered notices")
    func returnClears() async {
        let rig = Rig()
        rig.driver.appBecameActive()
        await rig.driver.settled()
        #expect(rig.log.events.contains("notice.clear"))
    }

    // MARK: Leaving mid-turn

    @Test("going inactive at 2 s starts the card now, with the phase the turn is in")
    func inactiveStartsTheCard() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .thinking }
        rig.clock.advance(.seconds(2))
        #expect(rig.driver.leavingForeground() == .started)
        await rig.driver.settled()
        #expect(rig.log.events.contains("card.start.thinking"))
    }

    @Test("going inactive with nothing running, or with Live Activities off, starts nothing and says why")
    func inactiveWithoutAReason() async {
        let idle = Rig()
        #expect(idle.driver.leavingForeground() == .noTurn)
        let off = Rig()
        off.effects.activitiesEnabled = false
        off.driver.turnBegan(kind: .answer) { .thinking }
        #expect(off.driver.leavingForeground() == .disabled)
        await off.driver.settled()
        #expect(!off.log.events.contains { $0.hasPrefix("card.start") })
    }

    @Test("a pulled Control Center: inactive then active again takes the card back down")
    func transientInactive() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .thinking }
        rig.driver.leavingForeground()
        rig.driver.appBecameActive()
        await rig.driver.settled()
        let events = rig.log.events
        let start = events.firstIndex(of: "card.start.thinking")
        let end = events.firstIndex(of: "card.end.none")
        #expect(start != nil && end != nil && start! < end!)
    }

    @Test("inactive then background for a Mini turn: the card exists, the grace holds, Ready and the notice follow")
    func inactiveThenBackgroundThenReady() async {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { .answering }
        rig.driver.leavingForeground()
        rig.effects.appIsActive = false
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        let events = rig.log.events
        #expect(events.contains("card.start.answering"))
        #expect(events.contains("card.end.ready"))
        #expect(events.contains("notice.answerReady"))
        #expect(rig.tasks.ended.count == 1)
    }

    // MARK: Lil/Big stopped at .inactive (#858) with the card

    /// Foreground, a turn begun, the leaving-card started: the state at the moment `.inactive` arrives.
    private func inactiveRig(phase: TurnActivityPhase = .answering) -> Rig {
        let rig = Rig()
        rig.driver.turnBegan(kind: .answer) { phase }
        rig.driver.leavingForeground()
        return rig
    }

    @Test("Lil at .inactive: card starts, then Paused, then the stop's finish is quiet; the notice waits for .background")
    func onDeviceInactiveThenRealExit() async {
        let rig = inactiveRig()
        rig.driver.stoppingAtInactive(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        rig.driver.turnFinished(.stopped) // what chat.stopResponding() leads to
        await rig.driver.settled()
        var events = rig.log.events
        let start = events.firstIndex(of: "card.start.answering")
        let paused = events.firstIndex(of: "card.end.paused")
        #expect(start != nil && paused != nil && start! < paused!)
        #expect(!events.contains("card.end.none"), "the stop must not end the Paused card")
        #expect(!events.contains { $0.hasPrefix("notice.") }, "still in front: no notice yet")
        // The exit turns out to be real: .background, with nothing left in flight.
        rig.effects.appIsActive = false
        rig.driver.leavingForBackground(turnInFlight: false, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        events = rig.log.events
        #expect(events.filter { $0 == "notice.paused" }.count == 1)
        #expect(rig.tasks.ended.count == rig.tasks.begun.count, "every short task given back")
    }

    @Test("a Control Center pull with Lil: Paused card, no notice, and the card is cleared when active again")
    func onDeviceTransientPull() async {
        let rig = inactiveRig()
        rig.driver.stoppingAtInactive(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        rig.driver.turnFinished(.stopped)
        rig.driver.appBecameActive()
        await rig.driver.settled()
        #expect(!rig.log.events.contains("notice.paused"))
        #expect(rig.log.events.contains("card.end.none"))
        // A later real exit has nothing left to announce.
        rig.effects.appIsActive = false
        rig.driver.leavingForBackground(turnInFlight: false, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        #expect(!rig.log.events.contains("notice.paused"))
    }

    @Test("Mini at .inactive: nothing is paused; the grace comes at .background and Ready follows")
    func offGPUInactiveChangesNothing() async {
        let rig = inactiveRig()
        rig.driver.stoppingAtInactive(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        #expect(rig.tasks.begun.isEmpty)
        rig.effects.appIsActive = false
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: false)
        rig.driver.turnFinished(.answered)
        await rig.driver.settled()
        #expect(rig.tasks.begun == ["app.m1k3.turn"])
        #expect(rig.log.events.contains("card.end.ready"))
        #expect(rig.log.events.contains("notice.answerReady"))
        #expect(!rig.log.events.contains("card.end.paused"))
    }

    @Test("the missed-inactive path still works: .background with the turn draining pauses and notifies once")
    func backgroundWithoutInactive() async {
        let rig = Rig()
        rig.runningCard(.answering)
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        #expect(rig.log.events.filter { $0 == "notice.paused" }.count == 1)
        #expect(rig.log.events.contains("card.end.paused"))
    }

    @Test("an untracked turn (voice) stopped at .inactive writes nothing")
    func untrackedInactiveStop() async {
        let rig = Rig()
        rig.driver.stoppingAtInactive(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        await rig.driver.settled()
        #expect(rig.tasks.begun.isEmpty)
        #expect(!rig.log.events.contains { $0.hasPrefix("card.start") || $0.hasPrefix("card.end") })
        #expect(!rig.log.events.contains("notice.paused"))
    }

    // MARK: Effects in order

    @Test("a stale card from a killed process is cleared before anything starts")
    func staleCardClearedFirst() async {
        let rig = Rig()
        rig.runningCard()
        await rig.driver.settled()
        #expect(rig.log.events.first == "card.stale")
        #expect(rig.log.events.contains("card.start.thinking"))
    }

    @Test("Live Activities switched off: the card never starts")
    func disabledNeverStarts() async {
        let rig = Rig()
        rig.effects.activitiesEnabled = false
        rig.runningCard()
        await rig.driver.settled()
        #expect(!rig.log.events.contains { $0.hasPrefix("card.start") })
    }
}
