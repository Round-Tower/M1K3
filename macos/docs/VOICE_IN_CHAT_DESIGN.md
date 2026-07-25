# Voice in the chat — merging voice-first into the conversation (design)

**Status:** DESIGN — Kev's 07-25 direction ("voice first should/could be
integrated into the main chat view, or a minimal version of it"). No code.
Build next session behind a Settings toggle so it's felt against the current
hero, not argued in the abstract.

## The scar this design respects

We merged voice into chat once before — the 06-21 bottom VoiceDock — and Kev
reverted it within a week: the avatar shrank to a 92pt corner card and the
whole thing read as a regression. The lesson wasn't "don't merge"; it was
**the avatar must stay the hero**. What didn't exist then and does now:

- `AvatarChatBackground` — the avatar as a full-window reactive backdrop
  behind the glass bubbles (opt-in on Mac since 06-26; the DEFAULT chat
  experience on iOS since #57). The avatar can be enormous *and* the
  transcript can be present, simultaneously. That dissolves the 06-21
  trade-off.
- Sentence-streamed speech (07-25) — the transcript text and the spoken audio
  now advance together, which makes showing the transcript during voice
  *valuable* instead of redundant: you read along, and reading-while-waiting
  is itself a perceived-latency killer.

## The shape

Voice becomes a **state of the conversation**, not a separate room:

1. **Entering voice mode** (⌘⇧V / the toolbar button) stays in the chat view.
   The avatar promotes to the full-window backdrop for the duration (whatever
   the user's normal `avatarDisplay` preference — it restores on exit).
   Bubbles stay, streaming stays, scroll-back stays.
2. **The karaoke line** rides as a floating glass band directly above the
   input bar (not a separate hero overlay) — the current sentence with word
   highlight, exactly the `SpeechHighlight` feed that exists today.
3. **The input bar becomes the voice surface**: the mic state (listening /
   thinking / speaking) replaces the text field's placeholder region, with
   tap-to-barge-in on the whole band. **Typing is never disabled** — a
   keyboard message mid-voice-session is just a turn (the loop treats it as a
   barge-in + turn). Hybrid conversation is the point of the merge.
4. **The full-window hero (`VoiceModeView`) survives** as the *hands-free*
   presentation — a "expand" affordance on the karaoke band (and the current
   behaviour on iOS/visionOS where the windows are the hero anyway). Mac
   default flips to in-chat once it feels right; the hero is one tap away.

## Why not just keep the hero?

The hero is great at ambience and terrible at context: no scroll-back, no
chips, no visible stream while the model works, no typing escape hatch. Every
one of those exists in the chat view already — the merge is mostly *removal*
(of a parallel surface), not construction. Rubin would approve.

## Build plan (one PR, behind `voice.inChat` toggle, default OFF)

- **Phase 1 — the state.** `VoiceModeView` overlay mounts only when
  `voice.inChat` is off. When on: entering voice sets backdrop-promotion +
  shows the karaoke band + swaps the input-bar leading control to the loop
  state. The `VoiceLoopController` is UNTOUCHED — this is presentation only.
- **Phase 2 — hybrid input.** Typed sends while the loop is active: route
  through the same machine (`interrupt` + `runTurn`), pin the transitions
  red-first in `VoiceLoopMachineTests` (typed turn ≡ endpointed utterance).
- **Phase 3 — polish.** Entry/exit transitions (backdrop bloom/recede — the
  treatment exists), Reduce Motion arms, VoiceOver labels for the band
  (a11y parity with #30), then the default flip + hero demotion, Kev's call.

## Open calls (Kev)

1. Does the avatar promotion override an explicit `avatarDisplay = .off`
   (voice is the one moment the face justifies itself), or respect it?
2. Karaoke band: current-sentence-only (calm) or a two-line trailing window?
3. After the default flips, does the hero stay reachable on Mac at all, or
   become an iOS/visionOS-only presentation?

*Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.8 (design over
existing, named seams — every component cited exists and is tested; the felt
result is exactly what the toggle-gated build is for). Prior: Unknown.*
