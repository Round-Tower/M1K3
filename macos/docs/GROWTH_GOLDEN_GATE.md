# Getting M1K3 found — the Golden Gate ASO plan (2026-09-15)

The listing is in review. This is the plan for the four weeks after
approval, written by the ASO lead the night before, with what the API, the
tree and Apple's own forms say — not what we'd like them to say. Companion
files: `fastlane/FEATURING_NOMINATION.md` (paste-ready), `fastlane/events/
waking-up/` (the in-app event), `tools/asc/` (the scripts), and the review
prompt that ships in 1.0.1 (`ReviewPromptPolicy`).

## 1. Where discovery actually comes from, for a free Mac app

Three facts shape everything below.

1. **Ratings gate search.** A listing with no ratings is invisible for every
   generic term however good the keywords are (Cartogram's July audit; the
   Lexy funnel). 1.0 shipped with **no way to ask for a rating** — fixed in
   this PR (see §4). Nothing else on this page pays off until the count
   moves off zero.
2. **Featuring is the only lever that reaches Mac App Store shoppers at
   scale**, and it is a form we have never filled in. Apple Ads do not run
   on the Mac App Store at all (iPhone/iPad search only); in-app events do
   not show on the Mac either (Apple's nomination form says so in as many
   words). The Mac's front door is editorial or external, full stop.
3. **External traffic converts**: the Lexy funnel's page-view→install rate
   never dropped below 56 %. The problem to solve is qualified reach, and
   Show HN, the local-AI subreddits and the Mac press are where this
   product is native.

## 2. Featuring — the nomination goes in the day the app is approved

- **What:** `fastlane/FEATURING_NOMINATION.md`, type *App Launch*, range =
  release day + four weeks, platforms macOS + iPhone + iPad, the "Waking Up"
  event attached once approved. Kev pastes; the form is ASC-only.
- **Why it can land:** the story is Apple's own — Foundation Models as the
  first tier, MLX, Liquid Glass, Apple Silicon only on the day Golden Gate
  dropped Intel, Data Not Collected on a chatbot, VoiceOver throughout, a
  solo developer. Editors pick apps that showcase the release.
- **Lead time honesty:** Apple asks for three weeks; we are at zero. Launch
  nominations still get read — Cartogram's went in post-release. The
  next window with real lead time is a **1.1 "App Enhancements"**
  nomination filed the day 1.0.1 ships, so 1.1 (the Golden Gate-native
  build on the 27 SDK) is the one to plan three weeks out.
