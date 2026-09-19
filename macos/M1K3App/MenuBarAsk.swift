//
//  MenuBarAsk.swift
//  M1K3App
//
//  Powers the menu-bar "Ask M1K3" box: one grounded answer with no chat window
//  and no transcript. Deliberately mirrors MCPHostController.askBrain — a
//  DEDICATED responder (never the chat one; collectedSources() is a draining
//  read), a single-flight guard, a 120s deadline so a runaway generation can't
//  wedge the bar, and the shared canary tripwire. The pure mapping lives in
//  M1K3Chat's MenuBarAskDriver; this is the @MainActor glue (verify-by-launch).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.8, Prior: Unknown

import Foundation
import M1K3Chat
import M1K3MCPKit
import os

@MainActor
@Observable
final class MenuBarAsk {
    private unowned let env: AppEnvironment
    /// Built ONCE. `env.provider` is the swappable runtime façade, so brain
    /// switches are tracked without rebuilding. `.fast` thinking: small brains
    /// stall on the think phase past the deadline — the fuller answer is what
    /// "Continue in chat" is for.
    private let responder: any RAGResponding

    /// One bar ask at a time — a second concurrent generation on the same MLX
    /// provider is undefined.
    private var inFlight = false

    /// Same ceiling as ask_m1k3.
    nonisolated static let deadlineSeconds: Double = 120

    /// Loud, persisted alert if a planted honeypot reaches the answer — count
    /// only, never the value (which would re-leak it).
    private nonisolated static let securityLog = Logger(subsystem: "app.m1k3", category: "security")

    private(set) var state: MenuBarAskState = .idle

    init(environment: AppEnvironment) {
        env = environment
        responder = AppEnvironment.makeAgentResponder(
            store: environment.store,
            embedder: environment.embedder,
            provider: environment.provider,
            forcedThinkingMode: .fast,
            ageBandProvider: AppEnvironment.ageBandProvider
        )
    }

    /// True while M1K3 can't take a bar ask — mid voice loop, mid chat turn, or
    /// already answering one. Drives the Ask box's disabled state.
    var isBusy: Bool {
        inFlight || env.voiceLoop != nil || env.chat.isResponding
    }

    /// Ask one question. Total: it never throws — every outcome lands in `state`.
    func ask(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard env.isReady else {
            state = .failed(
                question: question,
                message: "M1K3 is still waking up — try again in a moment."
            )
            return
        }
        guard !isBusy else {
            state = .failed(
                question: question,
                message: "M1K3 is busy right now — try again in a moment."
            )
            return
        }

        inFlight = true
        state = .asking(question: question)
        env.avatar.setActivity(.thinking)
        defer {
            inFlight = false
            env.avatar.resetToIdle()
        }

        // Capture Sendable values so the @Sendable timeout closure needn't touch
        // @MainActor self.
        let responder = responder
        let canary = CanaryGuard.fromLocalConfig()
        do {
            state = try await withTimeout(seconds: Self.deadlineSeconds) {
                await MenuBarAskDriver.run(
                    question: question,
                    using: responder,
                    canary: canary,
                    onCanaryTrip: { count in
                        Self.securityLog.fault(
                            "canary tripwire fired in menu-bar ask output: \(count, privacy: .public) honeypot(s) redacted"
                        )
                    }
                )
            }
        } catch {
            // withTimeout throws only TimeoutError here (run is total).
            state = MenuBarAskDriver.timedOut(question: question)
        }
    }

    func reset() {
        state = .idle
    }
}
