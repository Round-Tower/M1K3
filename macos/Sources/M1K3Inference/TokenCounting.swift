//
//  TokenCounting.swift
//  M1K3Inference
//
//  The measurement seam for anything that needs the REAL token cost of a
//  string through a provider's own tokenizer — not a chars≈tokens estimate.
//  Only tokenizer-backed backends (MLX) conform; Apple Foundation Models /
//  Mini have no exposed tokenizer and simply don't — callers reach this via
//  `provider as? TokenCounting`.
//
//  ⚠️ A nil cast means ONLY "no exact count available". It does NOT mean "this
//  provider self-manages its context window, there is nothing to measure or
//  cap" — this header said exactly that until 2026-08-03, and that belief was
//  the bug. Apple Foundation Models does not self-manage: it throws
//  `exceededContextWindowSize` at 4096 tokens, the SMALLEST window of any tier,
//  and was the only tier `GroundingBudget` exempted from its cap. Callers must
//  treat nil as "estimate instead" (see `GroundingBudget.measure`), never as
//  "skip the limit". Unmeasurable is not unlimited.
//
//  First consumer: `GroundingBudget` (M1K3Knowledge) caps the KNOWLEDGE +
//  memory grounding lanes AgentRAGResponder injects into the prompt, before
//  they can blow gemma-4's fixed non-history reserve (PR #65's prompt-size
//  instrument measured the grounded-Q worst case at 2998/3000 tokens — 2
//  tokens of headroom before `RotatingKVCache(8192)` silently rotates the
//  persona/grounding head out mid-turn). This protocol lives in M1K3Inference
//  — already an M1K3Chat dependency — rather than M1K3Chat casting to the
//  concrete `MLXGemmaProvider` type, which would need a new M1K3Chat→M1K3MLX
//  edge that doesn't otherwise exist.
//
//  Signed: Kev + claude-fable-5, 2026-07-20, Confidence 0.85, Prior: Unknown
//  Context: grounding-cap PR. The protocol shape mirrors ToolCallingProvider's
//  existing "runtimes without the capability simply don't conform" pattern
//  (M1K3Inference/ToolCallingProvider.swift). MLXGemmaProvider's conformance
//  (M1K3MLX/MLXGemmaProvider+TokenCounting.swift) is Metal-backed and
//  verify-by-launch, same as every other MLX generation path — it can't run
//  under `swift test`.
//

/// A provider that can report the exact token count of arbitrary text through
/// its own tokenizer, without running a generation.
public protocol TokenCounting: InferenceProvider {
    /// The token count for `text`, or `nil` if it can't be measured right now
    /// (model not loaded, load failed, no tokenizer). `nil`, never a
    /// confident `0` — a zero would read as "measured, and free" when the
    /// truth is "unmeasured".
    func tokenCount(_ text: String) async -> Int?
}
