//
//  RawCompletion.swift
//  M1K3Inference
//
//  The persona-FREE completion seam — built for Brain at Home's /v1/generate
//  route (docs/BRAIN_AT_HOME_SPEC.md §2), whose contract is "raw prompt in,
//  tokens out".
//
//  Why a separate seam instead of `generateStreaming(prompt:)`: every chat
//  path deliberately carries M1K3's persona — MLX seeds it as a cached KV
//  prefix, AFM sets it as session instructions — and that is correct for
//  every LOCAL surface. But a network-reachable "raw" endpoint primed with
//  the system prompt (including the About-the-user block) is a leak surface:
//  prefix-extraction prompts are easiest exactly where the persona sits in
//  context and no output guard runs (2026-08-19 security audit, finding 1).
//  So raw is STRUCTURAL: a conforming provider opens a session with no
//  instructions, no persona seed, no tools, no retrieval — there is nothing
//  in context to extract. Prevention, not detection (the B2 shape).
//
//  This is an `as?` capability seam — per the façade rule
//  (facade-capability-forwarding), EVERY provider façade must forward it or
//  production silently diverges from the bare provider. Pinned by
//  SwappableCapabilityForwardingTests.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (the seam is the
//  audit fold; conformances are thin persona-free variants of shipped
//  streaming paths). Prior: Unknown.
//

/// A provider that can serve a completion with NO persona, instructions,
/// tools, or cached-prefix seed in context — the Brain at Home raw contract.
public protocol RawCompletionProviding: Sendable {
    /// Stream a completion for `prompt` alone. `maxTokens` bounds decode
    /// length; providers clamp it to their own default cap (nil = that cap),
    /// so a remote caller can shorten a generation but never lengthen it.
    ///
    /// Returns nil when raw completion is UNAVAILABLE right now (a façade
    /// whose active backend doesn't conform) — nil is distinguishable from
    /// "the model said nothing", so the LAN route can answer 503 instead of
    /// streaming an empty success.
    func generateRawStreaming(prompt: String, maxTokens: Int?) -> AsyncStream<String>?
}
