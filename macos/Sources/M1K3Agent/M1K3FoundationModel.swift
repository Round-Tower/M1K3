//
//  M1K3FoundationModel.swift
//  M1K3Agent
//
//  The PRODUCTION conformance to Apple's real WWDC26 `LanguageModel` (ADR 0001).
//  Compile-gated on the FoundationModels SDK (Xcode 27+); runtime-gated on
//  @available(macOS 27, *). Product behaviour is decided by ROUTING
//  (EscalationLadder), never by this gate.
//
//  It's a thin adapter: it reuses the tested `M1K3ModelExecutor` (the real
//  ToolTurnSession + ThinkStreamGate) and translates the gate's reasoning/answer
//  split onto Apple's two distinct channel events — `.reasoning` and `.response`.
//  A naive adapter dumps everything into `.response` and leaves `.reasoning` empty;
//  filling it is M1K3's value-add.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.8 (type-checked against
//  the real macOS 27 SDK; live behaviour is verify-on-device under Xcode 27).
//  Prior: Kev + claude-opus-4-8
//  Review: Kev + claude-opus-5, 2026-09-15 — the GA SDK (Xcode 27A266a) renamed two call shapes
//  the beta (27A5194q) took: `LanguageModelCapabilities(_:)` and `updateUsage(input:output:)`.
//  Both fixed; the bridge compiles again under M1K3_FM27 on GA. Confidence 0.8.
//  Review: Kev + claude-opus-4-6, 2026-09-16 — M1K3_FM27 env-var gate removed; now
//  #if canImport(FoundationModels) (Xcode 27 GA is the toolchain). Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-18 — the three `@available(macOS 27.0, *)` gain `iOS 27.0,
//  visionOS 27.0`. With the env gate gone this file compiles for EVERY platform on Xcode 27, and `*` left
//  iOS at its deployment target, so `LanguageModelCapabilities` and the executor types failed as
//  "only available in iOS 27.0 or newer" — no local iOS build of the shell could pass (CI's runner is on
//  the older compiler, where `#if compiler(>=6.4)` skips the file). Verified on Xcode 27A266a: the M1K3iOS
//  simulator build goes from 6 errors to BUILD SUCCEEDED, and M1K3visionOS builds too. No behaviour
//  change. Confidence 0.9.
//

#if compiler(>=6.4)
    import Foundation
    import FoundationModels
    import M1K3Inference
    import M1K3LanguageModel
    import Synchronization

    enum M1K3FoundationError: Error {
        case unregistered(String)
    }

    /// Apple keys the executor on its `Configuration` (a Hashable cache key), so the
    /// non-hashable session factory can't live in the config. This registry resolves a
    /// model id → the real `M1K3Model` (descriptor + session factory) at executor build.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    public enum M1K3FoundationRegistry {
        private static let models = Mutex<[String: M1K3Model]>([:])

        public static func register(_ model: M1K3Model) {
            models.withLock { $0[model.descriptor.id] = model }
        }

        static func resolve(_ id: String) -> M1K3Model? {
            models.withLock { $0[id] }
        }
    }

    /// A M1K3 brain as Apple's real `LanguageModel`. Registers itself so its executor
    /// can be reconstructed from the (hashable) configuration.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    public struct M1K3FoundationModel: FoundationModels.LanguageModel {
        public typealias Executor = M1K3FoundationExecutor

        let model: M1K3Model

        public init(_ model: M1K3Model) {
            self.model = model
            M1K3FoundationRegistry.register(model)
        }

        public var capabilities: FoundationModels.LanguageModelCapabilities {
            var caps: [FoundationModels.LanguageModelCapabilities.Capability] = []
            let declared = model.descriptor.capabilities
            if declared.contains(.toolCalling) { caps.append(.toolCalling) }
            if declared.contains(.reasoning) { caps.append(.reasoning) }
            if declared.contains(.vision) { caps.append(.vision) }
            if declared.contains(.guidedGeneration) { caps.append(.guidedGeneration) }
            return FoundationModels.LanguageModelCapabilities(caps)
        }

        public var executorConfiguration: M1K3FoundationExecutor.Configuration {
            M1K3FoundationExecutor.Configuration(modelID: model.descriptor.id)
        }
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    public struct M1K3FoundationExecutor: FoundationModels.LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            public let modelID: String
        }

        public typealias Model = M1K3FoundationModel

        private let inner: any LanguageModelExecuting

        public init(configuration: Configuration) throws {
            guard let model = M1K3FoundationRegistry.resolve(configuration.modelID) else {
                throw M1K3FoundationError.unregistered(configuration.modelID)
            }
            inner = model.makeExecutor()
        }

        public func respond(
            to request: FoundationModels.LanguageModelExecutorGenerationRequest,
            model _: M1K3FoundationModel,
            streamingInto channel: FoundationModels.LanguageModelExecutorGenerationChannel
        ) async throws {
            let prompt = Self.userPrompt(from: request.transcript)

            // Run M1K3's tuned loop + ThinkStreamGate into the mirror channel (collects
            // reasoning/answer separately), then fan onto Apple's two event streams.
            let collected = GenerationChannel()
            try await inner.respond(to: prompt, into: collected)

            if !collected.reasoning.isEmpty {
                await channel.send(.reasoning(action: .appendText(collected.reasoning, tokenCount: 0)))
            }
            if !collected.answer.isEmpty {
                await channel.send(.response(action: .appendText(collected.answer, tokenCount: 0)))
            }
            // Rough output estimate (~4 chars/token) — the collect-then-emit path
            // doesn't tokenise; an estimate beats a misleading zero for debugging.
            let outputEstimate = (collected.answer.count + collected.reasoning.count) / 4
            // GA (27A266a) takes the two counts directly; the beta took a built `Usage`.
            await channel.send(.response(action: .updateUsage(
                input: .init(totalTokenCount: collected.inputTokenCount, cachedTokenCount: 0),
                output: .init(totalTokenCount: outputEstimate, reasoningTokenCount: collected.reasoning.count / 4)
            )))
        }

        /// Pull the user-authored text out of the request's `Transcript`.
        /// LIMITATION: extracts user-turn text only — `.response` (prior assistant
        /// turns) and `.image`/`.structure` segments are dropped. Correct for the
        /// single-turn brick; the executor owns cross-turn KV reuse via its cached
        /// session. Extend this when FoundationModels drives a full multi-turn session.
        static func userPrompt(from transcript: FoundationModels.Transcript) -> String {
            var parts: [String] = []
            for entry in transcript {
                guard case let .prompt(prompt) = entry else { continue }
                for segment in prompt.segments {
                    if case let .text(text) = segment { parts.append(text.content) }
                }
            }
            return parts.joined(separator: "\n")
        }
    }
#endif
