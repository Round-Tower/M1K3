# ADR-0007: System-model Mini — Gemini Nano via ML Kit GenAI

**Status:** ACCEPTED
**Date:** 2026-08-22
**Deciders:** Kev Murphy + Claude

MurphySig: kevin+claude-fable-5 / confidence 0.7 / 2026-08-22
Context: gives Mini M1K3 the same "platform system model when the device has
one" posture the Mac/iOS app already has via Apple Foundation Models
(`macos/Sources/M1K3Inference/AppleFoundationModelsProvider.swift`). SDK
surface verified directly against the `genai-prompt`/`genai-common`
1.0.0-beta4 AARs (`javap` over the decompiled class files, not secondhand
docs) — see the class-level KDoc on `GeminiNanoEngine` and
`AndroidSystemBrainProbe` for the exact API shape this relies on.

---

## Context

M1K3Tier.Mini has always meant "the small tier" — [`LlmModel.Qwen35_0B8`][llm],
a 557MB GGUF we download and serve via Ma/llama.cpp. On the Mac/iOS app,
the equivalent tier answers via Apple's on-device Foundation Models when the
hardware supports it, and only falls back to a bundled weight when it
doesn't. Android had no equivalent: ML Kit GenAI (Gemini Nano/AICore) was
present in this codebase once (`MlKitGenAiEngine`/`AndroidOnDeviceAi`), but —
per ADR-0006's 2026-08 addendum — it was **never wired into the real chat
flow** and was cut as dead weight during the 2026-08 KMP reduction.

This ADR re-adds it, this time actually wired in, with the same posture as
the Mac: **prefer the platform's own model when the device has one; our
weights are the fallback, not the default.**

[llm]: ../../shared/src/commonMain/kotlin/app/m1k3/ai/domain/ai/LlmModel.kt

## Decision

- **`M1K3Tier.Mini.model` stays `LlmModel.Qwen35_0B8`.** That identity is the
  download/weights fallback and the tier's `chatFormat` (ChatML) — nothing
  about the tier's *product identity* changes.
- **A new resolution layer decides which engine actually answers.**
  [`SystemBrainAvailability`](../../shared/src/commonMain/kotlin/app/m1k3/ai/domain/ai/SystemBrain.kt)
  (domain, platform-neutral) + [`MiniBrainPolicy.resolve`](../../shared/src/commonMain/kotlin/app/m1k3/ai/domain/ai/SystemBrain.kt)
  (pure) decide `MiniBrain.SystemModel` vs `MiniBrain.Weights(Qwen35_0B8)`.
  Rule: prefer the system model whenever the platform has one or can fetch
  one (`Available` / `Downloadable` / `Downloading`); fall back to weights
  only when it's genuinely `Unavailable`.
- **`SystemBrainProbe`** (domain interface) is how a platform reports its
  system-model status. `AndroidSystemBrainProbe` wraps ML Kit GenAI's
  `GenerativeModel.checkStatus()`/`.download()`. `StubSystemBrainProbe`
  (always `Unavailable`) is the iOS/desktop/test binding until/unless those
  targets get their own system model worth wiring.
- **`GeminiNanoEngine`** (`composeApp/androidMain`) implements `BaseLlmEngine`
  — plain generate/generateStreaming, no `NativeChatCapable` (Gemini Nano has
  no per-model tool dialect or GBNF grammar seam; the app's existing
  prompt-engineered fallback path handles it like any other non-native
  engine).
