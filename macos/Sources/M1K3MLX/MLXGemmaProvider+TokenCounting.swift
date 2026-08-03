//
//  MLXGemmaProvider+TokenCounting.swift
//  M1K3MLX
//
//  Conforms MLXGemmaProvider to M1K3Inference's `TokenCounting` seam so
//  `GroundingBudget` (M1K3Knowledge, wired from M1K3Chat's AgentRAGResponder)
//  can measure the REAL rendered grounding cost before it's injected into a
//  prompt — without M1K3Chat linking M1K3MLX (M1K3Chat → M1K3Inference is
//  already a dependency edge; M1K3MLX → M1K3Chat would be a new, wrong-
//  direction one). Apple Foundation Models / Mini simply don't conform:
//  `provider as? TokenCounting` is nil for them, which the cap treats as
//  "no EXACT count available — estimate instead". It does NOT stand the cap
//  down; this comment used to say the cap treats it as "this tier self-manages
//  its own context window, nothing to measure", and that belief was the
//  2026-08-03 Mini bug — AFM's window is 4096, the smallest of any tier, and it
//  throws rather than self-managing. See GroundingBudget.measure.
//
//  The conformance is DECLARATION-ONLY on purpose. `tokenCount(_:)` itself
//  lives on `MLXGemmaProvider` (MLXGemmaProvider.swift), added by PR #65's
//  prompt-size instrument, and its signature satisfies `TokenCounting`
//  exactly. The two arrived independently with byte-identical bodies; this
//  file carried a duplicate until both PRs landed together, which is the
//  collision the pre-merge note here predicted. One method, two callers —
//  the instrument that measures the prompt and the cap that bounds it read
//  the same tokenizer, so they can never disagree about what a token is.
//
//  Signed: Kev + claude-fable-5, 2026-07-20, Confidence 0.75, Prior: Unknown
//  Context: grounding-cap PR. The tokenizer path mirrors
//  `templateDebugDescription`'s `ensureLoaded()`/`container.perform()` shape
//  one-for-one (both use `context.tokenizer` off a loaded `ModelContainer`),
//  so mechanically it should be correct — but it is UNVERIFIED live: MLX
//  generation/tokenizer paths need the app-bundle metallib and can't run
//  under `swift test` (same limit as every other MLX call in this module).
//  Verify-owed: an on-device re-measure of grounded-Q, confirming it now
//  lands under the 3000-token reserve with margin.
//
//  Review: Kev + claude-opus-4-8, 2026-07-21, Confidence 0.9. Collapsed the
//  duplicated `tokenCount` to a bare conformance when #65 and #67 landed in
//  the same merge, exactly as the note above prescribed. Verified the two
//  bodies were byte-identical before deleting this one, so behaviour is
//  unchanged in both directions. Prior: Kev + claude-fable-5.
//

import Foundation
import M1K3Inference

extension MLXGemmaProvider: TokenCounting {}
