//
//  InferenceIntent.swift
//  M1K3Inference
//
//  Not every generation is a person waiting for an answer. Conversation titles
//  and memory distillation run the same provider as the chat turn, and on
//  2026-08-09 that cost Kev 16-19 seconds
//  per interactive turn: a 64-token background TITLE rendered a different
//  persona prefix, evicted the interactive one from a single-slot cache, and
//  the next chat turn re-prefilled ~2,000 tokens from scratch. Decode was
//  healthy at 30 tok/s throughout — the pause was never the model thinking.
//
//  The cache is now two slots (PersonaPrefixCache), which fixes that exact
//  pair. This flag is the belt to that pair of braces, and it is the stronger
//  guarantee of the two: capacity only holds while there are no more prefixes
//  than slots, and the cache key includes the TOOL SET — so a turn with a
//  different palette is a different prefix, and the count is not fixed at two
//  for ever. Under this flag, background work may USE a cached prefix but can
//  never take a slot from an interactive one. Capacity is a heuristic;
//  priority is a rule.
//
//  A task-local rather than a protocol change: `InferenceProvider.generate`
//  is implemented by every backend and consumed everywhere, and none of them
//  should have to care. It propagates into child tasks automatically, which
//  is exactly right — the distiller's inner generate is still background work.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (the mechanism it
//  guards was measured on the live app, not inferred; the flag itself is a
//  standard task-local and its propagation is pinned. Honest open: it governs
//  prefix STORAGE only — it deliberately does not change what a background
//  call generates, or which brain answers it.) Prior: Unknown
//
//  Review: Kev + claude-opus-5-5, 2026-09-26 — `instructions`: a task-local override of the persona,
//  read by the MLX and AFM providers, so summaries run persona-free on every brain. Confidence 0.85.

import Foundation

public enum InferenceIntent {
    /// True while the current task is background housekeeping rather than a
    /// turn someone is waiting on.
    @TaskLocal public static var isBackgroundUtility = false

    /// Run housekeeping so it cannot displace interactive state.
    ///
    /// Wrap the CALL, not the provider: the same provider serves both, and the
    /// difference is who is waiting.
    public static func backgroundUtility<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $isBackgroundUtility.withValue(true) { try await body() }
    }

    /// Instructions that REPLACE the chat persona for the current task's
    /// generations: every provider reads this before its own persona, and MLX
    /// skips the cached persona seed. Summaries use it (a persona in a stored
    /// summary recited itself, 2026-09-26). Nil means "the provider's persona".
    ///
    /// Use it on a provider that does NOT serve chat (the app's `summaryAFM`):
    /// AFM's PrewarmSlot drops a stored session whose instructions don't match,
    /// so an override call on the chat provider would evict chat's persona prewarm.
    @TaskLocal public static var instructions: String?

    public static func withInstructions<T>(
        _ text: String, _ body: () async throws -> T
    ) async rethrows -> T {
        try await $instructions.withValue(text) { try await body() }
    }
}
