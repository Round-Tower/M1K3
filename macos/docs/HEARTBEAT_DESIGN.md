# The Heartbeat — design record

**Status: v1 SHIPPED (2026-08-06) — default OFF pending Kev's ruling on the
double-bind below.** Kev's ask, verbatim intent: *"pulling in all context
available, summarizing it every couple of hours, giving status updates …
I need activity log heartbeat"*, plus a live mid-design steer: *"it should
read as a narrative or story … I'm not keen on the Apple model for this —
use the best model, or the 4-bit, depending on the actual thermals of the
device — the most capable model at the time. Good narrative across the day,
across the heartbeat."*

## What v1 is

Every ~2 hours (pure `HeartbeatSchedulePolicy`, checked by a 10-minute
coarse loop in `AppEnvironment+Heartbeat.swift`), M1K3 gathers the Tier-A
context the app already holds, composes a **deterministic digest**
(`HeartbeatComposer` — the #102 guard: facts come from code, never from the
model), asks the **resident MLX brain** to retell it as a short narrative of
the day, vets the retelling with `NarrativeGuard`, and records the pulse in
its own capped store. Since 2026-08-19 the canonical surface is the
**Heartbeat sidebar destination** (`HeartbeatScreen`) — an interaction
timeline where pulses interleave with visiting-agent MCP calls foldered into
per-client visits (`InteractionTimeline`, pure). The menu-bar popover line
and the idle-card teaser are the ambient surfaces; Settings keeps consent.
Principle 6 honoured: one canonical + ambient, zero elsewhere. (The
summoned Heartbeat Window was retired with the promotion.)

**Tier-A sources (no new consent):** thermal/low-power + battery/disk/uptime
(`LiveSystemStatusProvider`) · memories learned since the last pulse
(`MemoryStore.memoriesCreated(since:)`, SQL-side, superseded rows excluded) ·
conversation titles touched (`conversationSummaries()`) · visiting-agent
calls (`ConversationLogStore.activity(since:)` — read ONLY when the Agent
Log toggle is already on) · brain status · a fun fact from the corpus
(deterministic day-seeded pick, cited with its source title).

**The model rule (Kev's):** the most capable teller the moment allows —
Big/Lil when the MLX slot is `.ready`, the machine is cool
(`backgroundWorkAllowed()`), nothing is busy, and the battery is either
charging or ≥50%. Otherwise the digest ships as-is (`renderedBy: "digest"`).
**Mini/AFM is deliberately not in the chain** — and #102 measured why: an
open-ended "say something interesting" turn on Mini invented a weather
forecast. The render is a bare `swappableMLX.generate` — no tools, no
retrieval, no persona seed (safe per the #98 lesson: identity-per-turn only
fights a persona when one is seeded; a bare generate has none).

**Day-arc:** each render receives the day's earlier pulses (oldest first)
from `HeartbeatStore.since(startOfDay)` and is told to continue the thread,
not repeat it — "across the day, across the heartbeat."

## The challenger pass — what it changed, what Kev's ask overrode

A full `challenger` run attacked the draft. Folded as shipped:

1. **Empty pulses suppressed** (`HeartbeatEmptyRule`): a quiet window
   records nothing — except the day's first pulse, which always fires (fun
   fact and all). "Nothing happened" six times a day kills the surface.
2. **Watermark clock-skew clamp**: a future `lastPulse` (NTP correction,
   timezone flight) reads as due-now, never a wedge.
