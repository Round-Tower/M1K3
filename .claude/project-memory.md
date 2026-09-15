
---
## Session — 2026-09-15 (night) · growth/review-prompt → PR #354 · THE ASO LEAD SESSION: the rating ask ships in 1.0.1, the App Store Connect scripts get a home, and three "launch event" ideas meet Apple's actual rules

**Context:** Kev: "you're the ASO lead now. We need to get M1K3 discovered by Apple — how do we push the boundaries? A launch event for Golden Gate, perhaps 'Waking Up' — Custom Apps for Enterprise perhaps — marketing we can pay for cheap reach… we also have not review functionality… use M1K3 for comms." Plan mode opened it; the harness moved to auto mid-scouting, so it became build + plan. Three Explore scouts (metadata, review-prompt seams, Teams + portfolio tooling), five Apple fact checks, a local code-quality pass before the first push, comms via `speak` throughout. Worktree `../m1k3-aso`.

**Apple facts that reshaped the ask (all read off developer.apple.com / support.apple.com, 2026-09-15):**
- **In-app events show on iPhone and iPad ONLY** — the nomination form's own note. "Waking Up" is the iOS card + the nomination attachment, never a Mac moment.
- **Apple Ads never reach the Mac App Store**; no account exists anywhere in the portfolio. The Mac's front door is editorial or external.
- **Custom Apps cover macOS**, but a record is Public or Private, locked at first approval → a Teams custom app is a second record. Recommendation: not before the pilots (ADR 0005), and fix the policy-key forced-value read first (#350).
- Golden Gate shipped 2026-09-14, Apple Silicon only — our arm64-only build is the story.

**Shipped (PR #354, three commits, local code-quality pass folded before the first push):**
- `ReviewPromptPolicy` (M1K3Inference, pure): two liked answers OR twenty completed turns, AND three whole days, once per marketing version, ever; `isWin(answerFailed:interrupted:)` is the one pinned rule for what counts. `ReviewPromptLedger` (@MainActor @Observable) behind a two-method storage seam (UserDefaults as-is; a dictionary in tests), silent under the screengrab harness (it reroutes stores, NOT UserDefaults.standard). 15 swift-testing cases.
- Wiring: Mac thumbs-up records delight on the transition INTO liked; both text beats and all four voice turn shapes count wins; only ContentView (gated on `\.windowVisible`) and ChatScreen (`scenePhase == .active`) consume, two seconds after the answer. Doors: Help ▸ Rate M1K3…, Settings ▸ General ▸ App Store, iOS Settings ▸ About.
- `macos/tools/asc/` — asc.py (fastlane JSON key first, env pair second), precheck.py, keywords.py scan|apply, promo.py, events.py list|create|update; 21 pytest pins; on CI's pytest line. Proven live read-only: Mac + iOS 1.0.0 PASS; **visionOS FAIL** (no build, no screenshots, GPT/AGI in all eight locales — editable now).
- `fastlane/events/waking-up/` (eight locales within cap by test; PREMIERE; 18 Sep → 16 Oct) — and the discovery that **draft 6811192045 already exists** with art in all eight locales and copy over every cap (en-US 94/50, 302/120), NEW_SEASON, a past start → `events.py update` fixes it in place.
- `fastlane/FEATURING_NOMINATION.md` (paste-ready, Apple's template caps), `docs/GROWTH_GOLDEN_GATE.md` (featuring · event · ratings · Custom Apps · paid/free reach · the D-day calendar · the listing queue). fr-FR/pt-BR subtitles no longer say "Mac" on the shared field. Issues #350 #351 #352.

**Decisions (the why):**
- One pure rule, four call sites: the voice paths bypass `send()` on both platforms, so "only wins count" had to live in the policy, not the beat.
- The ask is consumed where a window can show it, never where the turn ran (MCP / popover) — and the version is marked before the two-second beat on purpose (the system's quota is spent when called).
- Fix the existing draft event rather than create a second: the art is the expensive part and it's already uploaded.
- Custom Apps: a channel for a product that exists; not yet.

**Blockers / gotchas (do NOT rediscover):**
- ★ **ASC writes are classifier-blocked in auto mode** ("Modify Shared Resources") — the keywords PATCH was refused after the read-only scan passed. Stage the exact loop for Kev; don't retry.
- ★ `xcodebuild` from a fresh worktree exits 65 in seconds with NOTHING through `xcbeautify --quiet` — mlx-swift's CudaBuild plugin gate; pass `-skipPackagePluginValidation -skipMacroValidation` (CI already does). Two rounds lost.
- ★ A shared `--scratch-path .build` blocks silently while another session's `swift test` holds it (a MiniLiveEval run) — `pgrep -fl swift-test` first; a private scratch full test build is ~170 s (MLX included) then instant.
- The local code-quality pass caught four real wiring gaps the tests could not (voice bypass, re-tap double count, interrupted-as-win, minimised-window consume) — the #1 lever from the 09-12 process note, paying off again.
- swiftformat's `numberFormatting` wants `86400` not `86_400` (threshold 6 digits); `wrapFunctionBodies` is on.

**Next up:**
- **Kev:** run the two staged commands in #354's body (visionOS keywords; `events.py update` on 6811192045), then submit the event in ASC; paste `FEATURING_NOMINATION.md` on release day; rate the app from his own devices on release day; open an Apple Ads account if the iOS brand-defence test is wanted; the app preview video (the #1 missing asset).
- 1.0.1: build with the prompt; verify-by-launch the sheet after the two-second beat, the Help item, the Settings rows. Then file the 1.1 "App Enhancements" nomination three weeks ahead.
- Queue in `GROWTH_GOLDEN_GATE.md` §8: /support page (#351), metadata_ios (#352), en-US keyword headroom, OG image, non-English release notes.
- **Landing:** CI green on 5c49307e with both passes read in full (the summon: no findings; the auto pass: four cosmetic notes — the honeymoon-restart-on-upgrade trade-off and the doors' bypass are now doc comments, the `daysSinceFirstUse` re-read is carried on the thread, verify-by-launch agreed). This block rides the trivial final head and lands on green CI under the standing deal (`land.sh 354 --passes 0`).

*Signed: Kev + claude-fable-5.1, 2026-09-15 (night), Confidence 0.85 (every Apple constraint read off Apple's own pages the same day; the tooling proven against the live record read-only; the shells built on Xcode 27 GA; 15 + 21 tests green; both bot passes read in full. Honest opens: the sheet is verify-by-launch on 1.0.1; the event and keyword writes are Kev's clicks; whether featuring lands is Apple's call.) Prior: Kev + claude-fable-5.1 (this file, the launch-night block).*
