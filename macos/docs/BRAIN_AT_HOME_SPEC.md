# Brain at Home — the LAN brain service (v1.1, as built)

> Your other devices discover this Mac on the home network, pair once by QR,
> and stream from its brain — everything stays inside your walls.
>
> Lineage: the signed scratch spec (`scratch/brain-at-home/SPEC.md`,
> 2026-07-14, 12 security-auditor findings folded) → the Phase A spike
> verdicts (`scratch/brain-at-home/spikes/RESULTS.md`, 2026-08-19) → this
> document, the spec AS BUILT for the Mac side (PR: feat/brain-at-home-service).

## §1 Product shape (v1, Mac side)

- **Settings → Privacy → Brain at Home**: "Serve my brain to my devices" —
  default OFF (nil is a NO). ON = listen + advertise (`_m1k3._tcp`,
  TXT = version + display name only); OFF = both gone instantly.
- Pairing is a one-time ceremony: the Mac shows a QR (≤60 s), the device
  scans it, the Mac asks **"«name» wants to pair — Approve?"**. Paired
  devices are listed with one-tap revoke.
- Client surfaces (iPhone Phase C, Android after) are NEXT sessions — this
  PR ships the Mac server, verified by package-level loopback TLS round-trips
  including the negative paths.

## §2 Scope: inference first — AND the scoped MCP route (the 2026-08-19 ruling)

The scratch spec ruled "inference, not MCP". **Kev's 2026-08-19 ruling: both**
— but the MCP surface reaches the LAN only in a deliberately narrower shape:

