# Security Policy

M1K3's whole promise is **"Your AI. Your Mac. Private by design."** — on-device
by default, and when you choose more power, it goes only to Apple's Private
Cloud Compute — so privacy and security reports are the most valuable
contributions this project can receive.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

- Preferred: [GitHub private vulnerability reporting](https://github.com/Round-Tower/M1K3/security/advisories/new)
  (Security tab → "Report a vulnerability").
- Or email **kevin@round-tower.ie** with `[M1K3 SECURITY]` in the subject.

You'll get an acknowledgement within **72 hours** and a status update within
**14 days**. If the report is valid we'll credit you in the fix's release notes
(or keep you anonymous — your call).

## What counts as high priority here

Anything that breaks the local-only promise ranks above a classic RCE for this
project:

- Data leaving the machine without explicit user consent (network calls beyond
  the opt-in web search / model downloads / a user-initiated Private Cloud
  Compute turn).
- Prompt-injection paths that exfiltrate knowledge-base or memory content
  through the MCP server or web tools.
- Sandbox or entitlement escapes in the Mac app.
- The local MCP server (`127.0.0.1:4242`) being reachable off-host or abusable
  by other local processes beyond its design.
- PII surviving the diagnostic redaction in issue reports.

## Private Cloud Compute (a later release, opt-in)

**Not in 1.0.** The shipping build has no cloud path at all: the rung is built
(the policy, the consent sheet, the Mac shell, the adapter) but nothing
compiles it into a release, and the Developer ID build does not even carry the
entitlement. The App Store build carries the entitlement Apple granted for the
later release; it is inert in 1.0. When the rung ships:

With the Private Cloud Compute switch off — the default — nothing leaves the
device. Turning it on in Settings will add one control next to the message
field: sending a single message at a time to Apple's Private Cloud Compute,
after a consent sheet shows exactly what goes — the message, plus the
conversation so far only if you tick it. Never memories, documents, tools,
calendar, location, or your profile. Every PCC answer will be labelled in the
chat. If PCC fails or the quota runs out, the on-device brain answers and says
why.

Apple's own guarantee, not ours:

> "PCC uses that data only to perform the operations requested by the user"
> and "no user data is retained in any form after the response is returned."
>
> — Apple, [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/)

What M1K3 will log about a PCC turn: request/response sizes and error classes
(rate-limited, quota reached, network failure) only — never the message, the
conversation, or the answer. M1K3 itself has no servers and never sees or
stores your conversations, on-device or via PCC.

**M1K3 for Teams:** once the rung ships, organisations will be able to force
the Private Cloud Compute switch off by policy, so on those installs nothing
leaves the network at all. Today that is true of every install by construction.

## Supported versions

| Surface | Status |
|---|---|
| macOS app (`macos/`, TestFlight beta) | Supported — latest beta build |
| 間 AI mobile (`app/`) | Pre-release — not yet supported |
