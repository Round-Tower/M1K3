# Resolution Center reply — com.apple.security.network.server (Mac 1.0.0, 2026-09-16)

Paste-ready. The App Review Information notes (`review_notes.txt`, pushed with
`tools/asc/review_notes.py set --file ../fastlane/review_notes.txt --confirm`) carry the
same facts plus the verification steps; update the notes BEFORE replying, since the
message asks for both.

---

Thank you — the entitlement is required and in use. M1K3 listens for incoming connections in two features. Both are OFF by default and are enabled by the user in Settings ▸ Privacy:

1. MCP server — a local HTTP/JSON-RPC server bound to 127.0.0.1 port 4242 (loopback only; never a LAN interface) so AI coding agents on the same Mac (Claude Code, Cursor, VS Code) can call the app's tools. To verify: turn on Settings ▸ Privacy ▸ MCP server, then in Terminal run `/Applications/M1K3.app/Contents/Helpers/m1k3 status`, or `lsof -iTCP:4242` to see the socket bound to 127.0.0.1 only.

2. Brain at Home — a local-network service (Bonjour `_m1k3._tcp`, default port 4243) so the user's own iPhone or iPad running M1K3 can use this Mac's on-device models. It serves only devices paired by scanning a QR code on this Mac; every connection is TLS with a pre-shared key established at pairing, and unpaired clients are refused before any HTTP is exchanged. To verify: Settings ▸ Privacy ▸ Brain at Home ▸ "Serve my brain to my devices" ▸ "Pair a device…".

The App Sandbox refuses to bind a listening socket without com.apple.security.network.server, which is why the app carries it. The embedded command-line helper is a client only and does not carry it. Neither feature reaches the internet, and nothing listens until the user turns one on.

The App Review Information notes now describe both listeners and the steps above.

---

*Signed: Kev + claude-fable-5.1, 2026-09-16, Confidence 0.85 — every claim read off the
entitlement files, `LocalMCPHTTPServer` (loopback pin), `BrainServeListener` /
`BrainAdvertiser` (TLS-PSK, `_m1k3._tcp`, port 4243) and the Settings panes; the
pairing-listener ephemeral port is from `BrainServeController` (`port: 0`). Prior: Unknown.*
