# Brain-at-Home — spec (scratch draft v1)

> iPhone in your pocket, brain on your Mac. The iOS shell discovers your Mac on
> the home network, pairs once, and streams from the Mac's MLX brain — so the
> phone gets Big-tier answers while everything stays inside your walls.
>
> Status: SCRATCH SPEC — no production code. Security-auditor findings folded
> (see §9). Prior art: gemba's BonjourBrowser/Advertiser; seam scout 2026-07-14.

## 1. Product shape

- Phone Settings/brain picker gains a **"Home Mac"** tier: appears when a
  paired Mac is reachable, streams generation from it; the phone falls back to
  its own local brains (Mini/Lil) automatically when away. Local-first, always.
- Mac gets a **"Serve my brain to my devices"** toggle in the Privacy pane —
  default OFF (nil is a NO). ON = advertise + listen; OFF = listener down,
  advertisement gone, instantly.
- Pairing is a one-time ceremony: the Mac shows a QR; the phone scans it.
  Paired devices are listed in the Mac's Privacy pane with one-tap revoke.

## 2. The decisive scoping call: inference, not MCP

The phone uses the Mac as an **InferenceProvider** (prompt in → token stream
out), NOT as an MCP client. Rationale:

- `LocalMCPHTTPServer` is **loopback-pinned at the OS level**
  (`requiredLocalEndpoint = .loopback`, LocalMCPHTTPServer.swift:68) as the
  documented privacy story ("no LAN exposure, ever"). That pin is UNTOUCHED by
  this feature — widening the whole tool surface (search_knowledge,
  get_document, remember, forget…) to the LAN multiplies the attack surface
  for no v1 value.
- The phone already runs its own full agent loop, RAG, and memory locally
  (AppCore composes LocalAgent + HashingEmbeddingService + its own stores).
  What it lacks is a strong BRAIN. So the brain travels; the memories don't.
- Consequence, stated honestly: **phone corpus ≠ Mac corpus** in v1. "Ask my
  Mac's knowledge from my phone" is Phase D, a separate consent conversation.
- **Remote turns are brain-only — ZERO server-side tool execution (audit B1).**
  Tool-call syntax the Mac's brain emits streams back to the phone and is
  answered by the PHONE's own local tool registry, exactly as Mini/Lil do
  today. The Mac never executes a tool on behalf of a remote caller. If
  server-side execution is ever wanted, that is a different feature with its
  own threat table — not an extension of this one.
- **The v1 PSK is scoped to generate-only (audit N4).** Phase D requires a
  new, explicit per-device consent grant — never a silent widening of what an
  existing pairing unlocks.

## 3. Architecture

```
Mac                                        iPhone
───                                        ──────
BrainService (NEW, own port, default OFF)  RemoteMacBrainProvider (NEW)
 ├─ NWListener + TLS-PSK, Wi-Fi/Ethernet    ├─ conforms InferenceProvider
 │  interfaces ONLY (audit B3)              │  + ToolCallingProvider
 ├─ POST /v1/generate  (SSE token stream)   ├─ SSE streaming client (NEW —
 ├─ GET  /v1/health    (PSK-authed, B4)     │
 └─ serves the SAME loaded brain the        │  repo has no streaming HTTP yet)
    Mac app is using (no second load)       └─ drops into the existing
BrainAdvertiser (dnssd, gemba pattern)         SwappableInferenceProvider slot
 └─ _m1k3-brain._tcp + TXT {v, name}       BrainBrowser (NWBrowser,
MCP server: UNTOUCHED, loopback-only        gemba state-machine pattern,
                                            AsyncStream seam)
```

- **Separate listener, separate port, separate consent.** The MCP server's
  loopback pin and one-client model are never modified.
