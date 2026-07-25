# Context Tools — the Mac as M1K3's senses (plan)

**Status:** PLAN — no code yet. Security-audit pass required before the first
tool lands (the brain-at-home precedent: auditor walks the design, blocking
findings fold into this doc, then code).

Kev's ask (2026-07-25, voice note): *"it has full access to the Mac — it could
pull in health data, WiFi data, BLE, battery health, battery life, current
location. Lots of context we can pull from in a privacy-focused manner."*

## The shape: senses, not surveillance

Every context tool follows the same four rules. These are the product, not
implementation details:

1. **Per-tool consent toggle** in Settings → Privacy (the web-search toggle
   precedent: the promise lives in one pane). Default **OFF**, every one.
   A toggle that's off means the tool is **absent from the palette** — the
   model can't see it, ask for it, or be prompt-injected into wanting it
   (the #28 self-query-gate pattern: withhold, don't refuse).
2. **Summaries, not streams.** Tools return a compact snapshot ("battery 84%,
   discharging, ~3h left"), never raw feeds, histories, or logs. No context
   tool persists anything to the corpus on its own — if the user wants a fact
   remembered, the existing `remember` flow is the door.
3. **Local only.** Context snapshots are grounding for the local brain. They
   are never eligible for web-tool interpolation (query strings) — pinned by
   test, same class as the persona-clause "never leak digits" pins (#31).
4. **TCC is the floor, not the ceiling.** Where macOS gates the data (location,
   Bluetooth, calendar), the OS prompt happens ONLY after the in-app toggle is
   on — flipping the toggle explains why first (calm-invite copy), then the
   system dialog fires on first use. Two consents, ordered.

## The tools

### Phase 1 — no TCC, pure wins

| Tool | Source | Returns | Notes |
|---|---|---|---|
| `battery_status` | IOKit (`IOPSCopyPowerSourcesInfo`) + `pmset` | charge %, charging/discharging, time estimate, cycle count, condition | Extends the existing `SystemStatusTool`/`SystemStatusProviding` seam — same file family, same fake-able OS seam, TDD against fixtures. Pairs with Cool Head: M1K3 can *explain* why it deferred work. |
| `now_playing` | MediaRemote is private API — **use MPNowPlayingInfoCenter only if public surface suffices; otherwise CUT** | current track/app | Honest risk: may be infeasible without private API. Spike first; cut without ceremony if it needs anything unsandboxed. |

### Phase 2 — TCC-gated singles

| Tool | Source | TCC | Returns |
|---|---|---|---|
| `current_location` | CoreLocation | Location (when-in-use) | Coarse by default ("Ardmore, Ireland" — reverse-geocoded **locally via CLGeocoder? NO — CLGeocoder is a network service.** Use offline coarse rounding + the existing corpus; a named open question below). |
| `calendar_peek` | EventKit | Calendars | Next N events today/tomorrow, titles + times only. The companion win: "you've got the dentist at 3." |
| `wifi_context` | CoreWLAN | Location (SSID requires it on modern macOS) | SSID, band, RSSI as a quality word ("solid", "flaky"). Presence inference ("home network") stays user-side — the tool reports, it doesn't conclude. |

### Phase 3 — scoped presence (the reframed BLE ask)

**Not** BLE sniffing. Promiscuous advertisement scanning logs *other people's*
devices — surveillance-shaped, off-mission, and reads as dual-use in a public
repo. The version that ships:

- `device_presence` — CoreBluetooth scan filtered to a **user-registered
  allowlist** (their watch, phone, tags), returning near/far/absent per
  registered device. Registration UI = explicit pairing-style pick, stored
  local. Anything not allowlisted is invisible by construction (the scan
  delegate drops non-matching identifiers before they touch app state).

### Explicitly out (and why, so it stays decided)

- **Health data on macOS** — there is no HealthKit on the Mac. The honest
  path is the M1K3iOS shell reading HealthKit (consented) and shipping
  summaries over the future brain-at-home channel (SPEC.md, Phase D-adjacent),
  or a Health-app XML export ingested like any document today. Tracked on the
  mobile roadmap, not here.
- **BLE promiscuous scan / third-party device logging** — see Phase 3.
- **Screen contents / screen time** — a different trust conversation entirely;
  not in this plan.

## Architecture

- Each tool = `M1K3AgentTools` + an OS seam protocol (the
  `SystemStatusProviding` pattern): pure snapshot structs, fake providers in
  tests, thin adapters in the app target.
- Palette gating: `AgentToolPalette` (wherever the tool list is assembled)
  consults the consent flags — same withhold mechanism as the self-query gate.
- MCP exposure: context tools are **NOT auto-exposed over MCP.** A visiting
  agent asking M1K3 where Kev is happens through `ask_m1k3` (the local brain
  decides, grounded in its own rules), never via a raw
  `current_location` MCP tool. Revisit only with its own consent story.

## Security-audit findings — FOLDED (2026-07-25, design-stage pass)

The auditor verified the four rules against the live code and found three of
the plan's original claims weren't yet backed by mechanism. These are now
**prerequisites**, not aspirations:

- **P1 (was rule 3, "local only") — same-turn palette exclusion, in code.**
  "Context data never reaches web tools" cannot be a persona rule (prompt-
  injectable) or a static pin (#31-style pins cover prompt construction, not
  generative behaviour). Enforcement: once a context tool fires in a turn,
  `web_search`/`fetch_page`/`open_link` are WITHHELD for the rest of that
  turn — and vice versa (the SelfQueryGate withhold pattern, applied to
  tool-use-so-far). Sensitive tools (`current_location`, `calendar_peek`,
  `device_presence`) get the exclusion; `battery_status` and wifi quality
  words are exempt so "check my battery and search for a cable" still works.
  Input-shape scanning on web tools is belt-not-buckle defence, named as such.
- **P2 (was "not exposed over MCP") — palette scope split + second consent
  tier.** `ask_m1k3` builds its responder from the SAME `interactiveAgentTools`
  factory as chat (the WebSearchTool precedent proves one toggle = one palette
  = reachable by any loopback MCP client). Fix: the factory takes a scope
  (`.interactiveChat` vs `.mcpAsk`); context tools join `.mcpAsk` only behind
  a SECOND explicit toggle ("also usable by visiting agents"), never inherited
  from the chat toggle.
- **P3 (new, the biggest gap) — distillation exclusion BEFORE Phase 2.**
  Rolling memory distillation runs over persisted assistant text with no
  provenance: an answer that mentions your location becomes a permanent,
  retrievable memory-graph fact that outlives the toggle. Fix: a
  context-tainted turn marker threaded from the responder into `ChatTurn`;
  `MemoryDistillationCoordinator` skips tainted turns (the `quarantined`
  pattern, applied at the transcript→distiller boundary). **Phase 2 and 3 are
  blocked on P3. Phase 1 (battery) is not.**
- Also folded: TCC-denial state must auto-revert the in-app toggle with calm
  copy (no per-turn "permission denied" loops); `device_presence` gets named
  never-do invariants (never log raw scan results at ANY level, never expose
  nearby-device counts, toggle-off deallocates the CBCentralManager — no
  suspended-delegate backlog); context tools reach EVERY palette (chat, MCP,
  SelfTest, eval) through the same consent read, no harness shortcut ever;
  repeated-snapshot call-rate floor per conversation (a sequence of snapshots
  is a history); prefer grid-cell coarse location over gazetteer place names
  (more private, no bundled-data supply chain).

## Open questions (Kev's calls)

1. Location granularity: town-level default with a "precise" opt-up, or
   precise-only-when-asked?
2. Does `calendar_peek` include event titles by default, or busy/free only?
3. Phase order — battery first (zero friction) is my recommendation; anything
   you want promoted?

*Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.8 (plan only — APIs
verified against platform knowledge but not spiked; the now_playing and
offline-geocoding rows carry named feasibility risks). Prior: Unknown.*
