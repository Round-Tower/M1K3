//
//  IntelligenceMCPToolsTests.swift
//  M1K3MCPKitTests
//
//  ask_m1k3 + remember against fake handlers — argument validation and
//  passthrough. The live halves (HeadlessAsk, DocumentIngester) carry their
//  own tests in their packages.
//

import Foundation
@testable import M1K3MCPKit
import M1K3Memory
import MCP
import Testing

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private func makeHandlers(log: CallLog, askThrows: Bool = false) -> IntelligenceToolHandlers {
    IntelligenceToolHandlers(
        ask: { question in
            if askThrows { throw MCPVoiceError("M1K3 is in a conversation right now") }
            log.add("ask:\(question)")
            return "Grounded answer [Doc §Heading]"
        },
        remember: { title, text, kind in
            log.add("remember:\(title):\(text.count):\(kind.rawValue)")
            return "Indexed “\(title)” — 2 chunks."
        }
    )
}

private func text(_ result: CallTool.Result) -> String? {
    if case let .text(text, _, _) = result.content.first { return text }
    return nil
}

/// Deterministic job ids ("job-1", "job-2", …) for tests that name them.
private func counterID() -> @Sendable () -> String {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    let box = Box()
    return {
        box.lock.lock(); defer { box.lock.unlock() }
        box.count += 1
        return "job-\(box.count)"
    }
}

/// A one-shot gate so a fake `ask` can block until the test releases it — used to
/// exercise the submit → poll → done lifecycle deterministically.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

