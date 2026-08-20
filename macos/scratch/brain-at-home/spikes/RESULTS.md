# Brain-at-Home — Phase A spike verdicts (2026-08-19)

Machine: Kev's M1 Max, macOS 26.4, Xcode 26 SDK (MacOSX26.5). Each spike is a
self-contained `swift <file>.swift` script; exit 0 = all criteria pass. Run
them again before trusting these on a newer OS — A1's headline finding is
exactly the kind of thing an OS update changes.

## A1 — TLS-PSK echo (`spike-a1-tls-psk.swift`) · **PASS, with a spec-impacting finding**

**★ TLS 1.3 external-PSK does NOT handshake on Network.framework today.**
Client parks in `.waiting(-9838)` with matching 32-byte PSKs, min+max pinned
to 1.3, and the mandatory 1.3 ciphersuite appended. The SPEC's §4 mechanism
as written ("TLS 1.3 with PSK cipher suites") is unimplementable on this OS.

**★ The viable arm: TLS 1.2 pinned + `TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256`
(RFC 8442, 0xD001) — PSK mutual auth WITH forward secrecy.** The modern
`tls_ciphersuite_t` enum carries no PSK suites at all (SDK-header-verified:
RSA/ECDHE-cert/1.3 suites only), but imported C enums accept raw values and
the stack honours both 0x00A8 (plain PSK) and 0xD001 (ECDHE_PSK). Use
**0xD001 only** — plain `TLS_PSK` has no forward secrecy (a stolen PSK would
decrypt recorded traffic; ECDHE_PSK closes that).

Negative battery, all green against the ECDHE_PSK listener:
- wrong PSK → handshake dies on `-9820 bad MAC`, **zero bytes** served
- plain TCP → the only bytes back are one TLS **alert record**
  (`15 03 01 00 02 02 46` = fatal, protocol_version) — no application bytes,
  ever (audit B4 satisfied at the TLS layer)
- `sec_protocol_options_set_pre_shared_key_selection_block` exists (the
  multi-identity seam, audit S1) — compile-proven, wiring untested
- `prohibitedInterfaceTypes = [.cellular, .other]` accepted (`.other` covers
  utun/VPN tunnels). **Tailscale-unreachable remains hardware-owed** —
  loopback can't demonstrate interface pinning.

**Spec amendments this forces (fold into the promoted doc, PR 4):**
1. §4's "TLS 1.3" → "TLS 1.2 pinned (min = max) + ECDHE_PSK 0xD001, no other
   suites"; the threat table's transport-replay line re-argued for 1.2
   (ECDHE_PSK still gives per-session keys; TLS 1.2 GCM nonce handling is
   the stack's, not ours).
2. The A1 criterion "forced-TLS-1.2 hard-fail" inverts: we PIN 1.2; the
   hard-fail cases are no-PSK / wrong-PSK / plain-TCP (all proven).
3. Revisit per OS release: if a future macOS fixes 1.3 external-PSK, moving
   is a two-line ciphersuite/version change behind the same seam.
4. Android: Conscrypt's `PSKKeyManager` speaks the TLS 1.2 PSK suites
   (including ECDHE_PSK), so the 0xD001 arm is *more* Android-compatible
   than the 1.3 mechanism was. The cert-pin-via-QR profile stays the
   fallback if Conscrypt PSK proves painful in practice.

## A2 — SSE streaming over the PSK channel (`spike-a2-sse-stream.swift`) · **PASS 4/4**

- Server writes an SSE head + per-event frames as individual `NWConnection`
  sends — the client saw **7 distinct arrivals over ~954 ms** for a 6-event
  stream on a 150 ms cadence: genuinely incremental, nothing coalesced to
  connection close. The "streaming writer" the repo lacks is, at the NW
  layer, just *not* buffering — no chunked-encoding machinery needed when
  the connection closes with the stream.
- Client cancel mid-stream (after 2 events) surfaced as a **failed server
  send at event 3** — cancellation reaches the producer, so a remote
  generation can be torn down promptly (audit S2's preemption relies on
  this).
- **★ URLSession cannot be the client**: it has no external-PSK hook (TLS is
  configured via delegate challenges — certs only). The streaming client on
  every Apple surface must be `NWConnection`. This kills any "just
  URLSession.bytes" shortcut and is worth carrying into the Android note
  (OkHttp has the same shape: PSK needs Conscrypt's SSLSocketFactory, not
  the default TLS config).

## A3 — dnssd advertise + NWBrowser (`spike-a3-bonjour.swift`) · **PASS 4/4**

- `DNSServiceRegister` advertises `_m1k3-spike._tcp` + TXT (`v`, `name`
  only) **without binding the port** — the gemba advertise-without-binding
  pattern ports cleanly; the real listener keeps sole ownership of its
  socket.
- `NWBrowser(.bonjourWithTXTRecord)` finds it and surfaces the TXT metadata;
  `DNSServiceRefDeallocate` makes the browser report the service gone
  (clean teardown for the toggle-OFF path).
- No local-network permission prompt fired for this terminal-hosted run;
  the sandboxed app + iOS still need `NSLocalNetworkUsageDescription` (+
  `NSBonjourServices` on the browsing side) — unchanged from the spec.

## Verdict

**Phase A GATE: OPEN.** All three spikes pass; PR 4 (BrainService) may
proceed on the amended mechanism (ECDHE_PSK 0xD001, NWConnection clients,
dnssd advertiser). Hardware-owed before ship: Tailscale-unreachable (B3) and
a real second-device pairing.

*Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (every claim is a
reading from a run of the committed scripts on the named machine; the TLS 1.3
failure is reproducible-by-script, not a web claim; the Conscrypt note is
prior knowledge, NOT probed — verify when the Android client session starts).
Prior: scratch/brain-at-home/SPEC.md (Kev + claude-fable-5, 2026-07-14).*