3. **SQL-side windows** on both stores — never fetch-then-partition (the
   PR #94 truncation lesson), and never page PII-bearing response text into
   memory to compute an integer.
4. **Battery joins the gate** — `backgroundWorkAllowed()` reads thermal +
   low-power only; the render additionally requires charging or ≥50%.
5. **No main-thread IO** — every store read/write runs detached (the
   ConstellationWindow rule; the AgentLogWindow's sync read is the
   anti-pattern).
6. **Store safeguards**: cap 84 (12/day × 7 — a rolling week, not an
   archive) · one-tap Clear (which also resets the watermark — nothing
   survives) · `isExcludedFromBackup` on the DB file · excluded from
   diagnostics · **never enters the chat transcript**, so
   `MemoryDistillationCoordinator` (which only reads chat turns) can never
   mint permanent facts from a pulse. That structural exclusion replaces a
   provenance-taint system that would otherwise rot untested.
7. **MCP-lane honesty**: `MenuBarAsk.isBusy`-style predicates don't see an
   in-flight `ask_m1k3`. The render shares the ONE `swappableMLX` instance,
   so a collision serializes on the model container rather than starting a
   second decode loop (the 07-25 dual-MLX ruling) — a queued render, not a
   stalled machine.

Challenger positions **overridden by Kev's explicit ask**, recorded so they
aren't re-litigated blind: it argued for compose-on-look (no scheduler, no
store, read-receipt only) and no model in the loop. Kev asked for scheduled
pulses, a log, and the narrative told by the best available brain — those
ship, with the safeguards above.

## The double-bind — Kev's ruling wanted

**"Activity log" vs "prove nothing was kept."** A pulse history is a
presence-and-topic timeline (chat titles are derived from user content) in
the app whose pitch is provable data minimalism. v1 resolves it
conservatively: the feature is **OFF by default** (a consent surface, like
the Agent Log), capped at a week, and Clear wipes everything. Kev's call:
flip the default, shorten the cap, or drop the history for a latest-only
pulse. Also his: the noun — doctrine's closed list spends "heartbeat" on
the CRT band (this doc treats the band as the visual heartbeat and the
pulse as the narrative one, deliberately the same metaphor).

## Deferred (explicitly, with their gates)

- **Email, location, calendar, BLE presence** — blocked on
  CONTEXT_TOOLS_PLAN's P3 distillation-taint prerequisite + per-source
  consent + its security-audit gate. The plan is PARKED; nothing here
  bypasses it.
- **Web-search "local news"** — only ever behind the existing web toggle,
  and structurally P1-aware (sensitive context and web tools never share a
  turn). Not in v1.
- **Notifications** — `TurnNotifier` exists (generic-body rule, own opt-in
  key); earn it with evidence the pulse is read, per challenger.
- **supersededCount** in MemoryActivity — needs a `superseded_at` column;
  gathered as 0 until then.
- **Voice**: a pulse `/narrate`-spoken aloud, or read on voice-mode entry.

## Notification passing — scoping (Kev, 2026-08-06 evening: "notification
## passing is the way we're actually gonna make this work … local Bonjour
## + MCP")

The idea: devices summarize their incoming notifications into the Mac
resident's heartbeat — "what's going on there" across the household — over
the local network. Honest platform picture, per surface:

| Surface | Can it read other apps' notifications? | Path |
|---|---|---|
| **Android (間 AI, `app/`)** | **YES** — `NotificationListenerService` is a real, user-grantable API | The strongest opening move. The KMP app listens, digests LOCALLY (counts + app names + optional headline, per the digest rules), and passes the digest to the Mac over local MCP. |
| **macOS (M1K3 itself)** | Only its own. The Notification Center store (`db2/db`) is readable ONLY with Full Disk Access — impossible in the MAS sandbox, heavy-consent for the DMG build | Park. If ever: DMG-only, own consent tier, security-audit first. |
| **iOS/visionOS shell** | **NO** — there is no notification-listener API on iOS, full stop | The iPhone contributes its OWN app's signals only (delivered-notification count via `UNUserNotificationCenter`, plus app-side events). Not a general listener. |

Transport: **Bonjour-discovered local MCP** — the brain-at-home (§8)
direction. The Mac's in-app MCP server already exists; the missing pieces
are (a) advertising it over Bonjour on the LAN, (b) a device-pairing
consent tier (allowlist, the BLE `device_presence` pattern from
CONTEXT_TOOLS_PLAN — never promiscuous), and (c) a `heartbeat_ingest`
MCP tool: a device POSTs a small typed digest (app names, counts, an
optional headline line — never message bodies), which lands as a new
`HeartbeatContext` section on the next pulse.

