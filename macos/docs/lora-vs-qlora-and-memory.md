# LoRA vs QLoRA & memory — what goes in the weights, what goes in the store

> The question that won't die: *"QLoRA — is it one-and-done? Can't I just fine-tune
> M1K3's memory into the adapter?"* This is the durable answer, and the architecture it
> implies. It's why the Phase-16 LoRA bakes **voice** and never **facts**.

## TL;DR

QLoRA is essentially **one-and-done for memory** — and that's fine, because memory was
never its job. It's the **wrong tool for tuned memory** and the **right tool for tuned
behaviour/voice**. Those are different jobs:

- **Voice / behaviour** — diffuse style learned across hundreds of examples ("how M1K3
  talks, refuses, reasons"). → **weights (LoRA).**
- **Memory** — specific, citable, editable facts ("Kev's flight is Thursday at 6"). →
  **the store (RAG / vector memory).**

## Why LoRA ≠ memory

A QLoRA run bakes a *behavioural prior* into a low-rank delta on the weights. Ask it to
hold facts and it fails four of M1K3's load-bearing contracts:

1. **No provenance.** Facts need many epochs to stick and are lossy even then — and you
   can't ask an adapter "where did you learn that?" There's no source to return. That
   breaks M1K3's grounding/citation contract outright:
   [`GroundingGate.swift`](../Sources/M1K3Knowledge/GroundingGate.swift) abstains when
   nothing relevant is retrieved, and
   [`CitationValidator.swift`](../Sources/M1K3Knowledge/CitationValidator.swift) rejects
   claims without a backing source. A weight delta has no source line.

2. **No edit, no delete.** GDPR "right to deletion" against a weight delta means
   *retrain*. A memory you can't reliably forget is a privacy liability — exactly what
   M1K3's local-first ethos exists to reject. A vector row, by contrast, is one delete away.

3. **Catastrophic forgetting + contamination.** Continuously fine-tuning on new facts
   erodes general ability and risks the very leak vectors the **CHATEVAL `security`**
   suite guards (it doubles as the Phase-16 forgetting guard — a voice LoRA that softens a
   refusal is a *failing eval*). And the iron rule: train on your eval and the eval dies.
   *The eval you train against stops being an eval.*

4. **Latency / coupling.** Re-fusing or hot-swapping an adapter on every memory update is
   absurd next to a single vector write into
   [`KnowledgeStore.swift`](../Sources/M1K3Knowledge/KnowledgeStore.swift).

## The architecture it implies

This is the principle the whole trajectory has been converging on — each concern in the
layer that can actually serve it:

| Concern | Home | Where it lives |
| --- | --- | --- |
| **Memory** (facts you query, cite, edit, delete) | the store | `KnowledgeStore` + the `remember` tool + the RAG path ([`AgentRAGResponder.swift`](../Sources/M1K3Chat/AgentRAGResponder.swift) / [`RAGResponder.swift`](../Sources/M1K3Chat/RAGResponder.swift)) |
| **Voice / behaviour** (how M1K3 talks) | the weights | LoRA on lil-4B (Phase 16, Edge E) |
| **Policy** (rules, persona, abstention) | the prompt | [`M1K3Persona.corePrompt`](../Sources/M1K3Inference/M1K3Persona.swift) |
| **Enforcement** (hard guarantees) | the harness | [`CanaryGuard.swift`](../Sources/M1K3Chat/CanaryGuard.swift) + the CHATEVAL `security` suite |

A soft prior is the wrong home for a hard fact, and a hard gate is the wrong home for a
soft style. Put each where it belongs.

## The nuance — it's not *strictly* one-and-done

"One-and-done" is the right intuition for *live memory*, but an adapter is still a
**versioned artifact you re-train deliberately**, not a thing you append to:

- **Periodic distillation of durable traits.** Stable, long-lived *preferences* — "Kev
  likes terse answers, the Cork-villain voice, metric units" — can be distilled into the
  *next adapter version* on a cadence. Think **monthly bake, not per-fact write**. That's
  consolidation of durable behaviour, not a memory store.
- **Composable / swappable at load.** Adapters hot-swap — `SystemLanguageModel(adapter:)`
  for AFM; `mlx_lm.fuse`-or-load for MLX — so "tuned memory" *could* mean per-user or
  per-context adapters. Still coarse, still retrain-to-update.

This is exactly the Phase-16 voice bake. [`M1K3Persona.swift`](../Sources/M1K3Inference/M1K3Persona.swift)
flags the cost it pays down, in its own header (lines 12–21): *"the persona is prefilled
on every turn, so every sentence is a TTFT tax… voice lands in the exemplars."* Bake the
voice into lil's weights and the exemplars drop from every prompt — lower TTFT, more
consistent voice, and the documented exemplar-bleed bug dies with them.

## The frontier — the RAG↔LoRA loop

The genuinely interesting ground is the loop between the two:

- **RAG** holds the editable, citable facts.
- A **periodic LoRA** distils the *patterns that recur* in that memory into cheaper,
  prompt-free behaviour.
- The **Phase-14 evals harness** (`M1K3Eval` + the `M1K3_SELFTEST_CHATEVAL` stage) is what
  keeps the loop honest — you can *measure* whether a bake helped or lobotomised, in the
  before/after matrix. No delta, no ship.

So "it learns me over time" is real — but it's **distillation of durable preferences into
the next adapter on a schedule, sitting on top of RAG**, not LoRA-as-database.

## The rule of thumb

> If you're tempted to make the adapter remember a fact, ask: **can I cite it, edit it, and
> delete it?** Three noes means it belongs in the store.

## See also

- [`scratch/lora-spike/README.md`](../../scratch/lora-spike/README.md) — the lil voice-LoRA
  spike (data strategy, A/B loop, the two non-negotiables).
- [`PLAN.md`](../PLAN.md) — Edge E / Phase 16 (on-device fine-tuning) and Phase 14 (evals).
