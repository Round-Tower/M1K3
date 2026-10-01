# 0010. Private Cloud Compute is a brain you pick, and the pick holds

Date: 2026-10-01
Status: PROPOSED — Kev's ask, 2026-10-01 ("PCC moved to the brain picker - holds over time"); the shape below is the proposal
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
- **Consent is still per conversation, and still never stored.** The first PCC
  send in each conversation opens the consent sheet as before. Its
  include-the-conversation answer is about that conversation, so it can't
  carry over.
- **Only the user ends the pick:** choosing a brain on this Mac, or "Keep it on
  this Mac" on the sheet. A rung that stops existing (the Settings switch off,
  org policy) ends it too.
- **Some sends stay local while the pick waits.** A passing outage or an
  exhausted limit keeps the pick, and sends go to the local brain until PCC is
  back; the picker's label shows the local brain meanwhile. A staged
  attachment works the same way: images and files never ride a PCC turn, so
  that send stays local and the pick holds.
- **Only a typed send from the chat field goes to PCC.** Voice mode, retries and
  MCP `ask_m1k3` answer on this Mac whatever the pick, as before; the picker's
  label speaks for the chat field.
- **Consent is bound to its conversation id**, not just cleared on a switch: a
  sheet answered after the active conversation changed can't arm the new one.
- **Auto-route** still owns which local brain answers. The picker stays
  reachable for the PCC row, and the active local row un-picks PCC.

The lifecycle is still the pure `PrivateCloudArming`, pinned by
`PrivateCloudArmingTests`. ContentView only forwards events to it.

## Consequences

- A PCC user picks it once. Each new conversation costs one sheet, then plain
  Return.
- The pick outlives a relaunch, so the app can open with PCC selected. The
  label says so before anything is sent, and nothing leaves until that
  conversation's sheet is confirmed.
- An attachment turn quietly answers on-device while PCC is picked. The label
  and its tooltip say so ("Attachments never go to Private Cloud Compute").
- **App Review:** the control moved. If review notes describe PCC, they should
  say it's in the brain picker, and that it stays picked until a local brain is
  chosen.
- Open: whether the sheet should show once per conversation (this ADR) or once
  ever. Once ever would make the include-the-conversation choice a stored
  default, which is a bigger step for a privacy-first app. Kev's call.

<!-- Signed: Kev + claude-opus-5-5, 2026-10-01. Kev's ask; the shape (pick
     persisted, consent per conversation, transient states keep the pick) is
     the proposal. Confidence 0.8 (the state machine is pinned; the menu's feel
     is verify-by-launch). Prior: ADR 0007. -->
