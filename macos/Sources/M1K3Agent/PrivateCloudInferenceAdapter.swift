//
//  PrivateCloudInferenceAdapter.swift
//  M1K3Agent
//
//  Apple's server model (any `PrivateCloudAnswering`) as a plain `InferenceProvider`,
//  for the eval harness's PCC column. The persona rides as `instructions` on
//  every call and the adapter says so (`PersonaCarrying`), so the ReAct floor
//  sends the prompt body without it — the same pairing Mini ships with. Eval-only
//  by intent: the product's PCC turn is `PrivateCloudTurn`, which never attaches
//  tools; what this column measures is Apple's server model under M1K3's own
//  scaffolding, on synthetic fixtures, beside the local tiers.
//
//  `answer` streams CUMULATIVE snapshots (PrivateCloudAnswering's contract), so
//  `generate` keeps the last one and `generateStreaming` re-yields them as-is —
//  InferenceProvider leaves cumulative-vs-delta to the backend, and the eval's
//  consumers fold (StreamFold). A stream that fails before any text records the
//  reason (StreamFailureReporting) so the column reads "ran — <error>", not
//  "0 chars".
//
//  Lives here, not in the app target, so `swift test` reaches it
//  (PrivateCloudInferenceAdapterTests) — the review of #355 asked for exactly that.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85 (pinned with a
//  fake backend; driven live through the PCC column on the same day). Prior:
//  Unknown (moved out of ChatEvalStage.swift, where it was born that morning)
//

import Foundation
import M1K3Inference
import M1K3LanguageModel

public struct PrivateCloudInferenceAdapter: InferenceProvider, PersonaCarrying, StreamFailureReporting {
    public static let brainID = "pcc"
    public static let modelID = "apple/private-cloud-compute"

    private let backend: any PrivateCloudAnswering
    private let instructions: @Sendable () -> String
    private let failures = StreamFailureBox()

    /// - Parameter instructions: the standing persona (the shipping default); injectable so a
    ///   test can pin the pairing without the full persona text.
    public init(backend: any PrivateCloudAnswering, instructions: @escaping @Sendable () -> String = { M1K3Persona.systemPrompt }) {
        self.backend = backend
        self.instructions = instructions
    }

    public var name: String {
        Self.brainID
    }

    public var isAvailable: Bool {
        true
    }

    public var carriesStandingPersona: Bool {
        true
    }

    public func generate(prompt: String) async throws -> String {
        var latest = ""
        for try await snapshot in backend.answer(instructions: instructions(), prompt: prompt) {
            latest = snapshot
        }
        return latest
    }

    public func generateStreaming(prompt: String) -> AsyncStream<String> {
        let backend = backend
        let instructions = instructions
        let failures = failures
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in backend.answer(instructions: instructions(), prompt: prompt) {
                        continuation.yield(snapshot)
                    }
                } catch {
                    // InferenceProvider's contract: errors end the stream, they don't throw.
                    failures.record(String(describing: error))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func takeStreamFailure() -> String? {
        failures.take()
    }
}
