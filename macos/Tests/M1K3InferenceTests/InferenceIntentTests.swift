//
//  InferenceIntentTests.swift
//  M1K3InferenceTests
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9. Prior: Unknown
//

import M1K3Inference
import Testing

struct InferenceIntentTests {
    @Test("interactive is the default — nothing has to opt in to being a real turn")
    func defaultsToInteractive() {
        #expect(InferenceIntent.isBackgroundUtility == false)
    }

    @Test("the flag is set inside the block and restored after")
    func scopedToTheCall() async {
        await InferenceIntent.backgroundUtility {
            #expect(InferenceIntent.isBackgroundUtility)
        }
        #expect(InferenceIntent.isBackgroundUtility == false)
    }

    /// The reason this is a task-local and not a parameter: the distiller and
    /// the titler both await a provider that spawns its own work, and that
    /// inner generation is still background. A value that stopped at the first
    /// hop would guard nothing.
    @Test("it reaches nested async work, which is the whole point")
    func propagatesIntoChildTasks() async {
        let seen: Bool = await InferenceIntent.backgroundUtility {
            await Task { InferenceIntent.isBackgroundUtility }.value
        }
        #expect(seen)
    }

    /// Summaries must not carry the chat persona on any brain (Kev, 2026-09-26).
    /// The override rides the task like the background flag, so it reaches the
    /// provider's own inner work.
    @Test("instructions override is nil by default, scoped to the block, and reaches child tasks")
    func instructionsOverride() async {
        #expect(InferenceIntent.instructions == nil)
        let seen: String? = await InferenceIntent.withInstructions("Summarise neutrally.") {
            await Task { InferenceIntent.instructions }.value
        }
        #expect(seen == "Summarise neutrally.")
        #expect(InferenceIntent.instructions == nil)
    }

    @Test("a value is returned through the wrapper unchanged")
    func returnsTheBodysValue() async {
        let answer = await InferenceIntent.backgroundUtility { 42 }
        #expect(answer == 42)
    }

    @Test("thinking is undecided by default — the provider's construction flag governs")
    func thinkingUndecidedByDefault() {
        #expect(InferenceIntent.thinking == nil)
    }

    @Test("withThinking scopes the turn's decision and restores nil after")
    func thinkingScopedToTheTurn() async {
        await InferenceIntent.withThinking(false) {
            #expect(InferenceIntent.thinking == false)
            await InferenceIntent.withThinking(true) {
                #expect(InferenceIntent.thinking == true)
            }
            #expect(InferenceIntent.thinking == false)
        }
        #expect(InferenceIntent.thinking == nil)
    }

    @Test("the turn's decision reaches a stream producer Task spawned inside it — MLX's generateStreaming shape")
    func thinkingReachesAStreamProducerTask() async {
        let seen: [Bool?] = await InferenceIntent.withThinking(false) {
            let stream = AsyncStream<Bool?> { continuation in
                Task {
                    continuation.yield(InferenceIntent.thinking)
                    continuation.finish()
                }
            }
            var values: [Bool?] = []
            for await value in stream {
                values.append(value)
            }
            return values
        }
        #expect(seen == [false])
    }
}
