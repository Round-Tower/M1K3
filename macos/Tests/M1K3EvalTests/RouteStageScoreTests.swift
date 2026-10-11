//
//  RouteStageScoreTests.swift
//  M1K3EvalTests
//
//  The router arm of 2026-10-09 couldn't tell which stage picked a tool turn (head, Apple's
//  picker, or the agent): the head's notice went to os_log, never the eval JSON, so a head that
//  never fired read as one that won. A score now carries the turn's route stage, and the live
//  path collects the tools the turn actually ran.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.9. Prior: none (new file).
//

import Foundation
@testable import M1K3Eval
import Testing

struct RouteStageScoreTests {
    private var fixture: ChatEvalFixture {
        ChatEvalFixtures.all.first { $0.kind == .toolUse }!
    }

    @Test("a score carries the turn's route stage; a turn that never routed carries none")
    func carriesStage() {
        let headed = ChatEvalScorer.score(
            fixture: fixture, observation: EvalObservation(rawText: "x", routeStages: ["head"])
        )
        #expect(headed.routeStage == "head")
        let both = ChatEvalScorer.score(
            fixture: fixture, observation: EvalObservation(rawText: "x", routeStages: ["picker", "agent"])
        )
        #expect(both.routeStage == "picker,agent")
        #expect(ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: "x")).routeStage == nil)
    }

    @Test("a repeat keeps its stage")
    func repeatKeepsStage() {
        let score = ChatEvalScorer.score(
            fixture: fixture, observation: EvalObservation(rawText: "x", routeStages: ["head"])
        )
        #expect(score.withRepeatIndex(2).routeStage == "head")
        #expect(score.withRepeatIndex(2).repeatIndex == 2)
    }

    @Test("documents written before the field still decode (the key is simply absent)")
    func oldDocumentsDecode() throws {
        let score = ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: "x"))
        let encoded = try JSONEncoder().encode(score)
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("routeStage") == false)
        let decoded = try JSONDecoder().decode(ChatEvalScore.self, from: encoded)
        #expect(decoded.routeStage == nil)
        #expect(decoded == score)
    }

    @Test("the tool log keeps every tool a turn ran, in order")
    func toolLog() {
        let log = EvalToolLog()
        log.append("datetime")
        log.append("web_search")
        #expect(log.names == ["datetime", "web_search"])
    }
}
