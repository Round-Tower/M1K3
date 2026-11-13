# M1K3 for Claude (plugin)

Connects Claude to the [M1K3](https://m1k3.app) app running on this Mac, so
Claude can search your documents and notes, save and recall memories, ask
M1K3's local brain, and speak aloud in M1K3's voice.

M1K3 is a free, private AI assistant for the Mac. This plugin adds no model and
no account, and it runs no code of its own: it is one setting that points Claude
at the app you already have open.

## What you need

- A Mac with the **M1K3 app** (free on the Mac App Store) open.
- In M1K3: **Settings ▸ Server ▸ MCP server** switched on.
- The **access token** from that screen. The plugin asks for it when you enable
  it and keeps it in your system's secure credential store.

## Install

In Claude Code:

```
/plugin marketplace add Round-Tower/M1K3
/plugin install m1k3@m1k3
```

Then paste the access token when asked.

## What this plugin runs, sends and fetches

- **Runs:** nothing. The plugin holds no script and no program: a manifest, an
  icon, this page and one server address.
- **Sends:** Claude Code itself sends each tool call, with your access token in
  the `Authorization` header, to M1K3 on this Mac at `http://127.0.0.1:4242/mcp`.
  The address is fixed to loopback. The token is sent nowhere else.
- **Fetches:** nothing from the internet. No telemetry.

What a tool **returns** is another matter. A memory, a document excerpt or a
transcript that M1K3 hands back becomes part of your conversation with Claude,
exactly like text you paste in. Use it for what you are happy to share with the
model you are talking to. M1K3's own switches still apply: Private Cloud Compute
and each tool group stay off until you turn them on in M1K3.

## Limits

- **macOS only**, and only while the M1K3 app is running. If it is not, Claude
  Code shows the server as failed; open M1K3, then reconnect from `/mcp`. The
  same goes after M1K3 restarts.
- M1K3 serves **one client at a time**: a second Claude session connecting ends
  the first one's link.
- **Claude Code.** M1K3 listens on this Mac only, so Claude on the web cannot
  reach it, and Cowork does not ask for the token.
- For Claude Desktop there is the MCP Bundle (`integrations/mcpb`), which
  carries a small bridge because Desktop extensions speak stdio.

## Privacy Policy

M1K3 collects no data. The full policy is at <https://m1k3.app/privacy>.

## Support

<https://github.com/Round-Tower/M1K3/issues>

Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.6. Prior: none (new file).
Context: Kev, 2026-11-12, on listing M1K3 for Claude users: "Let's go it pal".
Open: the Cowork and chat limits are as Anthropic's platform-support page read
on 2026-11-12.
Review: Kev + claude-fable-5.2, 2026-11-13 — 0.1.0 installed from the marketplace
and answered a tool call (Kev, by hand). The directory's validator then held it
for running a script (only Verified organisations may), so 0.2.0 drops the Node
bridge for a direct loopback HTTP entry: no code, no Node, no port option.
Confidence 0.6. Open: the directory's verdict on a loopback address.
