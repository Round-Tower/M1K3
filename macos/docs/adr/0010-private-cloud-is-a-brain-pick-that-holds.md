# 0010. Private Cloud Compute is a brain you pick, and the pick holds

Date: 2026-10-01
Status: ACCEPTED — Kev, 2026-10-01 ("PCC moved to the brain picker - holds over time"; on the open question below: "I think it should be once")
Deciders: Kev + claude-opus-5-5
Supersedes: [ADR 0007](0007-private-cloud-consent-per-conversation.md), in part (where the control lives, and what turns it off)

## Context

ADR 0007 made PCC stay on for a conversation, through a cloud button beside
the message field. It turned itself off on a new or switched conversation, a
relaunch, a control that wasn't ready, or any staged attachment. In use that
read as PCC "not holding": pick it, start a new chat, and you're back on the
local brain without having asked to be. Kev's ruling: PCC belongs in the brain
picker with the other brains, and once picked it stays picked.

## Decision

- **PCC is a row in the brain picker** (the toolbar's brain menu), under the
  local brains, shown only when the rung exists (backend + Settings switch +
  org policy, unchanged). The composer's cloud button is gone. The picker's
  label names whoever answers the NEXT send: "Private Cloud Compute" with a
  filled cloud only when the send would really go there.
- **The pick holds** across conversations and relaunches. It is persisted
  (`PrivateCloudArming.selectedDefaultsKey`). This is a preference, not
  consent.
- **Consent is asked once.** The first PCC send opens the consent sheet as
  before; its answer, including the "also send this conversation" choice, is
  stored (`PrivateCloudArming.consentDefaultsKey`) and reused in every
  conversation and after a relaunch. It lives exactly as long as the pick.
- **One exception: text that never left this Mac.** With "also send this
  conversation" stored, any message in the shared history that never left this
  Mac (`ChatSession.onDeviceMessageIDs`: an answer made here, or a question no
  PCC answer followed) re-asks until a sheet has shown it. Clearing is by
  message id, not by conversation (PR #462 round two: a local turn landing
  after the sheet, from an attachment, an outage or voice, used to leave
  unseen). What was shown is never stored; a relaunch asks again.
- **Only the user ends the pick:** choosing a brain on this Mac, or "Keep it on
  this Mac" on the sheet. A rung that stops existing (the Settings switch off,
  org policy) ends it too, including at launch. Ending the pick forgets the
  stored consent, so the next pick asks again.
- **Some sends stay local while the pick waits.** A passing outage or an
  exhausted limit keeps the pick, and sends go to the local brain until PCC is
  back; the picker's label shows the local brain meanwhile. A staged
  attachment works the same way: images and files never ride a PCC turn, so
  that send stays local and the pick holds.
- **Only a typed send from the chat field goes to PCC.** Voice mode, retries and
  MCP `ask_m1k3` answer on this Mac whatever the pick, as before. The picker's
  label speaks for the chat field, and shows the local brain while voice mode
  is on (PR #462 review).
- **A late sheet clears only what it showed:** the ids are captured when it
  opens, so a sheet answered after a switch can't clear the new conversation.
- **Auto-route** still owns which local brain answers. The picker stays
  reachable for the PCC row, and the active local row un-picks PCC.

The lifecycle is still the pure `PrivateCloudArming`, pinned by
`PrivateCloudArmingTests`. ContentView only forwards events to it.

## Consequences

- A PCC user picks it once and sees one sheet, then plain Return everywhere.
- The pick outlives a relaunch, so the app can open with PCC selected. The
  label says so before anything is sent. Its stored consent means the first
  message goes without a sheet. That is the cost of "once", accepted.
- An attachment turn quietly answers on-device while PCC is picked. The label
  and its tooltip say so ("Attachments never go to Private Cloud Compute").
- **App Review:** the control moved. If review notes describe PCC, they should
  say it's in the brain picker, and that it stays picked until a local brain is
  chosen.
- Settled (Kev): once ever, not once per conversation. The include-the-
  conversation choice becomes a stored default, and the on-device-history
  exception is what keeps that safe.
- ADR 0007's "consent is never stored" no longer holds; its per-turn label
  does, and so does "attachments never ride a PCC turn".

<!-- Signed: Kev + claude-opus-5-5, 2026-10-01. Kev's ask; the shape (pick
     persisted, consent per conversation, transient states keep the pick) is
     the proposal. Confidence 0.8 (the state machine is pinned; the menu's feel
     is verify-by-launch). Prior: ADR 0007. -->
<!-- Review: Kev + claude-opus-5-5, 2026-10-01 — ACCEPTED. Kev tested PCC in the picker ("it's
     working nice") and chose once-ever consent; the on-device-history exception is the proposal
     that keeps the stored include-the-conversation choice safe. Confidence 0.85. -->
