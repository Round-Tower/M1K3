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

## Addendum — the pulse reads odd (2026-08-30)

Six live days of pulses, read back off the banner stack and the Heartbeat
destination (Kev: *"reading kinda odd at times"*). Seven named failures. Each
one has a root cause in code, so none of this is "tune the prompt and hope."

### 1. The chat line loses its subject

`HeartbeatComposer.chatLine` emits a passive with no actor —
`Conversations touched: 'The Ballmer Legacy'.` The model filled the gap two
ways across the week, both wrong:

- **as M1K3's own work** — *"I've been processing 'The Ballmer Legacy'"*.
  M1K3 processed nothing; Kev had a conversation.
- **as a report filed on Kev** — *"though I note you've been seeking out
  authentic Irish coffee in Cork"*. Correct facts, surveillance register.
  This is the one that actually stings on a product whose pitch is that
  nothing leaves.

**Fix (composer):** name the actor, make it mutual — `We talked about 'X'.`
A resident says *we*; a monitor says *you were observed*.

### 2. The brain becomes a housemate

`brainLine` emits `Big is resident.` and nothing anywhere says what Big *is*.
Three consecutive pulses anthropomorphised it: *"keeping Big company on the
shelf"* · *"Big is still here with us"* · *"with Big still hanging around the
workspace."* Predictable — the render is a bare generate with no persona seed
(deliberately, per #98), so an unexplained proper noun gets the friendliest
available reading.

**Fix (composer):** `Running on Big, the larger brain.`
**Fix (prompt):** the brain is what M1K3 thinks *with*, never a companion.

### 3. "From the shelf" leaks its metaphor

The fun-fact prefix is the only figurative phrase in the whole digest, and
it is exactly the phrase the model borrowed for Big ("on the shelf"). A
metaphor in the digest is a metaphor the retelling will reuse somewhere else.

It is also a **principle 3 violation** we shipped without noticing: the closed
noun list spends `documents` on the corpus. `shelf` is a second noun for the
same thing.

**Fix:** `From your documents: … [title]`.

### 4. Ambience drives the sentences

Device state is always present and never interesting. Activity sections are
frequently absent. So the digest's *stable* half outweighs its *newsworthy*
half, every pulse opens on thermals and uptime, and the model is left making
something of a disk number — *"there's plenty of disk space left to occupy."*

**Fix (prompt):** split the digest into **NEWS** (memory · chat · visiting
agents) and **AMBIENT** (machine · brain), and instruct: lead with the news;
touch ambient only when it changed, or when there is no news at all.

### 5. Three days, one sentence — the structural one

> 08-28 · *"I'm keeping things steady on this end; the machine is running cool
> and I've been up for three days…"*
> 08-29 · *"…the machine is running cool and we've been up for four days…"*
> 08-30 · *"I'm keeping things steady on this end…"*

Not a style problem. `earlierPulsesToday` comes from
`HeartbeatStore.since(startOfDay)` — it **resets at midnight** — and
`HeartbeatEmptyRule` suppresses quiet windows, so on a quiet day the only
pulse that fires is the day's *first*, which by construction sees an empty
arc and a near-identical digest. "Continue the day's thread, don't repeat it"
has had nothing to continue, every single day.

**Two fixes, both cheap:**

- **Don't ask the model when there is no news.** Gate the render on
  `context.hasActivity`; an ambience-only pulse ships the digest. This kills
  the repetition at its source *and* saves a decode — the pulse that reads
  worst is also the one we were paying for.
- **Cross the midnight boundary for anti-repetition material.** Add
  `HeartbeatStore.recent(limit:)` beside `since(_:)`, feed the last three
  pulses regardless of day, and say plainly: don't open the way these opened.

### 6. Digit laundering through the day-arc — a real bug

`NarrativeGuard` admits digits found in earlier **narratives** as well as the
digest (the pulse-2 fix, 2026-08-06). That closed a false reject and opened a
laundering path: **a digit fabricated in pulse 1 is permanently allowed for
every later pulse that day.** The guard's whole job is the one thing it then
stops doing.

*"You were busy exploring global events and local foodies on the 19th"* — with
no date anywhere in that pulse's material — is what the hole looks like from
outside.

**Fix:** admit digits from earlier **digests** only. The digests are already
in hand — `HeartbeatStore.since` returns whole `HeartbeatEntry` rows and the
engine maps them to `displayText`, discarding `digest`. So it is a call-site
change plus renaming the guard's parameter `earlierPulses` → `earlierDigests`.
The day-arc prompt keeps using the narratives; only the *evidence set* narrows.

### 7. "I've stayed busy while you were away"

No work was done. **Prompt rule:** report what happened; never claim work.

### One new verdict worth having

`NarrativeGuard` already carries a Mac-noun tripwire — a register check, not a
truth check. Add a cheap sibling: **`.repeatsOpener`** — reject when the first
six words match a recent pulse's first six. Pure, deterministic, trivially
TDD'd, and the fallback asymmetry still holds: a false reject costs style
because the digest ships.

### The fixes by layer

| Layer | Change | Shape |
|---|---|---|
| `HeartbeatComposer` | `We talked about 'X'` · `Running on Big, the larger brain` · `From your documents:` · NEWS/AMBIENT sectioning | pure, test-pinned |
| `HeartbeatPrompt` | lead-with-news rule · don't personify the brain · don't claim work · don't editorialise numbers · don't open like these | string contract, test-pinned |
| `NarrativeGuard` | `earlierPulses` → `earlierDigests` (closes laundering) · new `.repeatsOpener` verdict | pure, TDD red-first |
| `HeartbeatStore` | `recent(limit:)` beside `since(_:)` | GRDB, round-trip test |
| `AppEnvironment+Heartbeat` | render gated on `hasActivity` · pass digests to the guard, narratives to the prompt | app wiring, ⌘R |

Ordering note: fix 6 is the only one that is a *defect* rather than a matter of
taste. It ships first and alone, so its test tells the truth about one change.

## Addendum — pulse tags (2026-08-30)

Kev's ask: *"maybe add tags / knowledge graph stuff?"* Ruling taken the same
day: **structural only.**

### The rule

**A tag describes the shape of a window, never its content.** Same rule as the
CRT rain, for the same reason — and here it binds harder, because a tag is a
*persistent, filterable index*, and an index over conversation and memory
titles is precisely the "history of what you talked about" that the
OFF-by-default stance in §"The double-bind" exists to avoid. Topic tags were
considered and declined: they would have made the pulse store's privacy answer
worse than the pulse store's privacy question.

### The vocabulary (closed, and versioned like the noun list)

- `pulse:first-today` · `pulse:quiet` · `pulse:active`
- `machine:cool` · `machine:warm` · `machine:hot` · `machine:low-power`
- `power:charging` · `power:battery`
- `memory:learned` · `memory:corrected`
- `chat:touched`
- `agent:visited`, plus `agent:<client>` — the MCP client's self-reported
  name (Claude, Cursor). Client identity is not user content, and the
  timeline's visit headers already show it.
- `brain:big` · `brain:lil` · `brain:mini` · `told-by:digest` (Mini can be
  the resident too — added at implementation, same shape rule)
- `hold:quiet-hours` · `hold:warm` · `hold:busy` · `hold:quiet-window`
  (on the hold record, not on a pulse — a hold is the absence of one)

**Explicitly not tags:** conversation titles · memory titles or keywords drawn
from them · fun-fact source titles · tool arguments · any exact count.

**Counts are banded, never exact.** `memory:learned` says a fact was learned;
*how many* stays in the digest, which is capped at a week and cleared with one
tap. A tag carrying `17` is a durable data point about somebody's week.

### Where it lives

`pulse_tags(pulse_id, tag)` in `heartbeat.sqlite`, foreign key
`ON DELETE CASCADE`. The store's "nothing survives Clear" guarantee must not
acquire an exception on its first extension — the cap trim and Clear take the
tags with them or the schema is wrong.

### Who composes them

`HeartbeatComposer.tags(from: HeartbeatContext) -> Set<PulseTag>` — pure,
deterministic, the #102 guard extended verbatim. **The model never sees a tag
and never produces one.** Tags are facts, and facts come from code.

### What it buys

Filter chips over the interaction timeline: *only pulses where an agent
visited* · *only pulses where the machine ran hot* · *only the days something
was learned*. That is the honest version of the knowledge-graph ask — the pulse
store gets its own small graph (pulse ⟶ tag ⟶ pulse) without adding one node
to the memory graph.

### And deliberately NOT the memory graph

Writing pulses as `MemoryStore` nodes would undo store safeguard #6. Pulses are
kept out of the chat transcript *precisely* so `MemoryDistillationCoordinator`
can never mint a permanent fact from one; nodes would hand it a second door
into the same room. If a pulse ever needs to point at a memory it points **one
way** — a stored memory ID as a read-only reference, so the timeline can link
out to the constellation. No edge. No node. No new distillation surface.

### Verify-owed

The seven fixes above are ⌘R-owed as a set: toggle the heartbeat on, live with
it a few days, and read the pulses back cold. `swift test` will prove the
composer strings, the guard verdicts, the store round-trip and the tag
function; it cannot prove that a pulse reads well, and that was the whole
complaint.

*Signed: Kev + claude-opus-5, 2026-08-30, Confidence 0.85 (root causes are
read directly off the shipped code and six days of live pulses, and each fix
lands in a pure, testable layer; the digit-laundering hole is the one claim I'd
stake a bug report on. What remains judgement is whether the reworded composer
lines actually read better in the model's mouth — gemma is prompt-fragile and
that is an A/B, not an assertion). Prior: v1 SHIPPED 2026-08-06 + the honest-
holds addendum 2026-08-08.*
