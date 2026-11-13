# M1K3 for Claude (plugin)

Connects Claude to the [M1K3](https://m1k3.app) app running on this Mac, so
Claude can search your documents and notes, save and recall memories, ask
M1K3's local brain, and speak aloud in M1K3's voice.

M1K3 is a free, private AI assistant for the Mac. This plugin adds no model and
no account: it is one small file that passes Claude's tool calls to the app you
already have open.

## What you need

- A Mac with the **M1K3 app** (free on the Mac App Store) open.
- In M1K3: **Settings ▸ Server ▸ MCP server** switched on.
- The **access token** from that screen. The plugin asks for it when you enable
  it and keeps it in your system's secure credential store.
- Node 18 or later on your PATH.

## Install

In Claude Code:

```
/plugin marketplace add Round-Tower/M1K3
/plugin install m1k3@m1k3
```

Then paste the access token when asked. Leave the port at 4242 unless you
changed it in M1K3. If the tools do not appear at once, run `/reload-plugins`.

Already connected M1K3 with `m1k3 connect claude`? Keep one of the two. With
both, every tool is listed twice (once as `mcp__m1k3__…`, once as
`mcp__plugin_m1k3_m1k3__…`). To keep the plugin:
`claude mcp remove m1k3 -s user`.

## What this plugin runs, sends and fetches

- **Runs:** `node server/index.js`, a single file with no dependencies. It
  installs nothing and downloads nothing.
- **Sends:** each tool call, and your access token, to M1K3 on this Mac at
  `http://127.0.0.1:<port>/mcp`. The address is fixed to loopback; only the port
  can be changed, and a redirect is refused. It contacts nothing else.
- **Fetches:** nothing from the internet. No telemetry.

What a tool **returns** is another matter. A memory, a document excerpt or a
transcript that M1K3 hands back becomes part of your conversation with Claude,
exactly like text you paste in. Use it for what you are happy to share with the
model you are talking to. M1K3's own switches still apply: Private Cloud Compute
and each tool group stay off until you turn them on in M1K3.

## Limits

- **macOS only**, and only while the M1K3 app is running. If it is not, each
  call answers with a sentence saying so.
- M1K3 serves **one client at a time**: a second Claude session connecting ends
  the first one's link.
- **Claude Code.** Claude's chat apps do not start local servers from a plugin,
  and Cowork does not ask for the token, so the plugin does not load there.
- The bridge is the same file as the MCP Bundle's (`integrations/mcpb`); a test
  holds the two equal.

## Privacy Policy

M1K3 collects no data. The full policy is at <https://m1k3.app/privacy>.

## Support

<https://github.com/Round-Tower/M1K3/issues>

Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.6. Prior: none (new file).
Context: Kev, 2026-11-12, on listing M1K3 for Claude users: "Let's go it pal".
Open: not yet installed from the marketplace by hand, and not yet submitted to
Claude's directory (Kev's, through the portal). The Cowork and chat limits are
as Anthropic's platform-support page read on 2026-11-12.

Review: Kev + claude-fable-5.2, 2026-11-13 — installed from the marketplace by hand (Kev, in a live Claude Code
session: marketplace add, install, reload): the bridge answered and every tool was driven through it the same day
(the run that found #826's six bugs). That retires the first half of the Open; the directory submission is still
Kev's. Added `/reload-plugins` and the one-route note: that session had the `connect` entry too, and listed each
tool twice. Confidence 0.8.
