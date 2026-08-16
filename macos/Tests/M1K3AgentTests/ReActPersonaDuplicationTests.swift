//
//  ReActPersonaDuplicationTests.swift
//  M1K3AgentTests
//
//  The ReAct floor used to prepend `M1K3Persona.systemPrompt` to every prompt
//  body unconditionally. That is correct for a bare completion backend, and
//  WRONG for one that already carries standing instructions of its own — which
//  is exactly the pairing that ships: the ReAct floor is, in production, the
//  Mini (Apple Foundation Models) path, and `AppleFoundationModelsProvider`
//  puts the very same persona into `LanguageModelSession(instructions:)` on
//  every call.
//
//  So Mini was sent the persona TWICE per generation: ~890 tokens each against
//  a 4096-token window — ~43% of the window spent restating identity before the
//  question existed. `MiniPromptBudgetTests` could not see it, because it pins
//  the persona in ISOLATION: a component-level budget test is structurally
//  blind to a duplication bug, which is the general lesson worth keeping.
//
//  The native path was never affected — it passes the persona once, as a
//  `.system` ToolMessage the MLX provider seeds as its KV prefix.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9, Prior: Unknown
//  Context: macos/docs/NEXT_SESSION.md #102; found by `challenger` while
//  pressure-testing the small-talk-gate proposal, and verified against source.
//

import M1K3Agent
import M1K3Inference
import Testing

struct ReActPersonaDuplicationTests {
    /// A backend that carries standing instructions itself (the AFM shape).
    private struct StandingInstructionsProvider: InferenceProvider, PersonaCarrying {
        let name = "standing"
        let isAvailable = true
        let carriesStandingPersona = true
        let recorder: PromptRecorder
        func generate(prompt: String) async throws -> String {
            await recorder.record(prompt)
            return "CONCLUSION: done"
        }

        func generateStreaming(prompt _: String) -> AsyncStream<String> {
            AsyncStream { $0.finish() }
        }
    }

    /// A plain completion backend with no standing instructions of its own.
    private struct BareProvider: InferenceProvider {
        let name = "bare"
        let isAvailable = true
        let recorder: PromptRecorder
        func generate(prompt: String) async throws -> String {
            await recorder.record(prompt)
            return "CONCLUSION: done"
        }

        func generateStreaming(prompt _: String) -> AsyncStream<String> {
            AsyncStream { $0.finish() }
        }
    }

    @Test("a provider carrying standing instructions is not sent the persona again")
    func standingInstructionsProviderGetsPersonaOnce() async throws {
        let recorder = PromptRecorder()
        let agent = LocalAgent(
            inferenceProvider: StandingInstructionsProvider(recorder: recorder),
            tools: [], maxIterations: 1
        )
        _ = try await agent.run(goal: "what's up?", context: nil)
        let prompt = try #require(await recorder.prompts.first)
        #expect(!prompt.contains(M1K3Persona.systemPrompt), "the session already carries it")
    }

    @Test("the seam survives a façade — production hands the agent a wrapper, not the backend")
    func facadeForwardsPersonaCarrying() async throws {
        // THE PRODUCTION SHAPE, previously untested: the live responder's
        // provider is a routing façade (RuntimeInferenceProvider in the app,
        // SwappableInferenceProvider here in the package), and an `as?`
        // capability cast on a façade that doesn't forward it silently fails —
        // the #65 RecordingProvider lesson, and exactly how the #117 dedup
        // shipped fixed-in-eval but dead-in-production (2026-08-16 find): the
        // eval hands the agent the BARE provider, production never does.
        let recorder = PromptRecorder()
        let facade = SwappableInferenceProvider(StandingInstructionsProvider(recorder: recorder))
        let agent = LocalAgent(inferenceProvider: facade, tools: [], maxIterations: 1)
        _ = try await agent.run(goal: "what's up?", context: nil)
        let prompt = try #require(await recorder.prompts.first)
        #expect(!prompt.contains(M1K3Persona.systemPrompt), "the façade must forward the capability")
    }

    @Test("a façade over a bare backend still reports not-carrying — no false stripping")
    func facadeOverBareStaysBare() async throws {
        let recorder = PromptRecorder()
        let facade = SwappableInferenceProvider(BareProvider(recorder: recorder))
        let agent = LocalAgent(inferenceProvider: facade, tools: [], maxIterations: 1)
        _ = try await agent.run(goal: "what's up?", context: nil)
        let prompt = try #require(await recorder.prompts.first)
        #expect(prompt.contains(M1K3Persona.systemPrompt))
    }

    @Test("a bare completion backend still gets the persona — it has nowhere else to come from")
    func bareProviderStillGetsPersona() async throws {
        let recorder = PromptRecorder()
        let agent = LocalAgent(
            inferenceProvider: BareProvider(recorder: recorder),
            tools: [], maxIterations: 1
        )
        _ = try await agent.run(goal: "what's up?", context: nil)
        let prompt = try #require(await recorder.prompts.first)
        #expect(prompt.contains(M1K3Persona.systemPrompt))
    }

    @Test("the persona never appears more than once in a ReAct prompt, either way")
    func personaAppearsAtMostOnce() async throws {
        for carries in [true, false] {
            let recorder = PromptRecorder()
            let provider: any InferenceProvider = carries
                ? StandingInstructionsProvider(recorder: recorder)
                : BareProvider(recorder: recorder)
            let agent = LocalAgent(inferenceProvider: provider, tools: [], maxIterations: 1)
            _ = try await agent.run(goal: "what's up?", context: nil)
            let prompt = try #require(await recorder.prompts.first)
            let occurrences = prompt.components(separatedBy: M1K3Persona.systemPrompt).count - 1
            #expect(occurrences <= 1, "persona appeared \(occurrences)× (carries=\(carries))")
        }
    }

    @Test("dropping the persona does not drop the ReAct scaffold the loop depends on")
    func scaffoldSurvivesPersonaOmission() async throws {
        // The persona and the format contract are separate concerns; removing the
        // former must not disturb the latter, or the loop stops parsing actions.
        let recorder = PromptRecorder()
        let agent = LocalAgent(
            inferenceProvider: StandingInstructionsProvider(recorder: recorder),
            tools: [], maxIterations: 1
        )
        _ = try await agent.run(goal: "what's up?", context: nil)
        let prompt = try #require(await recorder.prompts.first)
        #expect(prompt.contains("CONCLUSION:"))
        #expect(prompt.contains("ACTION:"))
        #expect(prompt.contains("Your goal: what's up?"))
    }

    @Test("a backend that doesn't opt in keeps today's behaviour")
    func optingOutIsTheDefault() {
        // Same `as?` capability seam as ToolCallingProvider / TokenCounting: not
        // conforming is the safe default, so every existing backend — and every
        // future one written without knowing this protocol exists — keeps the
        // persona in its prompt body rather than silently losing its identity.
        let bare: any InferenceProvider = BareProvider(recorder: PromptRecorder())
        #expect((bare as? PersonaCarrying)?.carriesStandingPersona != true)
    }
}

private actor PromptRecorder {
    var prompts: [String] = []
    func record(_ prompt: String) {
        prompts.append(prompt)
    }
}
