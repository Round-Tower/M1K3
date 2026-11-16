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
        let driver: TurnActivityDriver
        init() {
            let log = log
            let effects = FakeEffects(log)
            let tasks = FakeTasks(log)
            self.effects = effects
            self.tasks = tasks
            driver = TurnActivityDriver(effects: effects, tasks: tasks, sampleInterval: .seconds(3600))
        }

        /// A turn running with its card on screen, the app then sent to the background.
        func runningCard(_ phase: TurnActivityPhase = .thinking) {
            driver.turnBegan { phase }
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
        rig.driver.turnBegan { .thinking }
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

    @Test("no card on screen, nothing to pause, and no task begun for it")
    func nothingToPause() {
        let rig = Rig()
        rig.driver.turnBegan { .thinking }
        rig.driver.leavingForBackground(turnInFlight: true, brainRunsOnThisDevicesGPU: true)
        #expect(rig.tasks.begun.isEmpty)
    }

    @Test("no turn in flight: neither a grace nor a Paused card")
    func idleLeavesNothing() {
        let rig = Rig()
        rig.driver.leavingForBackground(turnInFlight: false, brainRunsOnThisDevicesGPU: false)
        rig.driver.leavingForBackground(turnInFlight: false, brainRunsOnThisDevicesGPU: true)
        #expect(rig.tasks.begun.isEmpty)
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
