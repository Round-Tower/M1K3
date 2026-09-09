# 0005. Relicense forward to FSL-1.1-ALv2; humans stay free, organisations are the paid line

Date: 2026-09-09
Status: ACCEPTED
Deciders: Kev (the call) + claude-fable-5.1 (the read, verified against the git history and the site)

## Context

M1K3 shipped Apache-2.0 from the soft-OSS launch (2026-07-01) with the public
promise "free for humans, forever". Two facts forced a decision on 2026-09-09:

1. **Free-for-humans cannot make Round Tower viable**, even alongside the
   other direct-to-consumer apps. The willingness to pay for privacy-first,
   on-device AI sits with organisations under compliance pressure (schools,
   clinics, firms, public sector), not with individuals.
2. **Apache-2.0 lets anyone productise the work.** Nothing stops a competitor
   shipping a rebranded M1K3, or an "M1K3 for Teams" of their own, on the
   back of the repository. The trademark policy (TRADEMARKS.md, 2026-09-07)
   closes the *App Store clone* risk — a fork under the M1K3 name and icon —
   but a licence, not a mark, governs a competing product under another name.

Three constraints shaped the answer, each checked before deciding:

- **Copyright is undivided.** `git shortlog -sne --all`: 1,319 commits by
  Kevin Murphy, 11 by Claude (output belongs to the user under Anthropic's
  terms), 50 by the repo-visualizer bot (generated diagrams). All 200 pull
  requests are the author's. No contributor consent is needed to relicense.
- **Relicensing is forward-only.** Every revision published under Apache-2.0
  stays Apache-2.0 for everyone who holds it (NOTICE already says this of the
  brand-asset carve-out; the same law applies to the code). The August clone
  counts (~2,800 in 14 days) already hold a perpetual grant. A licence change
  protects the next two years of work, not the last two.
- **Auditability is load-bearing.** The privacy page closes with "Don't take
  this page's word for it — take the source's." The privacy claim is
  verifiable *because* the source is public. A private repository would turn
  "nothing leaves" into "trust me", kill the MurphySig showcase (public signed
  code is the demo), and remove the MCP/GEO pages' foundation.

## Decision

1. **From this commit onward, M1K3's own code and docs are licensed under the
   Functional Source License, Version 1.1, ALv2 Future License
   (`FSL-1.1-ALv2`).** Anyone may read, build, modify and use the Software for
   any purpose that is not a *Competing Use* — including personal use,
   internal use, non-commercial education and research. Making the Software
   (or a substantially similar product) available to others commercially, or
   substituting for a product Round Tower offers using it, is not permitted.
   Each version converts to Apache-2.0 two years after it is made available.
2. **The repository stays public.** Source-available, not closed. The privacy
   claim keeps its checklist; the provenance stays on the record.
3. **"Free for humans, forever" stands, literally.** Personal use is a
   Permitted Purpose under the FSL, at no charge, with no account and no
   telemetry — unchanged. The site stops saying "open source" (the FSL is not
   an OSI licence and we will not pretend otherwise) and says
   "source-available" instead.
4. **Organisations are the paid line: M1K3 for Teams.** The shape that is
   coherent with "nothing leaves" is on-premises — the organisation's own
   Apple Silicon hardware serving brains, institutional memory and a tuned
   persona to its people over its own network, under its own domain. Not a
   hosted per-tenant cloud. The seed exists (Brain at Home: pairing, TLS-PSK,
   scoped MCP) and is single-user today; the multi-user, admin, identity and
   audit surface is *not built yet*, deliberately — pilots are sold before the
   product is built.
5. **Contributions become invitation-only under a CLA** (`CLA.md`):
   Apache-2.0 inbound, FSL outbound, so the future grant can be honoured and a
   later licence change never needs a contributor hunt. The project has had no
   external contributor in 200 PRs; the cost is nil, the option is preserved.
6. **The App Store clone defence is unchanged and now more urgent:** the
   trademark filing (IPOI, classes 9 and 42, per the 2026-09-07 ruling) is the
   real lever against someone shipping "M1K3" that is not ours.

## Consequences

- Earlier revisions (through the parent of the relicensing commit) remain
  Apache-2.0; NOTICE records the boundary. Do not claim otherwise anywhere.
- Every surface that said "open source (Apache-2.0)" now says
  "source-available (FSL-1.1-ALv2)": LICENSE, NOTICE, README, CONTRIBUTING,
  TRADEMARKS, `site/llms.txt`, every page on m1k3.app (including the JSON-LD
  `license` URL and the FAQ answers — schema must match visible copy).
- The comparison pages must stay honest: Ollama and MLX are open source (MIT);
  M1K3 is not, and the tables say so in plain words.
- Optional consumer purchases (new companions, a new voice, cosmetic
  features) remain possible and are explicitly *not* the business — never
  gate a privacy or core feature behind them.
- Model weights keep their own licences (Apache-2.0 for Qwen/Gemma, LFM Open
  License for LFM2.5); the weights-archive tooling under `macos/tools/weights`
  still ships the Apache text for the weights it mirrors. That is about the
  models, not about M1K3.
- Show HN is framed as source-available from the first sentence. Relicensing
  after a launch is the story to avoid; launching this way is the ordinary one.
- The FSL's own Trademarks clause now backs TRADEMARKS.md directly (no reliance
  on Apache §6 for revisions from here on).

## Alternatives considered

- **Private repository with vetted access.** Rejected: does not touch existing
  clones, destroys auditability and the provenance showcase, and kills the
  launch. Gating who may *contribute* is separable from gating who may *read*,
  and only the first is useful here.
- **AGPL-3.0.** Rejected: it permits commercial competing use as long as the
  competitor publishes their changes — the opposite of the goal.
- **BSL 1.1.** Viable; a four-year change date and an "Additional Use Grant"
  to draft. FSL is shorter, two-year, and its Permitted Purposes already say
  what we mean. Chosen for a solo author who wants the licence readable.
- **Open core (Apache core + proprietary Teams).** The Teams layer will be
  proprietary regardless; leaving the core Apache keeps the "someone ships our
  app under another name" hole open. FSL closes it without going private.

*Signed: Kev + claude-fable-5.1, 2026-09-09, Confidence 0.85 (copyright
ownership read off the git history, not assumed; the forward-only nature of
relicensing is settled law; the B2B shape is Kev's call and the market read
is judgment, untested — three pilots decide it. Prior: Unknown — new file.)*
