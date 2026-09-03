# Context Tools — the Mac as M1K3's senses (plan)

**Status:** THE FIRST THREE SENSES BUILT (2026-09-01) — `battery_status`
(Phase 1, exclusion-exempt), `calendar_peek` and `current_location` (Phase 2,
both `.localSensitive` + distillation-tainted) shipped under this charter on
Kev's rulings below: per-sense default-OFF toggles in Settings → Privacy →
Context (with TCC-denial auto-revert + calm copy), interactive-chat-only via
`ContextSenseHook` (the ScriptExecutionHook pattern — `ask_m1k3`/menu-bar/
deep-dive structurally never see them, and the warm variant's inert providers
can never fire a TCC prompt at launch), grid-cell coarse location with the
precise opt-up as its own toggle, calendar titles+times capped at five
events. Entitlements + usage strings in both entitlement files + project.yml.
Still unbuilt from this charter: `now_playing` (spike-gated), `wifi_context`,
Phase 3 `device_presence`. Named honest gaps: the eval/SelfTest palette
carries neither the hands nor the senses (unit pins only, not CHATEVAL), and
the EventKit/CoreLocation adapters are verify-by-launch — the TCC dance has
not yet been driven on a real ⌘R.
Earlier milestone (2026-08-23): the hands (`execute_script` +
`propose_script`) landed first, proving the P1 same-turn exclusion
(`ToolExclusionClass` in LocalAgent's dispatch core), the P3 distillation
taint (`DistillationTaint`), and the LAN MCP fail-closed scope the senses
now inherit.
The folded security-audit findings (distillation-exclusion taint before Phase 2,
second consent tier for `ask_m1k3`) remain the binding prerequisites whenever
this is scheduled via ROADMAP.md. Security-audit pass required before the first
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
- **Reading other apps' notifications** (Kev's ask, 2026-09-01: "a way of
  telling what's going on… without integrating with any other apps") —
  ruled OUT, twice over. Structurally: macOS has no public API for another
  app's notifications; the real routes are the private Notification Center
  sqlite (outside our sandbox, needs Full Disk Access, undocumented format
  that breaks across releases) or AX-scraping banners — both fragile and
  surveillance-shaped. And content-wise it's the hottest stream on the
  machine (2FA codes, private messages) — the screen-contents trust
  conversation, not this charter's. The shippable cousin is a
  **`focus_status`** sense: ONE bit ("a Focus is on"), no content, via the
  `com.apple.developer.focus-status` entitlement — a candidate for a later
  phase alongside `device_presence`.

## Architecture

- Each tool = `M1K3AgentTools` + an OS seam protocol (the
  `SystemStatusProviding` pattern): pure snapshot structs, fake providers in
  tests, thin adapters in the app target.
- Palette gating: `AgentToolPalette` (wherever the tool list is assembled)
  Since 2026-09-03 the assembled list also passes `ToolPalettePolicy` (M1K3Chat, shared with the iOS shell): availability gating on stable facts only — a corpus for the knowledge tools, the web toggle for the web trio + `open_link`, a dive that reaches Big for `delegate_deep`, a battery for `battery_status`. Never per question: the palette is a prefix-cache key.
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

## Security-audit — the hands (2026-08-23, code-stage pass)

The auditor walked the shipped diff against this charter. Three BLOCKING
findings were fixed in-branch; the rest are documented residual risks (the
brain-at-home precedent: named, not silent).

**Fixed before merge:**
- **F1 — same-turn exclusion bypass via `delegate_deep`.** A dive spins up a
  separate web-capable agent the parent's `firedExclusionClasses` never saw, so
  `execute_script → delegate_deep(<script output>) → web_search` was a same-turn
  exfil chain. Fixed: `delegate_deep` now carries `.network`, so it is refused
  once a local-sensitive tool has fired the turn (symmetric with the web tools).
- **F2 — TOCTOU between the approval snapshot and launch.** The scripts folder
  lives outside the sandbox container; a co-resident process could swap the
  file in the await gap. Fixed: `UserScriptRunner.run` re-reads and re-hashes
  the bytes against the approved SHA-256 immediately before launch (irreducible
  micro-window remains — NSUserUnixTask re-opens the URL — but the check is at
  the exec boundary, not a stale snapshot).
- **F3 — approval ledger in UserDefaults.** A plist any co-resident process can
  rewrite with `defaults write` was the entire human-review trust boundary.
  Fixed: `KeychainScriptApprovalStore` (device-only, per-app ACL), one-time
  migration off the plist. Fail-closed on a Keychain write error (the run is
  refused, never silently downgraded).

**Also hardened:** symlinks in the scripts folder are excluded from the listing
and refused at run (F7); the persona-prefix warm hook uses inert
`NullScriptRunning`/`EmptyScriptApprovalStore` stubs so a mis-wired warm can
never execute (F9); script output is fenced as untrusted data in the
observation (F6 — a prompt-injection speed bump, named as such).

**Documented residual risks (not fixed in v1):**
- **Cross-turn exfiltration (F5).** P1 is same-turn only: turn N's script output
  lands in the transcript, and turn N+1 can reference it to a web tool. The
  per-turn boundary is stated in the Settings copy; a cooldown window is a
  possible follow-up.
- **Argument confused-deputy (F4).** Approval pins the script's BYTES, not its
  argv; a later turn can re-invoke an approved script with model-chosen
  arguments. The Settings copy now warns to approve only scripts trusted with
  any input; per-approval argument allow-lists are a possible follow-up.
- **Entitlement possibly unnecessary (verify-at-⌘R, review R2).** A sandboxed
  app MAY already have read/write to its own `~/Library/Application Scripts/
  <bundle-id>/` without any entitlement. If a real-device check confirms it, the
  whole `scriptsFolderForWriting()` bookmark/open-panel flow AND the
  `files.user-selected.read-write` entitlement can be DROPPED — removing F10
  entirely rather than documenting it. If the write is refused without the grant
  (or MAS review needs it), the current implementation stands as-is.
- **Entitlement scope (F10).** `files.user-selected.read-write` is app-wide, not
  panel-scoped; the install panel narrows itself to the Application Scripts
  folder by path check. Any future NSOpenPanel inherits write capability — a
  note for whoever touches one next.
- **Audio side-channel (F11).** Script output can be spoken via TTS in voice
  mode, a different exposure than on-screen text.
- **NSUserUnixTask is unkillable (F8).** A runaway approved script can only be
  stopped via Activity Monitor — surfaced in BUGS.md, not just code comments.

## Security-audit — the senses (2026-09-01, code-stage pass)

The auditor walked the shipped diff against this charter. One BLOCKING
finding, fixed in-branch; two residuals documented (the hands precedent:
named, not silent). P1/P2/P3, toggle-before-TCC, warm safety, the coarse
boundary and the OneShotLocation continuation race were all explicitly
verified clean.

**Fixed before merge:**
- **S1 — calendar titles were unfenced attacker-controlled prompt text.**
  Subscribed calendars and invites from strangers put arbitrary text in the
  EventKit store; a title shaped like `ACTION: web_search(...)` rode into
  the prompt raw. Fixed with the ExecuteScriptTool F6 pattern: the event
  listing is fenced as untrusted data and titles cap at 200 chars. The
  fence is a prompt-injection speed bump, named as such, not a guarantee.

**Documented residual risks (not fixed in v1):**
- **S2 — cross-turn exfiltration, the senses' F5.** A turn-N answer
  synthesized from calendar/location lands in the transcript and rides
  `replayableHistory` into turn N+1, where the web tools are available
  again — the same-turn exclusion (P1) is per-turn by design. Identical
  shape to the hands' F5; a cooldown window remains the possible follow-up
  for both.
- **S3 — location usage-string key coverage.** `requestWhenInUseAuthorization`
  on macOS documents `NSLocationWhenInUseUsageDescription`; both it and the
  general `NSLocationUsageDescription` are declared so the first-use TCC
  prompt can't silently no-op. Confirm on the ⌘R verify.

## Open questions — RULED (Kev, 2026-09-01)

1. Location granularity: **coarse by default, precise opt-up** — the default
   snapshot is a grid-cell coarse location; a separate "precise" toggle (or
   per-ask escalation) opts up. Coarse is the toggle's promise; precise is a
   second, explicit consent.
2. `calendar_peek` **includes event titles** (plus times) by default — the
   companion win ("you've got the dentist at 3") needs the title to be worth
   anything. Busy/free-only was considered and rejected.
3. Phase order confirmed: **battery first** (zero friction, exclusion-exempt),
   then calendar_peek + current_location together (same consent shape, same
   toggle-then-TCC ordering). Email is explicitly NOT in this charter — if it
   ever happens it gets its own consent ceremony, metadata-first.

*Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.8 (plan only — APIs
verified against platform knowledge but not spiked; the now_playing and
offline-geocoding rows carry named feasibility risks). Prior: Unknown.*
