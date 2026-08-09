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

    @Test("a value is returned through the wrapper unchanged")
    func returnsTheBodysValue() async {
        let answer = await InferenceIntent.backgroundUtility { 42 }
        #expect(answer == 42)
    }
}
