# M1K3 Design Doctrine

> Written out of the 2026-08-03 project dream cycle — a Tier-0/1/2 pass
> (measure → date → supersede) over the app, the brand, and the docs.
> Test every UI, copy, and brand decision against this before shipping.
> Change it by superseding a principle, not by quietly violating one.

## The essence

**M1K3 is a resident, not a service.** It lives on this Mac, remembers you
across every context window, and can *prove* nothing left.

Everything else — the voice, the face, the corpus, the creatures, the MCP
port — is evidence of residency. If a feature doesn't make M1K3 more
*present* or the proof more *legible*, it isn't serving the product.

## The principles

1. **The container is Apple's. The creature is M1K3's.**
   Liquid Glass, materials, chrome, navigation, controls, system type =
   Apple's layer. Pixel, grayscale, CRT, dial-up, the face, the boot =
   M1K3's layer. The retro always appears *inside* a frame Apple drew.
   Never a pixel-styled button; never a glass face. If you can't name the
   layer a new element belongs to, it doesn't ship.

2. **Retro dresses M1K3, never the user's tools.**
   Pixel/CRT applies to what M1K3 *is* (face, voice, state, waking up). It
   never applies to what the user *does* (fields, lists, settings,
   toolbars). A retro control is a costume on the wrong actor.

3. **One noun per concept — the list is closed.**
   `brain` (never model / engine / runtime / tier in UI) ·
   `companion` (the product) · `face` (the pixel avatar) ·
   `creature` (the opt-in 3D pet) · `memory` (the fact graph) ·
   `documents` (the corpus). A new noun requires killing an old one.

   **The machine / Mac split** (Kev, 2026-08-03 — *"M1K3 is a mechanic
   after all"*). Same layer rule as principle 1, applied to a word:
   - **M1K3 says "machine."** His own voice — persona, boot lines, the
     Hear-a-sample line, spoken answers, first-person UI copy. It's his
     register already: the system prompt ends *"just you and the machine."*
     A mechanic talks about the machine he keeps running.
   - **The chrome says "Mac."** Product name, store listing, site,
     requirements, platform claims. That's Apple's layer, and "M1K3 for
     Mac" / "Your AI. Your Mac. Nothing leaves." are load-bearing for
     search and for the platform-trust promise. The shop sign says Mac.

   **The seam already exists.** `HostPlatform.noun` (M1K3Inference) is the
   single source for the machine noun in every persona and tool string —
   built in 2026-07-18 when Mini introduced itself as running "on this Mac"
   *on an iPhone*. Flipping macOS's arm from `"Mac"` to `"machine"` is one
   line, and `thisDevice` / `yourDevice` carry it everywhere.

   ⚠️ **But it is deliberately frozen.** `HostPlatformTests` pins the macOS
   arm byte-identical to the literals it replaced, precisely because gemma
   is prompt-fragile and the Mac persona is A/B-frozen. So this is a
   *measured* pass — flip the noun, re-pin the tests, A/B both brains
   before it ships — never a hot edit. Third-person chrome that names the
   platform ("Your Mac is blocking the mic — flip M1K3 on in System
   Settings") stays "Mac": that sentence is about Apple's layer, and
   sending someone to System Settings on their "machine" helps nobody.

4. **A setting is a decision you failed to make.**
   A new toggle must pass all three: (a) two real users would genuinely
   choose differently, (b) the wrong default actually hurts, (c) it's
   expressible in the closed vocabulary. Otherwise decide it.
   **Accessibility and consent are exempt** — those aren't settings,
   they're promises.

5. **Say a promise once.**
   Privacy *is* the product; every duplicate consent wording weakens the
   claim. One dialog, one wording, one place.

6. **Show a state once.**
   Progress in nine places isn't reassurance, it's anxiety. One canonical
   place (where you're waiting) plus one ambient place (the menu bar).
   Zero elsewhere.

7. **Engineering nouns don't ship.**
   Embeddings, runtimes, weights, self-tests, generation stats. Give the
   instrument a hidden door; take it off the main road.

8. **The voice is part of the surface — copy included.**
   Warm, dry, brief, faintly villainous. If a sentence could describe any
   privacy SaaS, it isn't describing M1K3. Applies to the App Store, the
   site, JSON-LD, error strings, and empty states.

## Protected species (measured, then refused as cuts)

These look like clutter in an audit and are actually the soul. Do not
"clean them up":

- **The dial-up loop** — turns the worst moment (a long download) into a
  character moment, and it's the one place the product's offline ancestry
  is audible. The inline mute stays (courtesy, not a setting).
- **The CRT rolling band** — the heartbeat. The one signal the face is
  alive and running *here*, not a shipped PNG. Never a setting.
- **The villain persona** — remove it and this is a grey privacy utility
  with a pixel face. It belongs *in the marketing*, not just the prompt.
- **Reading modes (all four)** — this product descends from dyslexia work.
  Reduce the ceremony (ask once, at onboarding), never the capability.

## Standing decisions

- **One name: M1K3.** The leetspeak already reads as "Mike" — the product
  never explains the joke or introduces a second name. Users may call it
  whatever they like.
- **Companion, not assistant.** An assistant is defined by tasks and is
  replaced by the next benchmark. A companion is defined by staying —
  and every M1K3 differentiator (memory, self-correction, face, voice) is
  a residency feature. "Assistant" survives only as an App Store keyword.
- **One mark: the pixel M.** Single source of truth for favicon, app icon,
  visionOS stack, and OG imagery. The labyrinth family is history (attic).
- **The face fronts the brand; creatures are guests.** OG images and
  first-run show the pixel face. The Fox appears only on the companions
  page.
- **M1K3 lives on a machine; the product runs on a Mac.** Ratified by Kev
  2026-08-03 — see the machine/Mac split under principle 3.

---
*Signed: Kev + claude-fable-5, 2026-08-03, Confidence 0.8 (the essence and
principles distilled from a measured audit — 3 repo scouts + the resident's
own corpus + a reduction pass; the vocabulary and protected list are
recommendations Kev has not yet ratified item-by-item. Treat "Standing
decisions" as proposals until a human merge confirms them — EXCEPT the
machine/Mac split, which is Kev's own call, made in-session). Prior: none —
new doc.*