struct IntelligenceMCPToolsTests {
    @Test("the surface is ask_m1k3, get_answer, list_jobs, and remember")
    func surface() {
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: CallLog())))
        #expect(registry.tools.map(\.name) == ["ask_m1k3", "get_answer", "list_jobs", "remember"])
    }

    /// Long enough that only a genuinely hung fake could miss it (see the note on
    /// the fast-path tests). Not a product number — production's is
    /// `defaultAskGraceSeconds`.
    private let schedulerTolerantGrace: Double = 60

    @Test("ask_m1k3 passes the question through and returns the answer")
    func askPassthrough() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(
            handlers: makeHandlers(log: log), graceSeconds: schedulerTolerantGrace
        ))
        let result = await registry.call(name: "ask_m1k3", arguments: ["question": .string("what failed?")])
        #expect(result.isError != true)
        #expect(text(result) == "Grounded answer [Doc §Heading]")
        #expect(log.all == ["ask:what failed?"])
    }

    @Test("ask_m1k3 with a missing or blank question is an isError without invoking the brain")
    func askMissingQuestion() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log)))
        let missing = await registry.call(name: "ask_m1k3", arguments: nil)
        let blank = await registry.call(name: "ask_m1k3", arguments: ["question": .string("  ")])
        #expect(missing.isError == true)
        #expect(blank.isError == true)
        #expect(log.all.isEmpty)
    }

    @Test("a busy brain surfaces its message as isError")
    func askBusy() async {
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(
                handlers: makeHandlers(log: CallLog(), askThrows: true),
                graceSeconds: schedulerTolerantGrace
            )
        )
        let result = await registry.call(name: "ask_m1k3", arguments: ["question": .string("hi")])
        #expect(result.isError == true)
        #expect(text(result)?.contains("conversation") == true)
    }

    @Test("a turn that outlives the grace window hands back a job id, fast, instead of blocking")
    func askExceedingGraceReturnsJobId() async {
        // A generation slower than the grace window: ask_m1k3 must return a job
        // id promptly (non-error) rather than block until the client's deadline.
        let handlers = IntelligenceToolHandlers(
            ask: { _ in
                try await Task.sleep(for: .seconds(60))
                return "arrives after the grace window"
            },
            remember: { _, _, _ in "noop" }
        )
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: handlers, graceSeconds: 0.2)
        )
        let start = ContinuousClock.now
        let result = await registry.call(
            name: "ask_m1k3",
            arguments: ["question": .string("why is the sky blue — explain step by step, in great detail?")]
        )
        // The job-id response is the semantic proof of non-blocking: a call
        // that blocked to completion would return the ANSWER inline, never
        // the get_answer pointer. The clock bound only guards "blocked for
        // the whole 60s generation" — kept stall-proof at half the operation,
        // because tight bounds (2s) flaked twice on stalled CI runners
        // (3.9s and 9.1s measured for a ~0.2s return).
        #expect(start.duration(to: .now) < .seconds(30))
        #expect(result.isError != true)
        #expect(text(result)?.contains("get_answer") == true)
    }

    /// ⚠️ GRACE WINDOWS IN THIS FILE ARE SCHEDULER TOLERANCE, NOT THE THING UNDER
    /// TEST. What is asserted is the BEHAVIOUR — a completed job answers inline, an
    /// unfinished one hands back a job id. The seconds only have to be longer than
    /// the cooperative pool takes to run a fake that returns immediately.
    ///
    /// They were 5s, and on 2026-08-12 that went from an occasional flake to a
    /// consistently red CI job — on this branch AND on master — with the five
    /// fast-path tests reporting 7.9-11.7s for work that takes 0.38s locally
    /// (measured 3/3). Nothing was wrong with the code: `askM1K3Handler` spawns the
    /// generation in a `Task` and polls, so the fast path races the SCHEDULER, and
    /// ~2,600 tests running in parallel on a 3-core runner can starve that task for
    /// ten seconds. Three reruns and a fresh-runner retrigger all failed, which is
    /// what ruled out the usual "stalled runner" explanation.
    ///
    /// So the fast-path tests now allow a window no fake could ever legitimately
    /// need. The SLOW-path tests deliberately keep their tiny 0.2s window — that
    /// one IS the thing under test (a turn that outruns the grace must hand back a
    /// job id), and a bigger number would weaken it.
    @Test("a fast brain returns its answer inline within the grace window")
    func askFastReturnsInline() async {
        let log = CallLog()
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log), graceSeconds: schedulerTolerantGrace)
        )
        let result = await registry.call(name: "ask_m1k3", arguments: ["question": .string("what failed?")])
        #expect(result.isError != true)
        #expect(text(result) == "Grounded answer [Doc §Heading]")
        #expect(log.all == ["ask:what failed?"])
    }

    @Test("a long turn returns a job id, then get_answer fetches the result once ready")
    func submitPollLifecycle() async throws {
        let gate = Gate()
        let store = AskJobStore(makeID: { "job-x" })
        let handlers = IntelligenceToolHandlers(
            ask: { _ in
                await gate.wait()
                return "delayed answer [Doc §Heading]"
            },
            remember: { _, _, _ in "noop" }
        )
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: handlers, jobStore: store, graceSeconds: 0.2)
        )

        // Grace expires while the generation is gated → a job id comes back.
        let submit = await registry.call(name: "ask_m1k3", arguments: ["question": .string("the slow one")])
        #expect(submit.isError != true)
        #expect(text(submit)?.contains("job-x") == true)

        // Still gated → get_answer reports it's working, not an error.
        let pending = await registry.call(name: "get_answer", arguments: ["job_id": .string("job-x")])
        #expect(pending.isError != true)
        #expect(text(pending)?.contains("still working") == true)

        // Release the generation, let the detached task write back, then fetch.
        await gate.open()
        try await Task.sleep(for: .milliseconds(150))
        let done = await registry.call(name: "get_answer", arguments: ["job_id": .string("job-x")])
        #expect(done.isError != true)
        #expect(text(done) == "delayed answer [Doc §Heading]")
    }

    @Test("ask_m1k3 with a job_id self-redeems like get_answer — the stale-tool-list escape hatch")
    func askSelfRedeemsJobId() async throws {
        // Issue #2: a client whose cached tool list predates get_answer has no
        // advertised way to redeem a job id. The tool that ISSUED the ticket must
        // be able to redeem it: ask_m1k3 with a job_id behaves as get_answer.
        let gate = Gate()
        let store = AskJobStore(makeID: { "job-x" })
        let handlers = IntelligenceToolHandlers(
            ask: { _ in
                await gate.wait()
                return "delayed answer [Doc §Heading]"
            },
            remember: { _, _, _ in "noop" }
        )
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: handlers, jobStore: store, graceSeconds: 0.2)
        )

        let submit = await registry.call(name: "ask_m1k3", arguments: ["question": .string("the slow one")])
        #expect(text(submit)?.contains("job-x") == true)

        // Still gated → self-redeem reports it's working, not an error.
        let pending = await registry.call(name: "ask_m1k3", arguments: ["job_id": .string("job-x")])
        #expect(pending.isError != true)
        #expect(text(pending)?.contains("still working") == true)

        // Release, let the detached task write back, then redeem via ask_m1k3.
        await gate.open()
        try await Task.sleep(for: .milliseconds(150))
        let done = await registry.call(name: "ask_m1k3", arguments: ["job_id": .string("job-x")])
        #expect(done.isError != true)
        #expect(text(done) == "delayed answer [Doc §Heading]")
    }

    @Test("a job_id wins over a question — a stale client re-sending both redeems, never re-asks")
    func askJobIdWinsOverQuestion() async {
        // A stale client's cached schema still marks question required, so its
        // redemption call may carry both. Redeeming must not spawn a second job.
        let log = CallLog()
        let store = AskJobStore(makeID: { "job-x" })
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log), jobStore: store, graceSeconds: schedulerTolerantGrace)
        )
        let submit = await registry.call(name: "ask_m1k3", arguments: ["question": .string("first ask")])
        #expect(text(submit) == "Grounded answer [Doc §Heading]")

        let redeem = await registry.call(
            name: "ask_m1k3",
            arguments: ["question": .string("first ask"), "job_id": .string("job-x")]
        )
        #expect(redeem.isError != true)
        #expect(text(redeem) == "Grounded answer [Doc §Heading]")
        #expect(log.all == ["ask:first ask"]) // exactly one generation — no re-ask
    }

    @Test("a new question while a job runs returns a busy note naming that job — and queues nothing")
    func askWhileJobRunningIsHonestBusy() async {
        // The app-side ask is single-flight, so a second question WOULD fail
        // anyway — but it used to burn a fresh job id and surface as an error
        // within milliseconds. Now the handler checks the store first and hands
        // back a non-error note naming the running job, so the caller can
        // redeem it (or wait) instead of wondering whether M1K3 is broken.
        let gate = Gate()
        let store = AskJobStore(makeID: counterID())
        let log = CallLog()
        let handlers = IntelligenceToolHandlers(
            ask: { question in
                log.add("ask:\(question)")
                await gate.wait()
                return "slow answer"
            },
            remember: { _, _, _ in "noop" }
        )
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: handlers, jobStore: store, graceSeconds: 0.2)
        )

        let submit = await registry.call(name: "ask_m1k3", arguments: ["question": .string("first")])
        #expect(text(submit)?.contains("job-1") == true)

        let second = await registry.call(name: "ask_m1k3", arguments: ["question": .string("second")])
        #expect(second.isError != true)
        #expect(text(second)?.contains("job-1") == true)
        #expect(text(second)?.contains("wasn’t queued") == true)
        // Exactly one generation ran and exactly one job exists — the second
        // question spawned neither.
        #expect(log.all == ["ask:first"])
        #expect(await store.summaries().count == 1)
        await gate.open()
    }

    @Test("list_jobs shows job ids and states without answer text")
    func listJobsListing() async throws {
        let gate = Gate()
        let store = AskJobStore(makeID: counterID())
        let handlers = IntelligenceToolHandlers(
            ask: { _ in
                await gate.wait()
                return "the finished answer body"
            },
            remember: { _, _, _ in "noop" }
        )
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: handlers, jobStore: store, graceSeconds: 0.2)
        )

        _ = await registry.call(name: "ask_m1k3", arguments: ["question": .string("slow one")])
        let whileRunning = await registry.call(name: "list_jobs", arguments: nil)
        #expect(whileRunning.isError != true)
        #expect(text(whileRunning)?.contains("job-1") == true)
        #expect(text(whileRunning)?.contains("running") == true)

        await gate.open()
        try await Task.sleep(for: .milliseconds(150))
        let afterFinish = await registry.call(name: "list_jobs", arguments: nil)
        #expect(text(afterFinish)?.contains("done") == true)
        // The listing is a recovery index, never a second answer channel.
        #expect(text(afterFinish)?.contains("finished answer body") != true)
    }

    @Test("list_jobs with no jobs says so plainly")
    func listJobsEmpty() async {
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: CallLog())))
        let result = await registry.call(name: "list_jobs", arguments: nil)
        #expect(result.isError != true)
        #expect(text(result)?.contains("No ask_m1k3 jobs") == true)
    }

    @Test("ask_m1k3 with an unknown job_id is a clean isError, not a new generation")
    func askSelfRedeemUnknownJob() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(name: "ask_m1k3", arguments: ["job_id": .string("ghost")])
        #expect(result.isError == true)
        #expect(text(result)?.contains("No such job") == true)
        #expect(log.all.isEmpty)
    }

    @Test("the job-id handoff message names the ask_m1k3 fallback for stale tool lists")
    func jobIdMessageCarriesFallbackHint() async {
        let store = AskJobStore(makeID: { "job-x" })
        let handlers = IntelligenceToolHandlers(
            ask: { _ in
                try await Task.sleep(for: .seconds(60))
                return "never arrives in time"
            },
            remember: { _, _, _ in "noop" }
        )
        let registry = MCPToolRegistry(
            makeIntelligenceToolDefinitions(handlers: handlers, jobStore: store, graceSeconds: 0.2)
        )
        let result = await registry.call(name: "ask_m1k3", arguments: ["question": .string("the slow one")])
        // The hint must name BOTH redemption paths: get_answer for current
        // clients, ask_m1k3-with-job_id for clients with a stale tool list.
        #expect(text(result)?.contains("get_answer") == true)
        #expect(text(result)?.contains("ask_m1k3") == true)
    }

    @Test("get_answer for an unknown job is a clean isError")
    func getAnswerUnknownJob() async {
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: CallLog())))
        let result = await registry.call(name: "get_answer", arguments: ["job_id": .string("ghost")])
        #expect(result.isError == true)
        #expect(text(result)?.contains("No such job") == true)
    }

    @Test("get_answer requires a job_id")
    func getAnswerValidation() async {
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: CallLog())))
        let missing = await registry.call(name: "get_answer", arguments: nil)
        let blank = await registry.call(name: "get_answer", arguments: ["job_id": .string("  ")])
        #expect(missing.isError == true)
        #expect(blank.isError == true)
    }

    @Test("remember passes title and text through")
    func rememberPassthrough() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(
            name: "remember",
            arguments: ["title": .string("Session notes"), "text": .string("The seal failed under load.")]
        )
        #expect(result.isError != true)
        #expect(text(result)?.contains("Session notes") == true)
        #expect(log.all == ["remember:Session notes:27:note"])
    }

    @Test("remember passes a catalogued kind through to the handler")
    func rememberCataloguedKind() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(
            name: "remember",
            arguments: [
                "title": .string("Kev's sister"), "text": .string("Kev's sister is called Aoife."),
                "kind": .string("profile"),
            ]
        )
        #expect(result.isError != true)
        #expect(log.all == ["remember:Kev's sister:29:profile"])
    }

    @Test("an unknown kind label misclassifies to note — it never rejects the fact")
    func rememberUnknownKindFallsBackToNote() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log)))
        let result = await registry.call(
            name: "remember",
            arguments: [
                "title": .string("t1"), "text": .string("a durable fact"),
                "kind": .string("banana"),
            ]
        )
        #expect(result.isError != true)
        #expect(log.all == ["remember:t1:14:note"])
    }

    @Test("the remember schema advertises the catalogued kind vocabulary")
    func rememberSchemaAdvertisesKinds() {
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: CallLog())))
        let remember = registry.tools.first { $0.name == "remember" }
        let schema = String(describing: remember?.inputSchema)
        for kind in MemoryKind.catalogued {
            #expect(schema.contains(kind.rawValue))
        }
        // Optional param: stale clients that don't send it keep working.
        #expect(!schema.contains("\"required\": [\"title\", \"text\", \"kind\"]"))
        // The description PROSE glosses each kind as "<kind> (<gloss>" — the
        // enum array derives from catalogued automatically, but the prose is
        // hand-written; this pin catches a kind added without its gloss.
        for kind in MemoryKind.catalogued {
            #expect(schema.contains("\(kind.rawValue) ("))
        }
    }

    @Test("remember requires both title and text")
    func rememberValidation() async {
        let log = CallLog()
        let registry = MCPToolRegistry(makeIntelligenceToolDefinitions(handlers: makeHandlers(log: log)))
        let noTitle = await registry.call(name: "remember", arguments: ["text": .string("body")])
        let noText = await registry.call(name: "remember", arguments: ["title": .string("t")])
        #expect(noTitle.isError == true)
        #expect(noText.isError == true)
        #expect(log.all.isEmpty)
    }
}