Sequencing gate: the ingest tool is INBOUND user-device data — it needs
the P2 second-consent-tier work (scoped tool palettes) plus a
security-audit pass before code, same as every context tool. And the
digest rules extend: notification content is the most private stream in
the house; app names + counts are the ceiling until Kev rules otherwise.

## Seed — the CRT data-rain (Kev, 2026-08-06 late, do not lose)

"Anytime anything happens… portray it in the background against the CRT —
anytime an agent calls, we stream upwards the actual data being passed
between the systems, Matrix-wise… what's going on in the background as
M1K3 is working away… or as M1K3 is generating code and eventually spits
out an artifact, as opposed to presently: recall, chest."

The CRT face becomes a live instrument: visiting-agent traffic, tool
calls, generation — rendered as glyph-rain rising through the phosphor
while M1K3 works, and artifacts MATERIALIZING out of the stream instead
of appearing in a panel. Evidence of residency, animated.

Design stakes named early:
- **Derived glyphs, never literal payload text.** The rain must be a
  visual HASH of the traffic (density/speed/color from call rate, tool
  kind, direction), not readable data — a screen-share or a screenshot
  must not leak what a visiting agent asked. Same rule as the heartbeat
  digest: shape, not content.
- Seams that already exist: `MCPCallLogSink` (per-call moments),
  the agent loop's onEvent stream (thoughts/actions), the phosphor
  shader arc (#45/#46/#48/#49) for the surface, reduce-motion + battery
  gates inherited from ChatBackdropTreatment.
- Belongs to the companion/phosphor thread, not the heartbeat store —
  the rain is ephemeral render state, nothing persists.

Extension (Kev, 2026-08-07 small hours): **the rain shows M1K3's own
THINKING too — transparency as the aesthetic.** Two honesty tiers, one
hard line: M1K3's own work renders REAL fragments (retrieval doc titles,
tool names, agent-loop thought snippets, the token stream) — your machine
thinking about your stuff, literal on purpose, the anti-black-box; while
visiting-agent traffic stays derived glyphs only (a screen-share must
never leak a visitor's payload). v1 needs no Metal: TimelineView+Canvas
glyph-rain behind the voice-mode face, density ∝ activity, feeding off
the agent onEvent stream + responder stages + MCPCallLogSink — a
subscriber, not a system. Voice mode first (the face's theatre); chat
backdrop is a later taste call.

## Addendum — honest holds (2026-08-08)

The first live days surfaced a design gap: the schedule's skips are logged
but invisible in the UI, so a held heartbeat is indistinguishable from a
broken one (observed: 47 quiet-hour + 3 thermal skips in one night while the
surfaces showed an ageing "8 hours ago"). `HeartbeatHoldLine` (pure,
`M1K3Heartbeat`) now resolves the last hold — quiet hours, warm machine,
busy machine, or the empty rule's quiet-window withhold — into one short
line; the engine records `heartbeatLastHold` on every non-tooSoon skip and
clears it on a recorded pulse. Surfaces: the main-screen idle card and the
Heartbeat destination header. Holds age out after 30 minutes (a hold that stopped
refreshing means the loop itself is asleep — an explanation would be a
guess). Surface census since the 2026-08-19 promotion: the Heartbeat
sidebar destination (canonical — `HeartbeatScreen`, the interaction
timeline) + the main-screen idle-card teaser and menu-bar line (ambient);
Settings keeps only consent. The summoned window is retired.

## Verify-owed (named)

The loop, the render quality on Big/Lil (gemma is prompt-fragile — A/B the
narrative before the toggle defaults on), the battery/thermal gates' feel,
and the popover line are **⌘R verify-owed** — `swift test` proves the
policies, not the pulse. Suggested first run: toggle on in Settings, drop
the interval… actually don't — just leave it running an afternoon.

*Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.85 (policies,
composer, guard, store all TDD-pinned red-first; app wiring compiles and
mirrors named house patterns; the live pulse is verify-owed as stated).
Prior: none (new doc).*
