//
//  IntelligenceMCPTools.swift
//  M1K3MCPKit
//
//  The resident-and-visitor tools: `ask_m1k3` reaches the local brain (a
//  grounded, cited answer from the full RAG/agent pipeline) and `remember`
//  writes into the permanent knowledge store — the durable-memory primitive
//  ("index this for M1K3") that makes the store more useful to a visiting
//  agent than its own session notes: queryable, section-attributed,
//  surviving every context window.
//
//  Handlers are app-injected closures (the VoiceToolHandlers pattern) — this
//  package stays free of inference/store links.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (contract
//  test-pinned with fakes; live behaviour rides tested seams — HeadlessAsk
//  in M1K3Chat, DocumentIngester in M1K3Knowledge). Prior: the MCP test
//  report 2026-06-11 (F5) + the resident/visitor reflection.
//
//  Review: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.8. Wired the
//  AsyncTimeout helper into ask_m1k3 so a runaway think-phase surfaced a clean
//  message instead of a raw -32001 at the MCP client's ~60s request deadline.
//
//  Review: Kev + claude-opus-4-8, 2026-07-01, Confidence 0.85. Replaced that
//  request-path timeout with a HYBRID submit-and-poll: a long turn (web search +
//  a verbose thinker) genuinely can't finish inside the client's deadline, so
//  ask_m1k3 now submits the generation to an AskJobStore, waits a short GRACE
//  window (the common fast case still returns the answer inline, unchanged), and
//  otherwise returns a job id the client fetches later via the new get_answer
//  tool. The generation runs detached with its own cap (inside handlers.ask), so
//  it finishes and is fetchable even after this request returns. Build/⌘R verify
//  pending — the live wire (job survival across stateless requests) is verify-by-launch.
//
//  Review: Kev + claude-fable-5, 2026-07-02, Confidence 0.9 (Issue #2). ask_m1k3
//  now self-redeems: an optional job_id argument fetches that job's result via
//  the same redeemJob path as get_answer, so a client whose cached tool list
//  predates get_answer can always redeem the ticket the tool itself issued —
//  the stateless transport can't announce tools/list_changed, so the fallback
//  lives in the tool that hands out the id. job_id wins over question (a stale
//  client's schema still requires question, so redemption calls may carry both).
//  Test-pinned with fakes, incl. the no-second-generation invariant.
//
//  Review: Kev + claude-fable-5, 2026-08-19, Confidence 0.9. The async package:
//  a second question while a job runs now returns a non-error busy note naming
//  the running job (it used to burn a fresh id and bounce as an error in
//  milliseconds — "broken", not "busy"); new list_jobs recovery tool (ids/state/
//  age, never answer text). Pairs with the app-side change that turned the 120s
//  cancel-the-work deadline into a 600s runaway backstop — a slow Big answer now
//  finishes and stays redeemable for the job store's full retention.
//

import Foundation
import M1K3Memory
import MCP

/// The app-injected implementations behind the intelligence tools.
public struct IntelligenceToolHandlers: Sendable {
    /// Ask the active brain. Returns the final answer text (citations intact,
    /// reasoning stripped, sources appended).
    public var ask: @Sendable (_ question: String) async throws -> String
    /// Index text into the knowledge store. Returns a human confirmation
    /// ("Indexed "Title" — 4 chunks."). `kind` is the caller's classification
    /// for the memory-graph node — already validated to the catalogued set
    /// (an off-vocabulary label arrives here as `.note`).
    public var remember: @Sendable (_ title: String, _ text: String, _ kind: MemoryKind) async throws -> String

    public init(
        ask: @escaping @Sendable (_ question: String) async throws -> String,
        remember: @escaping @Sendable (_ title: String, _ text: String, _ kind: MemoryKind) async throws -> String
    ) {
        self.ask = ask
        self.remember = remember
    }
}

/// How long `ask_m1k3` waits inline before handing back a job id to poll. Kept
/// well under the MCP client's ~60s request deadline: the common fast answer
/// still returns within this window (contract unchanged), while a genuinely long
/// turn hands back a job id instead of dying on the wire. The generation keeps
/// running detached and is fetched via `get_answer`.
public let defaultAskGraceSeconds: Double = 8

