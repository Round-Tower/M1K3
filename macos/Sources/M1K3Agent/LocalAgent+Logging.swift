//
//  LocalAgent+Logging.swift
//  M1K3Agent
//
//  Param-only diagnostics for the ReAct loop (cross-file extension, so no
//  private actor state in here — those helpers stay in LocalAgent.swift).
//  Logger interpolation is an autoclosure, and the formatter strips the
//  `self.` the compiler would demand inside one, so every interpolation here
//  is a parameter or hoisted local.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown

import Foundation
import M1K3LogCore
import os

extension LocalAgent {
    func logRunStart(goal: String, grounding: String?) {
        let toolNames = tools.keys.sorted().joined(separator: ", ")
        let cap = maxIterations
        let groundingChars = grounding?.count ?? 0
        M1K3Log.agentLoop.info("""
        run start: goal="\(LogPreview.preview(goal, max: 80), privacy: .public)" \
        tools=[\(toolNames, privacy: .public)] cap=\(cap) grounding=\(groundingChars) chars
        """)
    }

    func logPathSelection(provider: String, conforms: Bool, supportsToolCalls: Bool, usingNative: Bool) {
        let path = usingNative ? "NATIVE tool-calling" : "ReAct floor"
        M1K3Log.agentLoop.info("""
        path: provider="\(provider, privacy: .public)" conformsToToolCalling=\(conforms) \
        supportsToolCalls=\(supportsToolCalls) → \(path, privacy: .public)
        """)
    }

    func logCapReached() {
        let cap = maxIterations
        M1K3Log.agentLoop.notice("iteration cap (\(cap)) reached — synthesising a final answer")
    }

    func logEvidenceRescue(error: any Error, steps: Int) {
        let reason = String(describing: error)
        M1K3Log.agentLoop.error("""
        generation failed mid-loop but \(steps) trace step(s) were gathered — \
        concluding empty so the evidence is synthesised, not discarded \
        (\(reason, privacy: .public))
        """)
    }

    func logThought(_ thought: String, iteration: Int, start: ContinuousClock.Instant) {
        let took = Self.elapsed(since: start)
        M1K3Log.agentLoop.debug("""
        iteration \(iteration): thought in \(took, privacy: .public) \
        (\(thought.count) chars): "\(LogPreview.preview(thought), privacy: .public)"
        """)
    }

    func logObservation(
        _ observation: String, callDescription: String, iteration: Int, start: ContinuousClock.Instant
    ) {
        logObservation(
            observation, callDescription: callDescription,
            iteration: iteration, took: Self.elapsed(since: start)
        )
    }

    /// Variant taking a pre-measured duration — the native batch measures
    /// inside each concurrent child so the serial lane's queue wait isn't
    /// billed to the tool.
    func logObservation(
        _ observation: String, callDescription: String, iteration: Int, took: String
    ) {
        M1K3Log.agentLoop.info("""
        iteration \(iteration): \(callDescription, privacy: .public) → observation in \
        \(took, privacy: .public) (\(observation.count) chars): \
        "\(LogPreview.preview(observation), privacy: .public)"
        """)
    }

    func logConclusion(
        _ cleaned: String, raw: String, usedTools: Set<String>, iterations: Int
    ) {
        if cleaned.count != raw.trimmingCharacters(in: .whitespacesAndNewlines).count {
            M1K3Log.agentLoop.notice(
                "scaffolding stripped from conclusion (\(raw.count) → \(cleaned.count) chars)"
            )
        }
        let toolList = usedTools.sorted().joined(separator: ", ")
        M1K3Log.agentLoop.info("""
        run done: iterations=\(iterations) toolsUsed=[\(toolList, privacy: .public)] \
        conclusion=\(cleaned.count) chars: "\(LogPreview.preview(cleaned), privacy: .public)"
        """)
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        let milliseconds = duration.components.seconds * 1000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
        return "\(milliseconds)ms"
    }
}
