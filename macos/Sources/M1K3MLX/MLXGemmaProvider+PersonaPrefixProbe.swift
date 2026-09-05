//
//  MLXGemmaProvider+PersonaPrefixProbe.swift
//  M1K3MLX
//
//  The safety net that makes the persona-prefix optimisation shippable.
//
//  The prefix cache only works if the cached system block, followed by the
//  per-turn delta the seeded session re-emits, reconstructs EXACTLY the tokens
//  a from-scratch render would produce. A boundary off by even one token
//  doesn't crash — it silently feeds the model a KV cache describing a
//  different sequence, degrading generation in a way no unit test sees. So we
//  assert the invariant directly at launch:
//
//      [cached system block] + [consuming delta] == [full from-scratch render]
//
//  token-for-token, for plain chat (no tools) AND an agent turn (tools live in
//  the Qwen system block). This is the same verification tier as all MLX
//  generation in this project (verify-by-launch); it also retroactively guards
//  gemma's pre-existing prefix, and a post-dep-bump tokenizer drift fails it
//  LOUDLY instead of silently. The reported prefix token count is the per-turn
//  prefill the cache saves — the number that decides whether the path is worth
//  keeping on a given family.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-11, Confidence 0.85 (the assertion is
//  exact; it runs only under M1K3_SELFTEST_PREFIX=1). Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.85 — PR #232: the ground-truth
//  render goes through `MLXToolMapping.seedInputs` like `systemBlockIDs`, so the invariant
//  holds for lfm2 (tools inside the system text) instead of false-FAILing it.
//

import Foundation
import M1K3Inference
import MLXLMCommon

extension MLXGemmaProvider {
    /// Verify `[prefix] + [delta] == [full]` for plain chat and an agent turn.
    /// Returns a multi-line report; never throws (errors become report lines).
    public func personaPrefixInvariantProbe() async -> String {
        let container: ModelContainer
        do {
            container = try await ensureLoaded()
        } catch {
            return "persona-prefix invariant: load failed — \(error)"
        }
        let persona = M1K3Persona.systemPrompt(includeExemplars: true)
        let tools = [
            ToolDefinition(
                name: "web_search",
                description: "Search the web for current information.",
                parameters: [ToolParameterDefinition(
                    name: "query", description: "the search query"
                )]
            ),
            ToolDefinition(
                name: "datetime",
                // Mirrors DateTimeTool.description (M1K3AgentTools — no dep
                // edge to a tools layer from a backend, so the string is
                // duplicated with the same HostPlatform interpolation) so the
                // probe's token counts stay representative of the live prompt.
                description: "Get the current date and time on \(HostPlatform.thisDevice). Argument: optional, ignored.",
                parameters: []
            ),
        ].map(MLXToolMapping.toolSpec(from:))

        let plain = await checkInvariant(container: container, persona: persona, label: "plain", specs: nil)
        let agent = await checkInvariant(container: container, persona: persona, label: "agent", specs: tools)
        return "persona-prefix invariant:\n  \(plain)\n  \(agent)"
    }

    /// One invariant check for a given tool set. Renders all three token
    /// sequences through the SAME upstream route the prefix uses, so the
    /// comparison is apples-to-apples. A PASS proves the cached system block is
    /// a true token-prefix of the full render — exactly what
    /// MLXToolTurnSession's cross-turn reuse seeds from (cachedIDs =
    /// seed.tokenIDs). (The `[user]`/tools-nil delta is tools-independent
    /// because Qwen renders tools INSIDE the system block, i.e. the prefix.)
    private func checkInvariant(
        container: ModelContainer,
        persona: String,
        label: String,
        specs: [ToolSpec]?
    ) async -> String {
        do {
            return try await container.perform { context in
                guard let upstream = (context.tokenizer as? TransformersTokenizerAdapter)?.upstream else {
                    return "\(label): no template tokenizer"
                }
                /// upstream.applyChatTemplate is the inner impl of
                /// context.processor.prepare for chat UserInput (verified at
                /// mlx-swift-lm 3.31.3) — the probe uses it directly to stay in
                /// container.perform's synchronous context. If a future pin makes
                /// prepare prepend a BOS the template doesn't, this proxy drifts
                /// from production; re-verify on dep bumps.
                func render(_ messages: [[String: String]], tools: [ToolSpec]?, gen: Bool) throws -> [Int] {
                    try upstream.applyChatTemplate(
                        messages: messages, chatTemplate: nil,
                        addGenerationPrompt: gen, truncation: false, maxLength: nil, tools: tools
                    )
                }
                // Ground truth renders through the SAME seam production does:
                // for lfm2 the tools ride inside the system text (sidestepping
                // swift-jinja's sorted-key tojson), so `full` must too — or the
                // probe false-FAILs the one family the seam exists for.
                let seed = MLXToolMapping.seedInputs(
                    persona: persona, specs: specs, format: self.resolvedToolCallFormat ?? .json
                )
                let system: [String: String] = ["role": "system", "content": seed.system]
                let query: [String: String] = ["role": "user", "content": "What's the weather in Cork today?"]

                let prefix = try self.systemBlockIDs(context: context, persona: persona, specs: specs)
                // production delta: .system is in the cache and tools are
                // sentTools=true, so both are dropped. additionalContext
                // (enable_thinking) is dropped too — deliberately: it only
                // appends to the generation-prompt suffix, downstream of the
                // prefix boundary, so the invariant holds for fast OR thinking
                // mode. Comparing without it keeps the check mode-agnostic.
                let delta = try render([query], tools: nil, gen: true)
                let full = try render([system, query], tools: seed.specs, gen: true) // ground truth
                let stitched = prefix + delta

                guard stitched == full else {
                    let at = SystemBlockBoundary.commonPrefixLength(stitched, full)
                    let want = context.tokenizer.decode(tokenIds: Array(full[at ..< min(at + 8, full.count)]))
                    let got = context.tokenizer.decode(tokenIds: Array(stitched[at ..< min(at + 8, stitched.count)]))
                    return "\(label): invariant=FAIL prefix=\(prefix.count)tok "
                        + "diverge@\(at) want=[\(want)] got=[\(got)]"
                }
                return "\(label): invariant=PASS prefix=\(prefix.count)tok delta=\(delta.count) full=\(full.count)"
            }
        } catch {
            return "\(label): error — \(String(describing: error).prefix(100))"
        }
    }
}