public func makeIntelligenceToolDefinitions(
    handlers: IntelligenceToolHandlers,
    jobStore: AskJobStore = AskJobStore(),
    graceSeconds: Double = defaultAskGraceSeconds
) -> [MCPToolDefinition] {
    [
        askM1K3Definition(handlers: handlers, jobStore: jobStore, graceSeconds: graceSeconds),
        getAnswerDefinition(jobStore: jobStore),
        listJobsDefinition(jobStore: jobStore),
        rememberDefinition(handlers: handlers),
    ]
}

private func askM1K3Definition(
    handlers: IntelligenceToolHandlers,
    jobStore: AskJobStore,
    graceSeconds: Double
) -> MCPToolDefinition {
    MCPToolDefinition(
        tool: Tool(
            name: "ask_m1k3",
            description: "Ask M1K3's local brain a question. The answer is grounded in M1K3's "
                + "private knowledge store with section-level citations, and may use web search if "
                + "the user has it enabled in M1K3's settings. Fully local inference. Fast answers "
                + "return inline; a long turn (web search on a larger brain) instead returns a job id "
                + "— redeem it in a few seconds via get_answer, or by calling this tool again with "
                + "just the job_id. Check get_status for which brain is active.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "the question to ask (omit when redeeming a job_id)"],
                    "job_id": [
                        "type": "string",
                        "description": "a job id a previous ask_m1k3 call returned — fetches that result instead of asking a new question",
                    ],
                ],
                "required": [],
            ]
        ),
        handler: askM1K3Handler(handlers: handlers, jobStore: jobStore, graceSeconds: graceSeconds)
    )
}

private func getAnswerDefinition(jobStore: AskJobStore) -> MCPToolDefinition {
    MCPToolDefinition(
        tool: Tool(
            name: "get_answer",
            description: "Fetch the result of an ask_m1k3 call that returned a job id because it "
                + "was taking a while. Returns the grounded answer once ready, or asks you to poll "
                + "again if M1K3 is still working. Only needed when ask_m1k3 handed back a job id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string", "description": "the job id ask_m1k3 returned"],
                ],
                "required": ["job_id"],
            ]
        ),
        handler: getAnswerHandler(jobStore: jobStore)
    )
}

private func listJobsDefinition(jobStore: AskJobStore) -> MCPToolDefinition {
    MCPToolDefinition(
        tool: Tool(
            name: "list_jobs",
            description: "List recent ask_m1k3 jobs — id, state (running/done/error), and age in "
                + "seconds. Use this to recover a job id you lost; redeem a done job via get_answer. "
                + "Never contains answer text.",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        handler: { _ in
            let summaries = await jobStore.summaries()
            guard !summaries.isEmpty else {
                return "No ask_m1k3 jobs in the last few minutes."
            }
            // Stable key order — clients parse this; one JSON object per line.
            return summaries.map { summary in
                "{\"job_id\":\"\(summary.id)\",\"state\":\"\(summary.state)\",\"age_s\":\(summary.ageSeconds)}"
            }.joined(separator: "\n")
        }
    )
}

private func rememberDefinition(handlers: IntelligenceToolHandlers) -> MCPToolDefinition {
    MCPToolDefinition(
        tool: Tool(
            name: "remember",
            description: "Store text in M1K3's memory — it becomes part of what M1K3 knows, "
                + "searchable in every future conversation (the same store search_knowledge "
                + "reads). Use it for durable facts, notes, summaries, decisions. "
                + "Survives every session.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "a short title for the entry"],
                    "text": ["type": "string", "description": "the content to index"],
                    "kind": [
                        "type": "string",
                        "enum": .array(MemoryKind.catalogued.map { .string($0.rawValue) }),
                        // The description prose mirrors MemoryKind.catalogued —
                        // update it when the vocabulary changes (the enum above
                        // derives automatically; pinned by the allCases test).
                        "description": .string(
                            "what kind of fact this is: profile (a stable fact "
                                + "about the user), preference (a standing preference), decision "
                                + "(a decision and why), episode (something that happened), or "
                                + "note (anything else — the default when omitted)"
                        ),
                    ],
                ],
                "required": ["title", "text"],
            ]
        ),
        handler: { args in
            let title = stringArg(args, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = stringArg(args, "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !text.isEmpty else {
                throw MCPVoiceError("remember requires both a title and text")
            }
            // Off-vocabulary labels misclassify to .note, never reject — the
            // same doctrine as the distiller's parser.
            let kind = MemoryKind(catalogued: stringArg(args, "kind"))
            return try await handlers.remember(title, text, kind)
        }
    )
}

