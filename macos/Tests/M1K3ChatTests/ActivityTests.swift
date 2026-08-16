//
//  ActivityTests.swift
//  M1K3ChatTests
//
//  The activity channel is the cover for the agent loop's streaming silence:
//  the responder reports what it's doing, ChatSession shows it on the
//  in-flight assistant message, and the label clears the moment real tokens
//  (or completion) arrive. Labeler copy is pure; the session behavior is
//  pinned with a gated fake responder.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3Chat
import M1K3Knowledge
import Testing

struct ActivityLabelerTests {
    @Test("known tools get tailored copy")
    func knownTools() {
        #expect(ActivityLabeler.label(for: .usingTool(name: "web_search", argument: "rain in Dublin"))
            == "Searching the web for “rain in Dublin”…")
        #expect(ActivityLabeler.label(for: .usingTool(name: "search_knowledge", argument: "seals"))
            == "Searching your knowledge…")
        #expect(ActivityLabeler.label(for: .usingTool(name: "datetime", argument: ""))
            == "Checking the date & time…")
        #expect(ActivityLabeler.label(for: .usingTool(name: "system_status", argument: ""))
            == "Checking system status…")
    }

    @Test("fetch_page shows which site is being read")
    func fetchPageLabel() {
        #expect(ActivityLabeler.label(for: .usingTool(
            name: "fetch_page", argument: "https://weather.com/boston/10-day"
        )) == "Reading weather.com…")
        #expect(ActivityLabeler.label(for: .usingTool(name: "fetch_page", argument: "junk"))
            == "Reading a web page…")
    }

    @Test("unknown tools and the loop phases have sensible copy")
    func phases() {
        // The every-turn RAG phase must NOT read like the search_knowledge tool
        // ("Searching your knowledge…") — Kev heard it as a tool call that never
        // was (2026-08-16). A self-action verb keeps the two distinguishable.
        #expect(ActivityLabeler.label(for: .retrieving) == "Recalling what I know…")
        #expect(ActivityLabeler.label(for: .thinking(iteration: 0)) == "Thinking…")
        #expect(ActivityLabeler.label(for: .usingTool(name: "query_graph", argument: "x"))
            == "Using query_graph…")
    }

    @Test("tools have short display names for the transcript trace")
    func displayNames() {
        #expect(ActivityLabeler.displayName(forTool: "web_search") == "web search")
        #expect(ActivityLabeler.displayName(forTool: "search_knowledge") == "knowledge search")
        #expect(ActivityLabeler.displayName(forTool: "fetch_page") == "web page")
        #expect(ActivityLabeler.displayName(forTool: "lookup_fact") == "fact lookup")
        #expect(ActivityLabeler.displayName(forTool: "datetime") == "date & time")
        #expect(ActivityLabeler.displayName(forTool: "system_status") == "system status")
        #expect(ActivityLabeler.displayName(forTool: "delegate_deep") == "deep dive")
        #expect(ActivityLabeler.displayName(forTool: "list_documents") == "documents")
        #expect(ActivityLabeler.displayName(forTool: "get_document") == "document")
        #expect(ActivityLabeler.displayName(forTool: "open_link") == "link")
        // Unknown tools humanize rather than leak snake_case into the UI.
        #expect(ActivityLabeler.displayName(forTool: "query_graph") == "query graph")
    }

    @Test("the transcript trace line is a pinned product string")
    func traceLabel() {
        #expect(ActivityLabeler.traceLabel(for: ["web_search", "datetime"])
            == "Used web search · date & time")
        #expect(ActivityLabeler.traceLabel(for: ["delegate_deep"]) == "Used deep dive")
    }

    @Test("long web queries are truncated in the label")
    func truncatesLongQueries() {
        let longQuery = String(repeating: "very ", count: 30)
        let label = ActivityLabeler.label(for: .usingTool(name: "web_search", argument: longQuery))
        #expect(label.count < 80)
        #expect(label.contains("…"))
    }
}

// MARK: - ChatSession integration

/// Reports activity, then holds the stream open until the test releases it —
/// so the label is observable mid-flight.
private final class GatedActivityResponder: RAGResponding, @unchecked Sendable {
    private var release: (() -> Void)?

    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        onActivity(.usingTool(name: "web_search", argument: "weather"))
        let stream = AsyncStream<String> { continuation in
            release = {
                continuation.yield("Answer.")
                continuation.finish()
            }
        }
        return ([], stream)
    }

    func finish() {
        release?()
    }
}

