# 0006. Add Private Cloud Compute as an opt-in rung; move the posture from "Nothing leaves" to private by design

Date: 2026-09-14
Status: ACCEPTED
Deciders: Kev (the call) + claude-opus-5 (the SDK and runtime read, 2026-09-13, PR #317)

## Context

Since the soft launch, M1K3's promise has been **"Your AI. Your Mac. Nothing
leaves."** It appears in 32 files: the site (13 times on the landing page),
the README hero, SECURITY.md, two `project.yml` usage strings, and several
code comments.

On 2026-09-13 the macOS 27 SDK and runtime showed that
`PrivateCloudComputeLanguageModel` is a first-class `LanguageModel`:

- `availability = available` on this Mac, with the quota below its limit.
- `contextSize = 32768`, eight times Mini's 4096.
- Capabilities: vision, reasoning (`ContextOptions.reasoningLevel`), tools.
- Generation from an unentitled process fails with `ModelManagerError 1046`.
  The gate is the `com.apple.developer.private-cloud-compute` entitlement.

The policy for a network rung already exists and is test-pinned.
`EscalationLadder` has `Escalation.privateCloud`. `ChatEgressConsent` is its own
default-OFF key (Phase 17a), and an absent value counts as a no. The ladder
never picks a network model unless the egress switch is on **and** the user
escalated this request.

What blocked the PCC rung was the promise, not the code. Once a conversation
can leave the Mac, even to Apple's attested cloud, "Nothing leaves" stops being
literally true.

## Decision

1. **Ship PCC as an opt-in third rung** in 1.2, behind the existing ladder and
   consent key. Round Tower requests the entitlement now (see
   [../PCC_ENTITLEMENT_REQUEST.md](../PCC_ENTITLEMENT_REQUEST.md)).
2. **The posture moves from "Nothing leaves" to private by design.** The claim
   the product can always keep, and the one Teams buyers pay for, is this:
   *on your Mac by default; when you choose more power, it goes only to Apple's
   Private Cloud Compute, which keeps nothing and is independently verifiable;
   M1K3 itself never sees or stores your conversations.*
3. **The copy changes in the same release as the PCC rung, not before.** 1.0
   (2026-09-14) ships with "Nothing leaves", and that stays true until a build
   with the rung ships. Swapping the copy early would be dishonest in the
   other direction.

## Constraints the implementation must keep

These are what make "private by design" true rather than a slogan:

- **Default OFF, per request.** `ChatEgressConsent` stays default-OFF. No turn
  goes to PCC unless the user escalated it: an explicit "ask the bigger brain"
  control, never an automatic spill-over when Mini's window fills.
- **Visible, every time.** Every answer produced by PCC carries a label in the
  transcript, and the consent sheet says in one sentence what leaves (this
  turn plus the grounding M1K3 attaches) and where it goes.
- **Grounding is the user's call.** Memories and document excerpts attached to
  a PCC turn are listed in the consent sheet. The first version sends none
  unless the user ticks them.
- **Quota and failure are honest.** Show `quotaUsage`. On `rateLimited`,
  `quotaLimitReached` or a network failure, fall back to the local brain with
  one sentence saying why. Never an empty bubble.
- **The claims are Apple's, cited.** Site copy about PCC quotes Apple's current
  published guarantees and links to them. We verify them against Apple's docs
  at implementation time rather than paraphrasing from memory.
- **Offline users lose nothing.** With consent off, the app behaves exactly as
  1.0 does. The test suite pins that the ladder never selects `.privateCloud`
  with `networkAllowed == false`.

## Consequences

- **Tagline:** Kev picks the wording at copy time. The recommendation is
  **"Your AI. Your Mac. Private by design."** It keeps the rhythm and the
  first two beats.
- **Copy sweep in the PCC release:** 32 files (inventory:
  `rg -il 'nothing leaves' --glob '!*.jsonl'`). Code comments that describe
  on-device-only behaviour stay if they are still true of that path. The two
  Brain-at-Home `NSLocalNetworkUsageDescription` strings stay as they are,
  because Brain at Home really never leaves the network.
- **App Store privacy label:** decide whether PCC processing changes the "Data
  Not Collected" answer. Check Apple's guidance for PCC at implementation time;
  don't assume either way.
- **SECURITY.md** gains the PCC rung in its threat model: what leaves, the
  attestation Apple provides, and what M1K3 logs (nothing about the content).
- **Teams** (ADR 0005): on-prem deployments get a policy switch that forces the
  rung off, since some buyers will need a hard "never leaves".
- **Risk:** the posture change is one-way in the market's memory. Once the
  landing page stops saying "Nothing leaves", it can't credibly say it again.
  Accepted, because the stronger long-term claim is privacy that can be
  verified, which PCC supports.

<!-- Signed: Kev + claude-opus-5, 2026-09-14. Kev's call; the constraints are
     derived from the existing EscalationLadder / ChatEgressConsent contracts
     and the 2026-09-13 runtime probe. Confidence 0.8 (the product direction is
     decided; PCC generation itself is unprobed until the entitlement arrives,
     and the App Store label question is open). Prior: Unknown -->
