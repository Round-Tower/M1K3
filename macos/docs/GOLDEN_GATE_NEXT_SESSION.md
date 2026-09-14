# Next session: implement the Golden Gate plan

Paste the block below into a fresh session opened in `~/Development/m1k3`.
It's self-contained. The plan it implements is `macos/docs/GOLDEN_GATE_PLAN.md`
§ Roadmap, together with ADR 0006.

---

```
/goal Implement the Golden Gate plan (macos/docs/GOLDEN_GATE_PLAN.md § Roadmap + ADR 0006) — 1.0.x wins, the toolchain-free half of the PCC rung, and 1.1 if Xcode 27 is GA. M1K3 for comms.

Read first, in this order: macos/docs/GOLDEN_GATE_PLAN.md (the "macOS 27 SDK,
verified" section and § Roadmap), macos/docs/adr/0006-*.md, macos/docs/
PCC_ENTITLEMENT_REQUEST.md, macos/docs/GOLDEN_GATE_RELEASE.md, and
macos/CLAUDE.md § Landing a PR. Don't redo the SDK research. It was verified
on 2026-09-13 (PR #317) against Xcode-beta 27A5194q. Re-grep a swiftinterface
only when a symbol matters, and say which SDK you read. The 26.5 SDK lives in
/Applications/Xcode.app, the 27 SDK in /Applications/Xcode-beta.app.

Step 0: ground truth, reported before any code:
- CI state on master; whether 1.0 shipped (ASC build + TestFlight state by
  build number, not by log).
- Is Xcode 27 GA installed or released? Does App Store Connect accept 27-SDK
  builds? That decides whether contract item 4 runs.
- Has the PCC entitlement been granted? Check the tracking table in
  PCC_ENTITLEMENT_REQUEST.md and ask Kev. Also check whether the
  app.m1k3 provisioning profile carries com.apple.developer.private-cloud-compute.

Contract (one PR each; TDD red-first for every pure policy; every PR lands by
tools/ci/pr_watch.py + land.sh, meaning a local code-quality pass before the
first push and two review passes on the final head):

1. 1.0.x: Mini prewarm with a prompt prefix. `prewarm(promptPrefix:)` is in
   the 26.5 SDK. Pass the recurring prompt head (grounding header + tool
   block).
   EXIT: on an installed Release build on AC / High Power, the ttft log shows a
   lower turn-1 first token than instructions-only prewarm, A/B n>=5 per arm,
   with the power source recorded.
2. 1.0.x: Mini persona trim. Drop FOLLOW-UPS for Mini only (~315 tokens).
   Keep every ABSOLUTE RULE a span of its own (#221: the PersonaLeakGuard /
   SelfWiringQuarantine suites must stay green). Also wire tokenCount into
   GroundingBudgetPolicy.
   EXIT: Mini security x3 on the live path is no worse than the committed
   baseline, and open-chat is no worse. JSON committed under
   macos/docs/evals/.
3. 1.2, the toolchain-free half of the PCC rung (ADR 0006 constraints are
   the spec):
   - pure policy in M1K3LanguageModel: PCC escalation eligibility, what the
     consent sheet lists (grounding opt-in, none by default), the
     quota/failure → local-fallback sentence, and the per-answer label;
   - the escalation control + consent sheet + label in the Mac shell, wired
     through the existing EscalationLadder / ChatEgressConsent;
   - a Teams-style policy switch that forces the rung off.
   The PrivateCloudComputeLanguageModel adapter itself goes behind
   M1K3_FM27. Build it with
   `M1K3_FM27=1 DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
   swift build --target M1K3Agent --scratch-path .build-fm27`.
   EXIT: the ladder never selects .privateCloud with consent off (pinned);
   consent off leaves 1.0 behaviour byte-identical; the UI is verified by
   launch. If the entitlement is granted: one content-free PCC generation
   succeeds on a signed build where the unentitled probe got
   ModelManagerError 1046. If not: mark it verify-owed.
   DO NOT change any "Nothing leaves" copy in this PR. ADR 0006 says the copy
   swap ships with the release that ships the rung. Stage the sweep as its own
   PR (inventory: rg -il 'nothing leaves' --glob '!*.jsonl', 32 files; the
   Brain-at-Home NSLocalNetworkUsageDescription strings stay) and have Kev
   pick the tagline (recommended: "Your AI. Your Mac. Private by design.").
4. 1.1, only if Step 0 says Xcode 27 is GA and ASC accepts it: the
   toolchain bump PR. ci.yml pins Xcode 26 at lines ~70/142/200 on purpose,
   so this is the deliberate bump. M1K3_FM27 becomes #available(macOS 27, *).
   Run the full suite, the gemma-4 native tool-call smoke
   (M1K3_SELFTEST_CHATEVAL=1 _BRAINS=big _KINDS=tool-use), and one
   release-macos.sh --skip-notarize archive, plus a `generic/platform=iOS`
   build (#313: CI is simulator-only). Then, as separate PRs:
   toolCallingMode(.disallowed) for Mini small talk (#102), and typed
   LanguageModelError.rateLimited / .contextSizeExceeded replacing the
   empty-answer heuristic.
   EXIT: master green on Xcode 27 and a Release archive exported.

Out of scope this session: Mini vision, the SpotlightSearchTool/OCRTool
palette A/B, ADR 0001 going live for Lil/Big, and Core AI. Those are 1.1
follow-ups in the plan.

Standing rules: read-first diagnosis; verify-by-launch for anything touching
the AFM/MLX/voice runtime; state power source with every latency number; never
report a merge without state+mergedAt; blocked twice on the same step → stop
and report. End with /debrief.
```

<!-- Signed: Kev + claude-opus-5, 2026-09-14. Written to be run cold; every
     command and path was checked against master 69508f88. Confidence 0.8 (item
     4 depends on Apple's GA timing; the ci.yml line numbers will drift).
     Prior: Unknown -->
