# Wiring M1K3 into Claude (MCP)

M1K3 exposes MCP on **two surfaces**:

1. **The in-app HTTP server** — the live, full-capability surface. 18 tools
   (knowledge search, documents, voice, listening, memory graph, todos,
   `ask_m1k3`, `remember`, …; the full list is the README's generated table) served at `http://127.0.0.1:4242/mcp` while the app runs.
   **This is the way to connect.**
2. **The `M1K3MCP` stdio binary** — a knowledge-only fallback (3 tools:
   `search_knowledge`, `list_documents`, `get_document`) that reads the app's
   store directly, for clients that can't speak HTTP or when the app is closed.

Both surfaces send MCP `instructions` at initialize (`M1K3ServerInstructions`),
built from the tools that surface registers. The app's server tells every agent
that M1K3 is the user's voice: when the user is clearly there, `speak` short,
audio-first updates at the moments that matter (at most once per phase, never
for routine progress), and never say a secret aloud. The
stdio binary and the LAN brain server (`m1k3-brain`, paired devices) have no voice
tools, so they only point agents at the knowledge tools they serve.
No per-agent setup is needed for any of this.

## 1. Connect to the app (HTTP — recommended)

Turn the server on in the app: **Settings → Privacy → MCP server**. Every
request needs the server's **access token** (#270): M1K3 mints it on first
start and keeps it in the Keychain; Settings shows it masked, with **Copy** and
**New Token…** (a new token disconnects every agent until it is connected again).

The short way, from Terminal — it asks for the token, so Copy it first:

```bash
m1k3 login && m1k3 connect claude
```

(`m1k3` is on your PATH from the Homebrew cask; from the DMG it is
`/Applications/M1K3.app/Contents/Helpers/m1k3`.)

`m1k3 login` reads the token from the terminal with echo off (or a pipe:
`pbpaste | m1k3 login`), never from the command line, and keeps it in your login
keychain. `connect` then writes it into the client's config. For Claude Code
that means running `claude mcp add … --header`, so the token sits in that
process's arguments for the moment it runs — visible to your own user's
processes, which is inside what the token doesn't claim to defend (below).

**Claude Code by hand** (Settings' Copy button fills the token in):

```bash
claude mcp add --transport http -s user m1k3 http://127.0.0.1:4242/mcp \
  --header "Authorization: Bearer m1k3_…"
```

The JSON clients take a `headers` entry (`"type": "http"` matters to Claude
Code — a bare `"url"` key is silently rejected). Prefer the user scope: a
project `.mcp.json` entry shadows the user one, so after **New Token…** a stale
project entry 401s while the user entry works:

```json
{
  "mcpServers": {
    "m1k3": {
      "type": "http",
      "url": "http://127.0.0.1:4242/mcp",
      "headers": { "Authorization": "Bearer m1k3_…" }
    }
  }
}
```

A request without the token is answered **401** before it can reach a session.
What the token is for: stray scripts and callers that find the port open, and
knocking the connected agent off. It is not a defence against malware running
as you, which can read any client's config file — the per-tool switches
(listening, deleting memories, opening links) cover that for every caller.

When the app is closed the server is down — clients report the connection as
failed. That's benign; launch M1K3 and reconnect.

Notes for agents: `ask_m1k3` is submit-and-poll — ~8s inline grace, then a
`job_id` you poll via `get_answer`. Since 2026-08-19 a slow turn is never
cancelled on your behalf: the generation runs to completion (600s runaway
backstop, matching the job store's retention) and the answer stays redeemable
for ~10 minutes. Lost the id? `list_jobs` lists recent jobs (ids/state/age,
no answer text). Asking while a job runs returns a busy note naming that job
— nothing is queued. While the selected brain is still downloading, asks are
served by Mini (the answer says so) instead of erroring "still loading".
`speak wait:true` returns after playback or after ~25s with a still-speaking
note (playback continues — poll `get_status`).

## 2. The stdio fallback (knowledge-only)

### Build the release binary

```bash
cd ~/Development/m1k3/macos
swift build -c release --product M1K3MCP
# → .build/release/M1K3MCP
```

### Point it at M1K3's data

The app is App-Sandboxed, so it writes inside its container. The server reads
that path by default, but it's worth setting explicitly:

```
M1K3_STORE_PATH=~/Library/Containers/app.m1k3/Data/Library/Application Support/M1K3/knowledge.sqlite
```

(If you haven't launched the app yet, the store won't exist — the server falls
back to `~/Library/Application Support/M1K3/knowledge.sqlite`. Run the app and
ingest something first so there's knowledge to serve.)

### Register with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "m1k3": {
      "command": "$M1K3_ROOT/macos/.build/release/M1K3MCP",
      "env": {
        "M1K3_STORE_PATH": "$HOME/Library/Containers/app.m1k3/Data/Library/Application Support/M1K3/knowledge.sqlite"
      }
    }
  }
}
```

Restart Claude Desktop. You should see `search_knowledge` / `list_documents` /
`get_document` available, scoped to M1K3's store.

### Verify by hand

The stdio server speaks newline-delimited JSON-RPC. Smoke test (note: keep
stdin open — the server tears down on EOF before async handlers reply):

```bash
( printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'; sleep 3 ) \
  | .build/release/M1K3MCP
```

You should see `serverInfo` + the three tool definitions.

The HTTP surface can be smoke-tested the same way with `curl` against
`http://127.0.0.1:4242/mcp` (stateless — each POST carries one JSON-RPC call),
with the token on every request:

```bash
curl -s http://127.0.0.1:4242/mcp \
  -H "Authorization: Bearer m1k3_…" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

Without the header the answer is 401.

---
*Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown*
*Review: claude-fable-5, 2026-08-03 — restructured HTTP-first. The original doc
described only the stdio binary; by July the in-app HTTP server (15 tools,
127.0.0.1:4242) had become the primary surface and both READMEs pointed here
for it. Original stdio instructions preserved verbatim as the fallback path.
Confidence 0.9.*
*Review: claude-opus-5-5, 2026-10-02 — truth-up before the MCP directory
listings: the HTTP server has 18 tools (counted from the M1K3MCPKit
registrations: Intelligence 4, Voice 4, Memory 4, knowledge 3, Todo 2,
open_link 1), not 15; the curl smoke test now shows the Authorization header
#448 made mandatory. Confidence 0.85 (the tokenless call was checked against
the running app: 401; the tokened curl was not run, to keep the token out of
argv here).*