/// ask_m1k3: submit the generation, wait a short grace window for the fast case,
/// otherwise hand back a job id the client fetches via get_answer.
private func askM1K3Handler(
    handlers: IntelligenceToolHandlers,
    jobStore: AskJobStore,
    graceSeconds: Double
) -> @Sendable ([String: Value]?) async throws -> String {
    { args in
        // Self-redemption (Issue #2): a job_id means "fetch that result", never a
        // new generation — the tool that issues the ticket can always redeem it,
        // so a client whose cached tool list predates get_answer is never
        // stranded. It wins over question because a stale client's schema still
        // marks question required, so its redemption call may carry both.
        if let jobID = stringArg(args, "job_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jobID.isEmpty
        {
            return try await redeemJob(id: jobID, jobStore: jobStore)
        }

        let question = stringArg(args, "question")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !question.isEmpty else { throw MCPVoiceError("ask_m1k3 requires a non-empty question") }

        // Honest busy: the app-side ask is single-flight, so a question fired
        // while a job is generating would fail anyway — but it used to burn a
        // fresh job id and bounce as an error within milliseconds, which reads
        // as "broken", not "busy". Name the running job instead so the caller
        // can redeem or wait. (Benign race with a concurrent submit: the loser
        // lands as a failed job carrying the app's busy message.)
        if let runningID = await jobStore.runningJobIDs().first {
            return "M1K3 is already answering a question (job \"\(runningID)\") — your new "
                + "question wasn’t queued. Fetch that job via get_answer, or ask again once "
                + "it finishes."
        }

        let id = await jobStore.submit()
        // Detached generation: outlives this request so a turn that beats the
        // client's ~60s deadline still finishes and is fetchable via get_answer.
        // Its own cap lives inside handlers.ask (app-side).
        Task {
            do {
                let answer = try await handlers.ask(question)
                await jobStore.complete(id: id, result: answer)
            } catch {
                await jobStore.fail(id: id, message: describeAskError(error))
            }
        }

        // Grace window: the common fast case returns the answer inline, exactly as
        // before. Poll the store cheaply until the deadline.
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            switch await jobStore.status(of: id) {
            case let .done(answer):
                return answer
            case let .error(message):
                throw MCPVoiceError(message)
            case .running, .none:
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return "M1K3 is still working on this one — it's taking longer than usual "
            + "(a long think or a web search). Call get_answer with job_id \"\(id)\" in a "
            + "few seconds to fetch the result. (If get_answer isn't in your tool list, "
            + "call ask_m1k3 again with just that job_id.)"
    }
}

/// get_answer: fetch a submitted ask_m1k3 job's result, or report it's still working.
private func getAnswerHandler(
    jobStore: AskJobStore
) -> @Sendable ([String: Value]?) async throws -> String {
    { args in
        let id = stringArg(args, "job_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { throw MCPVoiceError("get_answer requires a job_id") }
        return try await redeemJob(id: id, jobStore: jobStore)
    }
}

/// The single redemption path behind both get_answer and ask_m1k3-with-job_id
/// (Issue #2's stale-tool-list escape hatch shares it by construction).
private func redeemJob(id: String, jobStore: AskJobStore) async throws -> String {
    switch await jobStore.status(of: id) {
    case .none:
        throw MCPVoiceError("No such job \"\(id)\" — it may have expired. Ask again with ask_m1k3.")
    case .running:
        return "M1K3 is still working on job \"\(id)\" — poll again in a few seconds "
            + "(get_answer, or ask_m1k3 with just this job_id)."
    case let .done(answer):
        return answer
    case let .error(message):
        throw MCPVoiceError(message)
    }
}

/// Preserve a clean, client-facing message when stashing a failed job — an
/// MCPVoiceError's own text (e.g. the "in a conversation right now" busy line)
/// rather than a wrapped debug description.
private func describeAskError(_ error: Error) -> String {
    if let voiceError = error as? MCPVoiceError { return voiceError.description }
    return error.localizedDescription
}