- **The missing asset:** there is **no app preview video** anywhere in the
  repo. Editorial surfaces lean on previews; the storyboards exist
  (`marketing/app-store/CAPTURE-PLAN.md` §3: iPhone "Airplane mode, then
  ask." ~22 s; Mac "Pull the cable." ~20 s). This is the single highest-
  value asset Kev can make this week — it also leads the Show HN post.

## 3. "Waking Up" — the launch event (iPhone + iPad)

`fastlane/events/waking-up/`: PREMIERE badge, ATTRACT_NEW_USERS, 18 Sep →
16 Oct, eight locales of copy within every cap (pinned by test). **A draft
already exists on the record** (6811192045, art uploaded in all eight
locales, copy over every cap, wrong badge, past start) — `tools/asc/
events.py update` fixes it in place; the write is Kev's click, then the
submit is too. **Honest scope:** it will not
appear on the Mac App Store. Its value is the iOS search card, the Today
tab lottery, and the nomination attachment. If the art costs more than an
hour, ship the nomination without it and attach later.

## 4. Ratings — the review prompt (ships in 1.0.1, this PR)

- `ReviewPromptPolicy` (M1K3Inference, pure, pinned): ask when **two liked
  answers** *or* **twenty completed turns**, **and** the app has lived with
  the user **three whole days**, **once per marketing version, ever**. The
  system's three-per-year throttle is the backstop, not the policy.
- `ReviewPromptLedger` owns the facts (UserDefaults; a dictionary in tests);
  under the screengrab harness it stamps, counts and prompts nothing.
- Consumed only where a window can show the sheet (Mac ContentView, iOS
  ChatScreen), two seconds after the answer lands — never on the last token.
- Manual doors: **Help ▸ Rate M1K3 on the App Store…**, Settings ▸ General ▸
  App Store on the Mac; Settings ▸ About on iOS.
- **Ask Kev to rate it himself on release day, from two Apple IDs he owns
  the devices for.** Two honest ratings beat zero for search eligibility.

## 5. Custom Apps / Apple Business Manager — the Teams question

What the docs say (verified 2026-09-15): Custom Apps cover **iOS, iPadOS
and macOS**; an app record is **Public or Private, chosen before its first
approval and locked after**; a private variant is therefore a **separate
record with its own bundle ID** (`app.m1k3.teams`), reviewed through the
same App Review, bought by the organisation through Apps and Books
(Volume Purchase — Apple's commission applies), assigned by MDM or
redemption code. The buyer identifies itself by its **Organization ID**.

**Recommendation: not yet — and the reason is the product, not Apple.**
ADR 0005 sells three fixed-scope on-prem pilots *before* building the
multi-user/admin surface; a Custom App is a distribution channel for a
product that exists. Building the second record now would be a channel
with nothing distinct to put in it. Two things to do today instead:

1. **Say the true thing on /teams:** the public app is already
   purchasable (free) by any organisation in Apple Business Manager's
   Apps and Books and deployable by MDM, because it is a standard App
   Store app. That sentence costs nothing and answers the IT question.
2. **Fix the policy-key read before any fleet claim.** `/teams` promises
   "an administrator locks the Private Cloud Compute switch off
   fleet-wide", but `AppEnvironment+PrivateCloud.swift` reads the key
   with `UserDefaults.standard.bool(forKey:)` — a user-writable value is
   honoured identically to an MDM-forced one. The rung is compiled out of
   1.0 so nothing is live, but the read must check the **forced** value
   (`CFPreferencesAppValueIsForced`) before 1.2 ships the rung. Issue
   filed with this PR.

**When to revisit:** the third pilot, or the first buyer who says "we can
only procure through Apps and Books". The Lexy precedent is real — one
institutional purchase was a hundred times a year of consumer ASO — so
the channel is worth having *when there is a Teams build to put in it*.

## 6. Paid reach, cheaply — and what not to buy

- **Apple Ads (formerly Apple Search Ads):** iPhone/iPad only, cost-per-tap,
  no account exists anywhere in the portfolio (GROWTH-LOOP.md §3). Worth a
  **$5–10/day, two-week brand-defence test** on the iOS listing *after*
  approval — bid `m1k3`, `local AI`, `private AI`, `offline AI` — chiefly
  to read the search-term report Apple otherwise hides below its privacy
  threshold. It will not move the Mac. Kev opens the account (Apple ID
  that owns the app) at ads.apple.com.
- **Reddit ads** (r/LocalLLaMA, r/macapps, r/MacOS): CPM, ~$5/day floors,
  the exact audience. Only after the organic posts land — a promoted post
  in a subreddit that has just upvoted the organic one is the cheap
  version; a cold promoted post there is the expensive one.
- **Do not buy:** Product Hunt promotion, newsletter sponsorships
  (TLDR-class slots run to four figures), Mac download-site placements.
  Free listings on AlternativeTo, MacUpdate and the awesome-lists do the
  same job at zero.

## 7. Free reach — the launch-week sequence (D = release day)

| Day | Move | Owner | Where the words are |
|---|---|---|---|
| D | Press release ×2; merge #336 (site CTAs), flip /install's `APP-STORE-LIVE`; IndexNow ping | Kev / agent | ROADMAP "On approval" |
| D | **Featuring nomination** submitted; **Waking Up** DRAFT created + submitted | Kev | `fastlane/FEATURING_NOMINATION.md`, `events/waking-up/` |
| D | Kev rates the app from his own devices; `promo.py` sets the launch promotional text on Mac + iOS | Kev / agent | `tools/asc/promo.py` |
| D+1 (Tue–Thu, 14:00–16:00 Irish) | **Show HN** with the preview video | Kev | `marketing/01-show-hn.md` |
| D+1 → D+3 | r/LocalLLaMA, r/macapps, lobste.rs, six MCP registries, Homebrew cask bump | agent | `marketing/09-soft-echo-drafts.md` |
| D+2 | Tips to MacStories, Six Colors, 9to5Mac, Cult of Mac, The Sweet Setup — lead with the network-monitor clip | Kev (from his address) | `marketing/06-growth-hacking.md` §8 |
| D+7 | Read ASC: impressions, product-page views, conversion, **ratings count**; first `precheck.py` run on the 1.0.1 version | agent | Monday pulse |
| D+14 | Apple Ads test starts (if the account exists); murphysig relaunch ≥ 2 weeks after Show HN (the two-HN-cards rule) | Kev | playbook |
| D+21 | 1.0.1 to review with the prompt; file the **1.1 App Enhancements nomination** three weeks ahead | both | ROADMAP 1.0.1 list |

## 8. Listing fixes — done here, and the queue

Done in this PR: the fr-FR ("sur Mac") and pt-BR ("no Mac") subtitles no
longer name the Mac on a field the iPhone storefront shares; `tools/asc/`
exists with pytest pins; the visionOS record's `GPT`/`AGI` keywords are
scannable (`keywords.py scan`) and fixable (`apply`) the moment that
version is editable.

Queue, in value order:
1. **App preview video** (Mac + iPhone) — §2. The lead asset for everything.
2. **A real `/support` page** — every locale's support URL is the homepage.
   Reviewers and editors click it.
3. ~~**iOS metadata source of truth**~~ — done 2026-10-01 (§10). `metadata_ios/` did not exist; the
   iOS listing's words live only in ASC. Pull them into the tree so the
   metadata guard covers them.
4. **en-US keyword headroom** — 100/100; reclaim from the ko/zh-Hans
   near-duplicate pairs first, then add `Apple Intelligence`-adjacent terms
   only if the search-term report (Apple Ads) shows demand.
5. **OG image** — still the June hero with the retired "Nothing leaves." alt
   text; regenerate from the 1.0 plate with "Private by design."
6. **Release notes in the seven non-English locales** — 1.0.1 ships an
   English-only What's New otherwise.

## 9. What to read, and when to change course

- Weekly (the Monday pulse's ASC tap): impressions, product-page views,
  page-view→install, **ratings count and average**, first-time downloads
  by source type (App Store search / browse / referrer / institutional).
- If featuring lands: browse impressions spike for ~3 days; that is the
  window to have the preview video and the review prompt live.
- If ratings stay under 10 by D+21: the prompt thresholds are the knob
  (`ReviewPromptPolicy.minCompletedTurns`), not more marketing.
- If an institutional (Apps and Books) purchase ever shows in the source
  breakdown: §5's "revisit" condition has fired.

## 10. The 2026-10-01 listing pass — keyword-first name, honest platforms

Kev's call: **"Local Offline AI Agent – M1K3"** / **"Private chat, voice &
memory"**. 1.0 was not live in any storefront (lookup → 0 results in us, ie,
gb, de), so the rename cost no ranking history.

What the research said (Apple-verified unless marked):
- **Word order in the name is folklore** (ASO blogs only); the words are what
  count, and name > subtitle > keywords is the consistent weighting. Every
  leader in the niche stacks Local / Offline / Private + AI + Chat/Assistant:
  Locally AI (1,705 ratings), Enclave (1,083), Private LLM (729). On the Mac
  store the *agent / coding-agent* angle is thin (BonzAI, 16 ratings) — hence
  "Agent" in the name and MCP/coding in the Mac keywords.
- **Storefront locale stacking** ([Apple's table](https://developer.apple.com/help/app-store-connect/reference/app-store-localizations)):
  the US storefront also shows es-MX (not es-ES), zh-Hans, zh-Hant, fr-FR,
  ko, pt-BR, ru, vi, ar; Germany, France, Spain, Mexico, China, Korea, Brazil
  each add **en-GB**. Indexing those for search is an industry observation
  (AppTweak, MobileAction), not an Apple statement. Added **en-GB** and
  **es-MX**; es-MX's keyword field carries English terms the US storefront
  reads that en-US had no room for.
- **Custom Product Pages in organic search** (70 pages, keywords from the
  latest approved version) and **Product Page Optimization** are iOS/iPadOS
  only — they cannot reach the Mac store. **App Store tags** are US-only,
  generated from en-US metadata; deselect-only, under App Information.
- **Screenshot-caption OCR** (blog-reported, June 2025) measured weak: 1 of
  64 caption phrases ranked without metadata support. Captions reinforce
  keywords; they don't add reach.

Done in this pass:
- `metadata_ios/` — the iPhone listing had the Mac's description word for
  word ("runs entirely on your Mac", Big 12B, MacBook Air to Mac Studio, the
  CLI, "delete at any time" though iOS memories are read-only). Now its own
  copy, in 10 locales, from what `MobileBrainMenu` / `project.yml` ship.
- **Web search defaults ON** on both platforms (`PrivacySettingsPane.swift`,
  `SettingsScreen.swift`), but every description said "a web search you
  explicitly turn on" — rewritten in all locales; the "nothing ever leaves"
  promo lines now say the notes and PDFs never leave.
- `check_store_metadata.py` now fails a PR on shared-field drift between the
  platform folders and on device claims (shared fields name no device; the
  iPhone copy names the Mac only on a Brain at Home line).
- TestFlight: per-platform "What to Test" via Xcode Cloud's
  `TestFlight/WhatToTest.<locale>.txt` contract (`ci_scripts/select_what_to_test.sh`;
  builds 438/439 shipped with the field empty), and the record-wide beta
  description tracked in `TestFlight/beta_description.en-US.txt`
  (`tools/asc/testflight.py`).

Queue from here, in value order:
1. **Apply** — the staged commands in the PR body (`fastlane mac metadata`,
   `fastlane ios metadata`, `testflight.py set --confirm`); ASC writes are
   Kev's.
2. **iOS CPPs** once 1.0 is approved: 3–5 pages per intent cluster
   (offline chat / PDF / transcribe / voice), each with its own keywords.
3. **Tags**: read the generated en-US tags the week of approval, deselect any
   off-brand.
4. **ru, zh-Hant, vi, ar** — the rest of the US stack; needs native-quality
   copy (or English-keyword-only fields), and a look at which of those
   storefronts the app is available in.
5. **visionOS** — its draft version still carries the Mac copy and no build;
   give it a `metadata_visionos/` when it gets an archive action.
6. **Screenshot captions** that echo the keyword set (weak signal, free).

Sources: [ASC app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) ·
[localizations](https://developer.apple.com/help/app-store-connect/reference/app-store-localizations) ·
[CPPs](https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions/) ·
[tags](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-tags) ·
[PPO](https://developer.apple.com/app-store/product-page-optimization/) ·
[AppTweak cross-localization](https://www.apptweak.com/en/aso-blog/how-to-benefit-from-cross-localization-on-the-app-store) ·
[MobileAction](https://www.mobileaction.co/blog/app-store-cross-localization/) ·
[caption OCR test](https://appscreenshotstudio.com/blog/how-apple-ocr-indexes-app-store-screenshot-text-2026) ·
[Xcode Cloud tester notes](https://www.finnvoorhees.com/words/platform-specific-release-notes-with-xcode-cloud)

<!--
Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: none (new). Context: Apple-side facts (in-app events iPhone/iPad
  only; nomination fields and lead time; Custom Apps platforms and the
  Public/Private lock; Apple Ads placements) read off developer.apple.com
  and support.apple.com on 2026-09-15; portfolio facts (no Apple Ads
  account, the Lexy funnel, Cartogram's nomination) read off the sibling
  repos the same day. Budgets are recommendations, not commitments.
  Honest opens: whether featuring lands is Apple's call; the event art is
  not generated; Kev's Apple Ads account does not exist yet.
Review: Kev + claude-opus-5.5, 2026-10-01 — §10 added (the rename, the
  iPhone listing's own copy, the web-search honesty fix, locale stacking,
  TestFlight notes); §8 item 3 closed. Confidence 0.75 for §10: the Apple
  facts are read off developer.apple.com, the ranking claims are ASO-blog
  observations and say so.
-->
