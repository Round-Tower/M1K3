# Security Policy

M1K3's whole promise is **"Your AI. Your Mac. Nothing leaves."** — so privacy and
security reports are the most valuable contributions this project can receive.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

- Preferred: [GitHub private vulnerability reporting](https://github.com/Round-Tower/m1k3/security/advisories/new)
  (Security tab → "Report a vulnerability").
- Or email **kevin@round-tower.ie** with `[M1K3 SECURITY]` in the subject.

You'll get an acknowledgement within **72 hours** and a status update within
**14 days**. If the report is valid we'll credit you in the fix's release notes
(or keep you anonymous — your call).

## What counts as high priority here

Anything that breaks the local-only promise ranks above a classic RCE for this
project:

- Data leaving the machine without explicit user consent (network calls beyond
  the opt-in web search / model downloads).
- Prompt-injection paths that exfiltrate knowledge-base or memory content
  through the MCP server or web tools.
- Sandbox or entitlement escapes in the Mac app.
- The local MCP server (`127.0.0.1:4242`) being reachable off-host or abusable
  by other local processes beyond its design.
- PII surviving the diagnostic redaction in issue reports.

## Supported versions

| Surface | Status |
|---|---|
| macOS app (`macos/`, TestFlight beta) | Supported — latest beta build |
| 間 AI mobile (`app/`) | Pre-release — not yet supported |
