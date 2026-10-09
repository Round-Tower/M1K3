# Security Policy

M1K3's whole promise is **"Your AI. Your Mac. Private by design."** — on-device
by default, and when you choose more power, it goes only to Apple's Private
Cloud Compute — so privacy and security reports are the most valuable
contributions this project can receive.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

- Preferred: [GitHub private vulnerability reporting](https://github.com/Round-Tower/M1K3/security/advisories/new)
  (Security tab → "Report a vulnerability").
- Or email **hello@round-tower.ie** with `[M1K3 SECURITY]` in the subject.

You'll get an acknowledgement within **72 hours** and a status update within
**14 days**. If the report is valid we'll credit you in the fix's release notes
(or keep you anonymous — your call).

## What counts as high priority here

Anything that breaks the local-only promise ranks above a classic RCE for this
project:

- Data leaving the machine without the user's say-so (network calls beyond
  web search, which is on by default with one switch in Settings to turn it
  off; model downloads the user asks for; a user-initiated Private Cloud
  Compute turn).
- Prompt-injection paths that exfiltrate knowledge-base or memory content
  through the MCP server or web tools.
- Sandbox or entitlement escapes in the Mac app.
- The local MCP server (`127.0.0.1:4242`) being reachable off-host or abusable
  by other local processes beyond its design.
- PII surviving the diagnostic redaction in issue reports.

## Private Cloud Compute (Mac App Store build, opt-in)

**Opt-in, off by default, App Store build only.** The rung exists only where
Apple's entitlement does: the Mac App Store build carries
`com.apple.developer.private-cloud-compute` (`M1K3-MAS.entitlements`); the
Developer ID DMG does not, so a DMG install has no cloud path at all. iOS has
no PCC rung.

With the Private Cloud Compute switch off — the default — no conversation goes
to a cloud model. Turning it on in Settings adds "Private Cloud Compute" to the
brain picker ([ADR 0010](./macos/docs/adr/0010-private-cloud-is-a-brain-pick-that-holds.md)).
The first send to it opens a consent sheet that shows exactly what goes — the
message, plus the conversation so far only if you tick it — and the answer is
asked once and kept for as long as PCC stays picked, across conversations and
relaunches. Never memories, documents, tools, calendar, location, or your
profile. Every PCC answer is labelled in the chat. If PCC fails or the quota
runs out, the on-device brain answers and says why.

Apple's own guarantee, not ours:

> "PCC uses that data only to perform the operations requested by the user"
> and "no user data is retained in any form after the response is returned."
>
> — Apple, [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/)

What M1K3 logs about a PCC turn: request/response sizes and error classes
(rate-limited, quota reached, network failure) only — never the message, the
conversation, or the answer. M1K3 itself has no servers and never sees or
stores your conversations, on-device or via PCC.

**M1K3 for Teams:** organisations can force the Private Cloud Compute switch
off by policy, so on those installs no conversation goes to anyone's cloud; the
documented crossings that remain are the model downloads you ask for and web
search (and the lookups it makes), which the user can switch off in Settings.

## Supported versions

| Surface | Status |
|---|---|
| macOS app (`macos/`, TestFlight beta) | Supported — latest beta build |
| 間 AI mobile (`app/`) | Pre-release — not yet supported |

<!-- Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85, Prior: Unknown (SECURITY.md predates
     this signature). The PCC section said "Not in 1.0 … no cloud path at all"; the rung shipped in the
     App Store build (entitlement in M1K3-MAS.entitlements, ADR 0010 consent, first live generation
     2026-09-15). Rewritten to what ships: opt-in, off by default, MAS lane only, none on the DMG.
     Review: Kev + claude-fable-5.1, 2026-10-09 (PR #527 fold) — Teams no longer claims an administrator
     can switch web search off: the only managed-off key is PCC's (PrivateCloudRung.managedOffDefaultsKey);
     webSearchAllowed() reads a plain UserDefaults key. Web search names the lookups it makes. -->