- **The persona is split, never re-added.** `ChatWithToolsUseCase` always
  hands engines ONE pre-rendered ChatML string (persona + context + tools +
  question, all rendered by `UnifiedPromptBuilder`/`DefaultChatFormatter` for
  `Qwen35_0B8`'s chat format). `ChatMlPromptSplit` recovers exactly the
  system and user turns already written into that string and routes each to
  ML Kit's own `SystemInstruction`/`TextPart` request slots. Nothing is
  synthesized on top — this is the fix for the exact bug class the Mac's
  `AppleFoundationModelsProvider` shipped with (persona sent once via prompt
  body, once via session instructions, ~890 tokens silently doubled for a
  week; see auto-memory `facade-capability-forwarding.md`).
- **`PromptBudget`** trims the user-content half to a conservative
  ~3500-token estimate before it's sent — the persona/system half is never
  truncated.
- **The resolution is probed once per process, cached.** Koin's
  `single<MiniBrain>` binding calls `SystemBrainProbe.availability()` once
  (first `get()`), and both the initial engine pick and the mid-session
  tier-switch `engineFactory` in `ChatScreenViewModel` consult the same
  cached value, so they can't disagree about which engine `Qwen35_0B8`
  resolves to. A user who enables/installs a system model mid-session sees
  the change on next launch, not mid-conversation — acceptable for a first
  cut; live re-probing is a named follow-up, not built here.
- **`isModelDownloaded(Qwen35_0B8)` reports `true` when the resolved brain is
  `SystemModel`** — Mini needs no on-disk weights when the platform is
  serving it, so the existing "download before use" gate doesn't block on
  557MB nobody needs.

## Privacy (ADR-0006 amendment)

ML Kit GenAI's `genai-prompt` 1.0.0-beta4 pulls in
`com.google.android.datatransport:transport-runtime` transitively (verified
directly against the AAR's POM) — the same Firelog usage-stats pipe ADR-0006
audited in 2026-04 (invocation counts, latency, model version, crash
reports; **no prompt/response content**). `ManifestPrivacyTest
.noAnalyticsLibraries_onClasspath` does not forbid this class (it only bans
first-party analytics SDKs a developer would consciously choose — Firebase
Analytics/Crashlytics, Google Analytics, Sentry, Mixpanel, Segment,
Amplitude), so no test change was needed; its stale doc comment claiming "no
ML Kit dependency remains on the classpath" is corrected in this change.

No network call originates from OUR code for this feature — `AICore`/Play
Services own the model fetch entirely, same as ADR-0006's original ML Kit
finding. `networkCallers_matchAllowList` (AC5) is unaffected.

## Consequences

### Positive
- Devices with Gemini Nano skip a 557MB download for the smallest tier —
  matches the Mac's "the platform's own model is the cheapest good option"
  posture.
- One policy (`MiniBrainPolicy`) makes the decision; both DI call sites
  consult it, so there's no way for the initial pick and a mid-session
  tier switch to disagree.

### Negative / open
- **Not live-reactive.** The probe runs once at first `get<MiniBrain>()`;
  a system model that finishes downloading (or becomes newly eligible)
  mid-session won't be picked up until the next app launch.
- **Streaming delta shape is unverified on hardware.** `generateContentStream`
  wasn't exercised on a real device this session — `GeminiNanoEngine`
  defends against both a cumulative-snapshot and an incremental-chunk shape
  (see its `diffAgainstPrevious` KDoc), but which one ML Kit actually uses
  is a device-verify item, not proven here.
- **No fallback-mid-session if a Downloadable/Downloading device's fetch
  ultimately fails.** `GeminiNanoEngine.initialize()` returns `Result.failure`
  in that case; there is no code path that re-resolves to the Qwen weights
  engine within the same process. Revisit if this proves to matter in
  practice.
- Tool schemas still get rendered into the persona/system half of the
  ChatML split (Gemini Nano can't act on them — it just reads them as more
  context). Harmless today; would want reconsidering if Mini's tool-relevant
  turns become common.

### Alternatives rejected
- **A new `LlmModel` identity for "Mini via system model."** Rejected —
  it would ripple through every model-keyed surface (download size, tier
  display, onboarding, `isModelDownloaded`) for a distinction that's really
  about *which engine answers*, not *which weights*. `MiniBrain` as a
  resolution layered ON TOP of the existing `LlmModel` identity keeps that
  surface untouched.
- **Re-render the prompt for Gemini Nano from `EnrichedContext` directly**
  (bypassing `UnifiedPromptBuilder`/ChatML entirely). Rejected for this pass
  — it's the more "correct" long-term shape (a system/user split built
  natively, no ChatML markers to parse back out) but is a bigger
  `ChatWithToolsUseCase`/`ChatScreenViewModel` change than this ADR's scope.
  `ChatMlPromptSplit` is the smaller, safer cut: it recovers what's already
  there rather than restructuring how it gets built.
