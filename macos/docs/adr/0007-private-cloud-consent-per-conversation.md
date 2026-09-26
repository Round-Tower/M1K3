# 0007. Private Cloud Compute consent holds for a conversation, not one request

Date: 2026-09-26
Status: PROPOSED — awaiting Kev
Deciders: Kev (the ask: "PCC should stay on when selected by the user") + claude-opus-5-5
Supersedes: the "Default OFF, per request" constraint of [ADR 0006](0006-private-cloud-compute-rung-and-the-private-by-design-posture.md), in part

## Context

ADR 0006 made the PCC rung an explicit escalation, one request at a time: the
cloud control armed the next message, the consent sheet opened on every send,
and the control fell back to local after each answer. In use, a conversation
with the bigger brain meant a click and a sheet per turn. Kev's ruling: once
the user turns PCC on, it should stay on.

## Decision

The control turns PCC on **for the current conversation**:

- **Consent once per conversation.** The first PCC send opens the consent
  sheet as before (what leaves, where it goes, the grounding opt-in, the
  "also send this conversation" choice). Later sends in the same conversation
  go straight to PCC and reuse that choice.
- **Still default OFF, still never automatic.** Nothing changes about when the
  control exists (backend + Settings switch + org policy) or about automatic
  spill-over: there is none.
- **It turns itself off** when the consent could be stale or can't be honoured:
  "Keep it on this Mac", a manual off, a new or switched conversation, a
  relaunch, a control that isn't ready (switch off, quota exhausted,
  unavailable), or any staged attachment (images and files never ride a PCC
  turn).
- **Visible, every time** still holds: the lit control says "On for this
  conversation", and every PCC answer keeps its transcript label.

The lifecycle is the pure `PrivateCloudArming` (M1K3LanguageModel), pinned by
`PrivateCloudArmingTests`; ContentView only forwards events to it.

## Consequences

- A PCC conversation is one click and one sheet, then plain Return.
- The "every time" of ADR 0006's consent sheet becomes "every conversation".
  The label on each answer and the lit control carry the per-turn visibility.
- Consent is never stored: it lives in view state, so it can't outlive the
  conversation or a relaunch, and it can't leak between conversations.
- **App Review:** the consent flow changes in a build that goes to review.
  The sheet's wording is unchanged; the review notes should say PCC stays on
  for a conversation once the user has confirmed it.

<!-- Signed: Kev + claude-opus-5-5, 2026-09-26. Kev's ask; the shape
     (once per conversation, off on any staleness) is the proposal.
     Confidence 0.8 (the state machine is pinned; the feel of a sticky cloud
     control is verify-by-launch with the Debug echo backend). Prior: ADR 0006. -->