@MainActor
struct ChatSessionActivityTests {
    @Test("the in-flight assistant message shows the activity label, cleared on completion")
    func labelLifecycle() async throws {
        let responder = GatedActivityResponder()
        let session = ChatSession(responder: responder)

        let sendTask = Task { await session.send("what's the weather?") }

        // Wait for the activity hop to land on the main actor.
        var label: String?
        for _ in 0 ..< 200 where label == nil {
            try await Task.sleep(for: .milliseconds(5))
            label = session.messages.last?.activityLabel
        }
        #expect(label == "Searching the web for “weather”…")

        responder.finish()
        await sendTask.value

        let assistant = session.messages.last
        #expect(assistant?.status == .complete)
        #expect(assistant?.text == "Answer.")
        #expect(assistant?.activityLabel == nil)
    }

    @Test("activityLabel is not persisted in the transcript")
    func labelNotPersisted() throws {
        var message = ChatMessage(role: .assistant, text: "hi", status: .complete)
        message.activityLabel = "Thinking…"
        let data = try JSONEncoder().encode([message])
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        #expect(decoded.first?.activityLabel == nil)
        #expect(decoded.first?.text == "hi")
    }
}

// MARK: - Tool trace (persisted provenance)

/// Emits several tool events (with a duplicate) before streaming — pins that
/// the trace is accumulated deduped, in dispatch order, and survives the turn.
private final class MultiToolResponder: RAGResponding, @unchecked Sendable {
    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        onActivity(.retrieving)
        onActivity(.usingTool(name: "web_search", argument: "weather"))
        onActivity(.usingTool(name: "web_search", argument: "weather tomorrow"))
        onActivity(.usingTool(name: "datetime", argument: ""))
        let stream = AsyncStream<String> { continuation in
            continuation.yield("Answer.")
            continuation.finish()
        }
        return ([], stream)
    }
}

/// Captures the onActivity callback so a test can fire a STRAGGLER event
/// after the turn has settled.
private final class CallbackCapturingResponder: RAGResponding, @unchecked Sendable {
    var capturedActivity: (@Sendable (ResponderActivity) -> Void)?

    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        capturedActivity = onActivity
        onActivity(.usingTool(name: "web_search", argument: "hi"))
        let stream = AsyncStream<String> { continuation in
            continuation.yield("Answer.")
            continuation.finish()
        }
        return ([], stream)
    }
}

@MainActor
struct ToolTraceTests {
    @Test("tools used are recorded on the message, deduped, phases excluded")
    func traceAccumulates() async throws {
        let session = ChatSession(responder: MultiToolResponder())
        await session.send("what's the weather?")
        // The activity hops ride Task { @MainActor } — give them a beat to land.
        for _ in 0 ..< 200 where session.messages.last?.toolsUsed?.count != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let assistant = session.messages.last
        #expect(assistant?.status == .complete)
        #expect(assistant?.toolsUsed == ["web_search", "datetime"])
    }

    @Test("a late activity hop cannot mutate a settled message")
    func lateHopIsDropped() async throws {
        // The trace hops ride unstructured Task { @MainActor } — one can land
        // AFTER the final update (and after the leak guard's clear). A settled
        // message must be immutable to them, or a leaked/persisted turn could
        // grow provenance it was stripped of (quality review, 2026-08-16).
        let responder = CallbackCapturingResponder()
        let session = ChatSession(responder: responder)
        await session.send("hi")
        for _ in 0 ..< 200 where session.messages.last?.toolsUsed == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.messages.last?.toolsUsed == ["web_search"])

        // Fire a straggler tool event after the turn is complete.
        responder.capturedActivity?(.usingTool(name: "datetime", argument: ""))
        try await Task.sleep(for: .milliseconds(50))
        let assistant = session.messages.last
        #expect(assistant?.status == .complete)
        #expect(assistant?.toolsUsed == ["web_search"])
        #expect(assistant?.activityLabel == nil)
    }

    @Test("the tool trace persists in the transcript, absent key decodes nil")
    func tracePersists() throws {
        var message = ChatMessage(role: .assistant, text: "hi", status: .complete)
        message.toolsUsed = ["web_search", "datetime"]
        let data = try JSONEncoder().encode([message])
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        #expect(decoded.first?.toolsUsed == ["web_search", "datetime"])

        // A pre-trace transcript (no key) must still decode — the
        // reasoning/attachments precedent.
        let old = ChatMessage(role: .assistant, text: "old", status: .complete)
        let oldData = try JSONEncoder().encode([old])
        let oldDecoded = try JSONDecoder().decode([ChatMessage].self, from: oldData)
        #expect(oldDecoded.first?.toolsUsed == nil)
    }
}
