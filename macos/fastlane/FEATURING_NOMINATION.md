# App Store featuring nomination — M1K3 1.0 (paste-ready)

Submit in **App Store Connect → M1K3 → Featuring Nominations → New** (role:
Account Holder / Admin / App Manager / Marketing). Apple asks for three
weeks' lead; a launch nomination is still the right type at launch — the
editorial window for a new release is weeks, not months. Every field below
is within its cap (name 60 · description 1,000 · helpful details 500) and
every claim is true of the shipping 1.0 build (Mac build 362, iOS build 361).

**Nomination name** (≤60)
> M1K3 1.0 — a private, on-device AI companion for Mac (Golden Gate launch)

**Nomination type** → **App Launch** (cannot be changed after submission)

**Description** (≤1,000)
> M1K3 is a local AI companion for Mac, iPhone and iPad from a solo Irish
> developer. Everything runs on the device: three brain tiers — Apple's own
> Foundation Models as the fast first tier, then Qwen and Gemma on MLX — a
> neural voice (Kokoro on MLX), a 3D companion in RealityKit, and your notes
> and PDFs as searchable memory you can read, edit and export. No account,
> no cloud, no analytics: Apple's privacy label reads Data Not Collected.
>
> 1.0 lands with macOS 27 Golden Gate. The app is Apple Silicon only — the
> same Macs Golden Gate runs on — and built for the platform: SwiftUI and
> Swift 6 throughout, Liquid Glass, Core Spotlight indexing, a menu-bar
> companion and a notch caption that follows the voice, a screensaver, full
> VoiceOver and Reduce Motion support. Brain at Home lets an iPhone borrow
> the Mac's brain over the local network, encrypted, with no relay. It is
> also an MCP server: Claude Code, Cursor and other agents can use it as a
> private knowledge store on the machine.
>
> Universal purchase, free, eight languages. Source-available on GitHub.

**Publish date / time frame** → the 1.0 release day (approval + Kev's
manual release) through the following four weeks. Pick **Range**.

**Related apps** → M1K3 (6780230835) only.

**Platforms** → macOS, iOS (iPhone), iOS (iPad). Leave visionOS unticked
until a visionOS build is attached (1.0 ships none).

**Countries or regions** → all 175 (as available). **Localizations** →
en-US, de-DE, es-ES, fr-FR, ja, ko, pt-BR, zh-Hans (auto-selected).

**In-App Events** → attach **"Waking Up"** once it is approved or published
(`events/waking-up/`). Apple: attach as early as possible.

**Supplemental materials** (≤5 URLs)
1. https://m1k3.app — the product page (hero, brains scoreboard, privacy)
2. https://m1k3.app/install — the two-minute install wizard
3. https://m1k3.app/brains — the public eval harness behind the brain picks
4. https://testflight.apple.com/join/Fxp2F5Je — TestFlight public link
5. https://github.com/Round-Tower/m1k3 — the source

**Helpful details** (≤500)
> Built by one developer (Kevin Murphy, Ardmore, Ireland — also behind the
> dyslexia reading tutor Lexy). Accessibility is first-class: VoiceOver
> labels throughout, Reduce Motion and Reduce Transparency honoured, a
> dyslexia-friendly reading mode in the chat. Privacy is structural, not a
> policy: the App Sandbox build has no network path for conversations,
> and the model weights are the only download. Happy to supply captures,
> a preview video, or a walkthrough on request: kevin@round-tower.ie.

## Editorial angles this fits (for the description's emphasis, not to paste)

- **Golden Gate day-one** — a Mac app built on the frameworks the release
  headlines: Foundation Models, Liquid Glass, Apple Silicon only.
- **"Made for Mac"** — menu bar, notch, screensaver, Spotlight, sandbox.
- **Privacy** — Data Not Collected on a chatbot is rare; it is the story.
- **Accessibility spotlight** — built by a dyslexic developer, reading mode
  in the product.
- **Indie / solo-developer story** — the same card Cartogram played.

## What is NOT claimed (keep it that way)

No download numbers (none are public yet), no visionOS, no Private Cloud
Compute (ADR 0006's rung is a later release), no "open source" (FSL-1.1 —
say source-available), no third-party marks in the copy.

<!--
Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: cartogram/CartogramMac/fastlane/FEATURING_NOMINATION.md and
  dyslexia-ai/ios/marketing/press/apple-featuring-2026-09.md (the shape).
Context: fields and caps read off Apple's nominations template
  (developer.apple.com/help/app-store-connect/reference/nominations-template);
  "in-app events are iPhone and iPad only" is the form's own note. Every
  framework named is in the 1.0 tree; the privacy label state was clicked
  by Kev on 2026-09-15. Kev pastes and submits — the form is his click.
-->
