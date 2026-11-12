# M1K3 for Claude: the MCP Bundle

A small extension that connects Claude (or any MCP client that launches a local
command) to the M1K3 app running on your Mac. Claude can then search your
documents and notes, save and recall memories, ask M1K3's local brain, and speak
aloud in M1K3's voice.

It is a bridge, not a second server: one dependency-free Node script
(`server/index.js`) that relays to M1K3's own MCP server on `127.0.0.1`.

## What you need

- The M1K3 app (free, Mac App Store), open.
- **Settings ▸ Server ▸ MCP server** switched on.
- The **access token** from that screen.

## Install

1. Build it (below) or take `m1k3.mcpb` from a release.
2. Open `m1k3.mcpb` with Claude Desktop.
3. Paste the access token when asked. Leave the port at 4242 unless you changed it.

Claude Code users do not need the bundle: `m1k3 login && m1k3 connect claude`
wires the app in directly (see [MCP_SETUP.md](../../macos/docs/MCP_SETUP.md)).

## What leaves your Mac

The bridge talks to M1K3 on this Mac and to nothing else: the address is fixed to
loopback, and only the port can be changed.

What a tool **returns** is another matter. A memory, a document excerpt or a
transcript that M1K3 hands back becomes part of your conversation with Claude,
exactly like text you paste in. Use it for what you are happy to share with the
model you are talking to. M1K3's own switches still apply: Private Cloud Compute
and each tool group stay off until you turn them on in M1K3.

## Limits

- **macOS only**, and only while the M1K3 app is running. If it is not, each call
  answers with a sentence saying so.
- **One client at a time.** M1K3 serves one connected MCP client; a second one
  connecting ends the first one's session.
- The tools are M1K3's own (19 today). The bundle's list is checked against the
  app's in CI.

## Build and test

```sh
node --test integrations/mcpb/test/bridge.test.js integrations/mcpb/test/manifest.test.js
integrations/mcpb/build.sh        # writes dist/m1k3.mcpb and prints its SHA-256
```

A bundle is a zip of `manifest.json`, `icon.png` and `server/index.js`.

## Privacy Policy

The bridge collects nothing, stores nothing and sends nothing off your Mac. The
access token you enter is kept by the client that runs the bundle (Claude Desktop
stores it as a secret) and is sent only to M1K3 on `127.0.0.1`. M1K3's own policy:
<https://m1k3.app/privacy>. Questions: open an issue at
<https://github.com/Round-Tower/M1K3/issues>.

_Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.7 (the bridge is pinned
by its tests and was driven against the live app, 1.4.0 build 550: initialize, 19
tools, one call). Prior: Unknown._
_Open: the bundle has not been opened in Claude Desktop yet, nor checked with the
official `mcpb validate`._