- **dnssd advertiser** (gemba's `DNSServiceRegister` pattern) — advertises
  without binding, so the BrainService's NWListener owns its port cleanly.
  TXT carries protocol version + display name ONLY — never secrets, never
  capability details that fingerprint the user.
- **No second model load**: BrainService generates through the app's live
  `SwappableInferenceProvider`/current brain. Single-flight with the Mac's own
  turns and **the Mac user wins by preemption (audit S2): a new local turn
  CANCELS any in-flight remote generation** (the phone sees a clean
  stream-interrupted error and retries/falls back local); remote requests
  otherwise queue or 429 with Retry-After. **Remote turns pass through the
  same `applyCoolHead` gate as local sends — a hard requirement, not a
  recommendation**: a paired device hammering Big-tier generations must never
  thermally starve the person at the Mac.
- **Interface pinning is a spike-A1 acceptance criterion (audit B3):** an
  unconstrained NWListener binds every non-loopback interface — including a
  Tailscale/VPN tunnel or Personal Hotspot — silently converting "LAN-only"
  into "wherever this device routes." Pin to Wi-Fi/Ethernet interface types
  AND reject non-RFC1918/link-local source addresses at accept time;
  A1 must demonstrate the port is unreachable over an active Tailscale.
- **Every route on this listener requires the PSK-authenticated session —
  no exceptions (audit B4).** An unauthenticated health endpoint would be a
  free LAN recon surface (owner name, brain, version) for any device with
  zero PSK knowledge. Discovery hinting lives in the TXT record and nowhere
  else.

## 4. Pairing & transport (the security core)

- **Trust = a 32-byte PSK, exchanged visually, never over the network.**
  Pairing: Mac generates a random 32-byte secret + displays it as a QR
  (payload: `m1k3-pair://v1?psk=…&name=…&port=…`). Phone scans with an
  **IN-APP scanner only (audit N1)** — never the system Camera app, which
  would leak the `m1k3-pair://` URL into Safari history/Spotlight/Handoff.
  No PAKE, no pairing network window, no code typing — the QR on the
  Mac's screen IS the secure channel (an attacker needs eyes on your screen).
- **The Mac confirms every pairing (audit B2 — prevention, not detection).**
  Completing a handshake against an uncommitted PSK does NOT pair: the Mac
  shows *"New device wants to pair: <name/model>. Approve?"* and nothing is
  written to the Keychain — and not one `/v1/generate` byte is served — until
  the human clicks Approve. This closes the fastest-handshake-wins race (a
  QR-relaying attacker beating the legitimate phone) and makes multi-device
  pairing sane later.
- **PSK identity is a random opaque per-pairing value (audit S1):** TLS 1.3
  sends the PSK *identity* in the cleartext ClientHello (RFC 8446 §4.2.11) —
  it must never be a device name or anything fingerprintable. Server-side
  lookup among N stored identities must be constant-time.
- **iOS Local Network permission is a first-class UX moment (audit S1):**
  `NSLocalNetworkUsageDescription` + `NSBonjourServices` allowlist are
  required for discovery to work at all and surface a system consent dialog —
  Phase C designs for it (calm copy, graceful denied-state), not around it.
- **TLS 1.3 with PSK cipher suites** (Network.framework
  `sec_protocol_options_add_pre_shared_key`) — the PSK gives mutual
  authentication AND encryption in one move: no certificates, no CA, no
  trust-on-first-use hole. A client without the PSK cannot complete the
  handshake; there is no plaintext or TLS-without-PSK fallback path.
- **Storage:** `KeychainKeyStore` on BOTH ends (service `app.m1k3`,
  `AfterFirstUnlockThisDeviceOnly`, never iCloud-synced). One PSK per paired
  device (Mac stores N identities; phone stores 1 per Mac).
- **Revoke:** deleting the device row deletes its PSK → next handshake fails,
  AND any currently-open connection under that identity is terminated
  immediately (audit S3 — "phone just got stolen" must not wait for the
  stream to end). Toggle OFF tears down the listener AND the advertisement.
- **Pairing screen auto-expires** (QR regenerates/away in ≤60 s; a stale
  screenshot of an expired QR is useless because the displayed secret is only
  committed to the Keychain when a device completes its first handshake —
  uncompleted candidates are discarded on expiry).

## 5. Threat model (v1, LAN-only)

| Threat | Answer |
|---|---|
| Passive LAN sniffing | TLS 1.3 PSK — no plaintext path exists |
| Active MitM / rogue "Mac" advertising | Phone only handshakes with its stored PSK; a rogue advertiser can't complete TLS. Discovery is untrusted UI hinting ONLY — never trust TXT/name for auth |
| Malicious LAN client | Can't handshake without PSK; pairing requires physical screen access; connection attempts rate-limited + logged to `securityLog` |
| Stolen QR (photo of screen) | Bounded by expiry + first-handshake commit (§4); paired-device list makes a ghost visible; revoke is one tap |
| Replay | TLS 1.3 handles transport replay; /v1/generate is stateless |
| DoS (hammering the port) | Per-IP handshake rate limit; listener is default-OFF and only up while the toggle is on |
| Prompt-injection via remote turns | The LITERALLY same responder instance + CanaryGuard + securityLog as local turns (Phase B acceptance criterion — not a parallel reimplementation; audit S4). AND stated honestly: CanaryGuard was built for content-borne injection; a remote caller can itself be the adversary (stolen PSK / compromised phone) — Phase B's auditor pass must adversarially prompt FROM the remote path. Canary storage → Keychain in Phase B (the MCPHostController.swift:52 widening is here) |
| Unauthenticated recon (health or any future route) | Every route requires the PSK session — no exceptions (audit B4). Discovery hinting lives in TXT only |
| Rogue advertiser reusing the Mac's display name | Can't authenticate — but surface it as a SIGNAL, not silence: "a device claiming to be your Mac failed to authenticate" (audit N2) |
| Repeated canary trips from one paired identity | Escalate: active notification + auto-revoke candidate, not a passive log line (audit N3) |
| WAN exposure | OUT OF SCOPE v1. No port-forwarding guidance, no relay. Interface pinning (B3) keeps an incidental VPN/hotspot from widening the boundary silently |

## 6. Concurrency & seams (house style)

- Pure state machines, tested first: `PairingState` (idle → displaying(secret,
  expiresAt) → committed(deviceID) | expired), `BrainBrowserState` (gemba's
  found/lost/browsing diff logic, modernised), `RemoteBrainAvailability`
  (reachable × paired × enabled → picker visibility).
- NW layer behind protocol seams surfacing **AsyncStream** (not @Observable
  mutation — the gemba divergence note): `BrainAdvertising`, `BrainBrowsing`,
  `BrainServing`, `SecretDisplaying`. Fakes drive the streams in tests; the
  NW concretes are verify-by-launch + a SelfTest loopback probe mode
  (M1K3_SELFTEST_BRAINSERVE=1: start listener with a test PSK, connect a
  client in-process, assert a token round-trip).
- `RemoteMacBrainProvider`: conforms `InferenceProvider` (4 reqs) +
  `ToolCallingProvider` via `StatelessToolTurnSession` (no remote KV
  assumptions in v1; the Mac's own persona-prefix/KV reuse still applies
  server-side). `isAvailable` = reachable ∧ paired ∧ enabled, cheap cached
  read refreshed by the browser stream.
- **Net-new hard bit:** an SSE/chunked streaming client (repo has zero
  streaming HTTP today — everything is buffered `.data(for:)`). Own spike.

## 7. Phasing

- **A — spikes (scratch, no ship):** (1) TLS-PSK NWListener⇄NWConnection echo
  on LAN incl. iPhone-to-Mac on real hardware — acceptance criteria include
  the NEGATIVE paths (audit S1/B3): no-PSK, wrong-PSK, and forced-TLS-1.2
  connections hard-fail with zero bytes returned; min TLS pinned to 1.3;
  constant-time server-side selection among N identities verified as API-
  supported; the port unreachable over an active Tailscale/VPN; (2) SSE
  streaming client with cancellation + backpressure; (3) dnssd advertise +
  NWBrowser round-trip (port gemba's pattern) incl. the iOS Local Network
  permission dance. Each spike has a RESULTS.md verdict gate.
- **B — Mac side:** BrainService + pairing UI (Privacy pane) + paired-device
  list/revoke + canary→Keychain migration + securityLog wiring. Full review
  loop + security-auditor pass on the REAL code.
- **C — iOS side:** browser + RemoteMacBrainProvider + "Home Mac" picker tier
  + away-fallback feel.
- **D — later, separate consent:** remote recall (a narrow, allowlisted
  read-only knowledge route — NOT the full MCP surface), multi-device
  politeness (queueing), Big-tier download hints.

## 8. Open questions (Kev)

1. Naming: "Home Mac" vs "M1K3 at home" vs the Mac's actual name in the picker.
2. Should the Mac show a live indicator while serving a phone turn (menu-bar
   glyph treatment = the honest-disclosure instinct says yes)?
3. Battery/thermal etiquette: do remote turns respect CoolHeadPolicy the same
   as local sends (recommend: yes, same `applyCoolHead` path, phone shows
   "your Mac is easing off")?
4. visionOS: same provider drops in — worth including in C, or iPhone first?

### 8a. Proposed defaults (2026-07-31 — Claude's ballot; veto any line and Phase A unblocks)

1. **Naming: the Mac's actual name in the picker** ("Kev's Mac Studio"), with
   the feature itself called **Brain at Home** in Settings/marketing copy.
   Rationale: the picker row is a *device* choice and the Mac's real name is
   the only label that stays honest with two Macs in the house; BrainTier
   copy already speaks "your Mac", so the vocabulary is established. Reject
   "M1K3 at home" for the picker — it names the persona, not the device
   answering.
2. **Serving indicator: yes, structural.** The menu-bar glyph carries a
   persistent distinct state the entire time the listener is up (not only
   during a turn), plus a stronger beat while actively serving — same honesty
   doctrine as the mic. A notification is the wrong shape; a steady presence
   is. If the pixel-M can wear a subtle antenna, that's the move.
3. **Thermal etiquette: CoolHeadPolicy applies identically — and remote turns
   yield first.** Same `applyCoolHead` path; under pressure the Mac declines
   NEW remote turns before it eases local ones (the person at the keyboard
   outranks the person on the sofa), and the phone falls back to its own
   ladder with "your Mac's gone properly warm — Mini's got you." No queueing
   in v1 (S2 already pins local-preempts-remote).
4. **visionOS: free rider, not a lane.** The client lands behind the same
   `SwappableInferenceProvider` slot both shells share — visionOS gets it by
   compilation, iPhone is the verify surface. Don't sequence anything for the
   headset; don't exclude it either.

*Proposed by claude-fable-5, 2026-07-31, for Kev's veto — §8 stays the
authoritative open list until he rules; nothing below changes.*

## 9. Security-auditor findings (2026-07-14 pass — ALL FOLDED above)

Blocking (resolved in-spec): **B1** tool-calling scope pinned brain-only,
phone-side registry (§2) · **B2** pairing requires an explicit on-Mac Approve
before commit — prevention over detection (§4) · **B3** interface pinning +
RFC1918 source check, Tailscale-unreachable as an A1 criterion (§3/§7) ·
**B4** every route PSK-authed, no unauthenticated health (§3/§5).
Should-fix (folded): **S1** negative-path A1 criteria, opaque constant-time
PSK identities, the iOS Local Network permission named (§4/§7) · **S2** local
turns preempt remote; CoolHead on remote turns is a hard requirement (§3) ·
**S3** revoke kills live connections (§4) · **S4** same-responder-instance as
a Phase B acceptance criterion + adversarial-remote-prompting test (§5).
Notes (folded): **N1** in-app QR scanner only (§4) · **N2** failed-auth
impersonation surfaces as a signal (§5) · **N3** canary-trip escalation (§5) ·
**N4** PSK scoped generate-only; Phase D = new consent grant (§2).

---
*Signed: Kev + claude-fable-5, 2026-07-14, Confidence 0.85 (architecture calls
grounded in two code scouts — the loopback pin, the Swappable slot, the
missing streaming client are verified facts; security design hardened by a
full auditor pass with all 12 findings folded; the TLS-PSK mechanics remain
unproven in this codebase until spike A1's negative-path criteria run on real
hardware). Prior: Unknown.*