- `POST /v1/generate` — raw prompt → SSE token stream off the live runtime
  façade (no second model load). **Raw is STRUCTURAL** (2026-08-19 security
  audit, finding 1): the route runs through `RawCompletionProviding` — a
  capability seam whose conformances open a session with **no persona, no KV
  persona seed, no instructions, no tools, no retrieval**, so there is
  nothing in context to prefix-extract. Forwarded by every provider façade
  (the #134 rule) and pinned by `SwappableCapabilityForwardingTests`; a
  backend that can't do raw yields an honest **503**, never a persona-seeded
  fallback. `max_tokens` is honored, clamped to the provider's own cap
  (shorten, never lengthen). **Zero server-side tool execution (audit B1)**:
  tool-call syntax the brain emits streams back for the CLIENT's own
  registry. A not-ready brain refuses with 429 `warming` — a remote request
  can never trigger a model load or download as a side effect.
- `POST /mcp` — the SAME tool implementations the loopback server dispatches,
  filtered through **`MCPToolScope.lan`** (M1K3BrainServe): an ALLOWlist of
  read/ask tools only — `search_knowledge, list_documents, get_document,
  ask_m1k3, get_answer, list_jobs, get_status, memory_stats, recall_memory,
  related_memory`. **Excluded**: `remember`/`forget_memory` (writes to
  permanent memory), `speak`/`listen`/`stop_speaking` (the Mac's speakers +
  microphone), `open_link` (the Mac's screen). A new tool is LAN-invisible
  until consciously added. The route has its **own toggle, default OFF** —
  never inherited from the serve toggle (the CONTEXT_TOOLS_PLAN P2 second
  consent tier, finally built). **Named equivalence (audit finding 2):**
  `ask_m1k3` runs the SAME agent loop as loopback — when the Settings
  web-search toggle allows it, an answer may fetch the web from the Mac.
  That reach is governed by the existing web consent, identical to loopback,
  and is stated in the Settings footer rather than implied away by "read
  tools only".
- The loopback `127.0.0.1:4242` MCP server is **untouched** — same pin, same
  15 tools. The Privacy-pane promise copy was rewritten honestly: loopback
  server unreachable from the network; the ONLY network path is Brain at
  Home, paired devices, off by default.

## §3 Transport & mechanism (AMENDED by spike A1)

**The scratch spec's TLS 1.3 external-PSK does not handshake on
Network.framework** (macOS 26.4, `-9838` — reproducible by
`spikes/spike-a1-tls-psk.swift`). The mechanism as built:

- **TLS 1.2 pinned (min = max) + `TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256`
  (RFC 8442, 0xD001)** — PSK mutual authentication WITH forward secrecy
  (plain `TLS_PSK` 0x00A8 also works and was rejected: no PFS). The modern
  `tls_ciphersuite_t` enum has no PSK suites; the raw-value door is used and
  documented in `BrainServeTLS`. No other suites are appended: no-PSK,
  wrong-PSK (bad MAC), and plain-TCP clients all die with **zero application
  bytes** (spike-proven, re-pinned by `BrainServeListenerTests`).
- Revisit per OS release: if a future macOS fixes 1.3 external-PSK, moving is
  a two-line change in `BrainServeTLS`.
- Interface pinning (audit B3): `prohibitedInterfaceTypes = [.cellular,
  .other]` (`.other` covers utun/VPN tunnels) + an accept-time
  `PrivateSourcePolicy` gate (RFC1918/link-local/loopback only). **The live
  Tailscale-unreachable check is hardware-owed.**
- Every route requires the PSK handshake (audit B4) — there is no
  unauthenticated route; discovery hinting lives in the TXT record only.
- **Clients must be `NWConnection`** on Apple platforms — URLSession has no
  external-PSK hook (spike A2 finding). Android: Conscrypt's `PSKKeyManager`
  speaks the TLS 1.2 PSK suites incl. ECDHE_PSK, so the 0xD001 arm is MORE
  Android-compatible than the 1.3 mechanism was (noted, not yet probed; the
  cert-pin-via-QR profile remains the fallback).

## §4 Pairing as built (audit B2/S1/S3/N1)

- QR payload: `m1k3-pair://v1?psk=<b64url 32B>&id=<opaque identity>&port=
  <pairing port>&mainPort=<serve port>&name=<mac name>`. In-app scanner only
  on the client (N1). Identity is a random UUID — never a device name (S1).
- **The candidate secret only ever loads into a separate, ephemeral PAIRING
  listener serving nothing but `POST /v1/pair`** — the main listener never
  holds it, so a QR-holder cannot reach `/v1/generate` before Approve **by
  construction**, not by a runtime check (B2, strengthened from the scratch
  spec's design). The pairing listener lives ≤60 s and dies on
  approve/decline/expiry.
- Approve is the ONLY path that writes the PSK to the Keychain
  (`KeychainKeyStore`, service `app.m1k3`, account `brainserve-psk-<id>`,
  afterFirstUnlock, device-only) and mints the device row. `PairingSession`
  (pure, TDD) pins: approve-without-request mints nothing; wrong-identity/
  expired requests are ignored; a candidate discarded on cancel never existed.
- Client confirmation flow: after Approve the main listener restarts with the
  new key — the device's next `/v1/health` handshake succeeding IS the
  "paired" signal (the pairing listener is gone by then).
- **Revoke** deletes the key + restarts the main listener without it — live
  connections under that identity die with the restart (S3). Zero paired
  devices = no listener at all (`BrainServeListener` refuses to start with an
  empty credential set — an unauthenticated listener cannot exist).

## §5 Etiquette & preemption (audit S2, §8a.3)

- Admission (`RemoteTurnDecision`): a busy local turn → `429 Retry-After:
  15`; thermal/low-power pressure (the same `backgroundWorkAllowed` read
  Prudent Compute uses) → `429 Retry-After: 120` — remote yields FIRST; a
  not-ready brain → `429 warming` (30 s).
- **Remote generation is single-flight** (audit finding 4): the one MLX slot
  never serves two remote streams at once — a second concurrent
  `/v1/generate` gets `429`, checked and claimed in one synchronous actor
  stretch so two arrivals can't both pass.
- A NEW local turn preempts in-flight remote streams — from
  `AppEnvironment.send` AND from `intelligenceAsk` (menu-bar Ask, loopback
  `ask_m1k3`), so a local ask can't race a remote stream on the same slot.
  A client hangup mid-stream reaches the producer (spike A2 + listener test).
- **Connection hygiene** (audit finding 5): a connection must deliver a
  parseable request within 10 s or be dropped (the Slowloris guard — covers
  never-handshakes too, since the deadline starts at accept), and open
  connections are capped at 16. Stop/revoke tears down **every** open
  connection, not just in-flight streams (finding 6).
- The serving indicator (§8a.2): Privacy-pane status + a menu-bar popover
  caption while serving. The pixel-M "antenna" glyph treatment is Kev's-eye
  work, owed.

## §6 What this PR deliberately does NOT do (named)

- **No phone/Android client** (Phase C — next sessions).
- **Canary tripwire stays in UserDefaults** — the Keychain migration named by
  the scratch spec's Phase B is a follow-up, kept out of this PR for review
  size; the LAN ask path runs the same CanaryGuard as loopback either way.
- **LAN MCP calls log to the Agent Interaction Log without a client name**
  until the heartbeat-timeline PR's identity stamping merges (they meet at
  `MCPToolRegistry`; reconcile then — the paired device NAME is the natural
  stamp for LAN sessions).
- No WAN, no relay, no port-forwarding guidance (out of scope, unchanged).
- Rate-limiting beyond admission (per-IP handshake buckets) is deferred; the
  listener is default-OFF, paired-only, private-source-gated, and now also
  connection-capped with a request deadline (audit finding 5).
- **Audit N2/N3 remain deferred, named** (2026-08-19 audit, finding 8): a
  failed PSK handshake now logs (`brain-serve` category — the passive half
  of N2), but there is no UI surface for impersonation attempts (N2's other
  half) and no auto-revoke/notify escalation on repeated canary trips from
  one paired identity (N3). Both ride the client-phase PR, where a real
  attacker model exists to design against.

## §7 Verify

- `swift test` — M1K3BrainServe: 30 tests incl. REAL loopback TLS-PSK
  round-trips (health, SSE stream + done, 429, wrong-PSK zero bytes,
  plain-TCP no app bytes, 404s, empty-credentials refusal, raw-unavailable
  503, second-stream 429 single-flight, and the Slowloris deadline drop).
- Hardware-owed (Kev): pair a real second device on the LAN (QR + Approve +
  stream); Tailscale-unreachable if a tunnel is up; the local-network
  permission dialog's first-use feel.

---
*Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.85 (mechanism
spike-proven and re-pinned in the fast suite; pairing state machine TDD'd;
the app glue — ceremony UX, LAN reachability, Bonjour on a real network — is
verify-by-launch and named hardware-owed. The LAN-MCP widening is Kev's
explicit 2026-08-19 ruling over the scratch spec's scoping call, shipped in
its narrowest shape: scoped allowlist, own default-OFF toggle, behind
pairing. Amended same-day after the pre-merge security audit: raw made
structural via `RawCompletionProviding` [the audit's one blocking finding],
single-flight remote generation, fail-closed source gate, connection
cap + request deadline, all-connection teardown on revoke, and the N2/N3
deferrals named instead of silent.) Prior: Kev + claude-fable-5
(scratch/brain-at-home/SPEC.md, 2026-07-14).*
