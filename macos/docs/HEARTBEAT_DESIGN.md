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
its own capped store. The menu-bar popover carries the latest pulse line
(ambient); Settings → M1K3 → Heartbeat is the canonical surface (toggle,
recent pulses, Clear). Principle 6 honoured: those two surfaces, zero
elsewhere. No notifications in v1.

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
