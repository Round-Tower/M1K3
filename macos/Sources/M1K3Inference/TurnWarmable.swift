//
//  TurnWarmable.swift
//  M1K3Inference
//
//  A capability seam: "the agent turn is over — prepare for the next one."
//
//  Exists for the AFM prewarm re-arm cadence. The first cut re-armed inside
//  `generate`/`generateStreaming`, which fires per PROVIDER CALL — and Mini's
//  ReAct floor makes several rapid calls per user turn (iterations + the
//  conclusion synthesis), interleaving prewarm daemon round-trips between the
//  real ones: structurally the logged AFM rate-collapse shape
//  (pkill-poisons-afm-daemon, 2026-08-03 — it is RATE, not force-quit). This
//  seam moves the re-arm to once per `LocalAgent.run`, bounded by user pacing.
//
//  ⚠️ Every façade must forward it (`as?` on a non-forwarding wrapper silently
//  fails — the #65 lesson, re-learned 2026-08-16 with PersonaCarrying and
//  TokenCounting). SwappableInferenceProvider forwards below its siblings;
//  the app's RuntimeInferenceProvider mirrors it.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9, Prior: Unknown
//

import Foundation

/// Implemented by backends that want a signal when an agent turn concludes —
/// today, the AFM provider re-arming its prewarmed session. Must be cheap and
/// non-blocking; it runs on the turn's tail.
public protocol TurnWarmable: Sendable {
    func prepareForNextTurn()
}
