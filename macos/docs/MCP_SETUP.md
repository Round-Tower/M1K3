# Wiring M1K3 into Claude (MCP)

M1K3 exposes MCP on **two surfaces**:

1. **The in-app HTTP server** — the live, full-capability surface. 15 tools
   (knowledge search, documents, voice, listening, memory graph, `ask_m1k3`,
   `remember`, …) served at `http://127.0.0.1:4242/mcp` while the app runs.
   **This is the way to connect.**
2. **The `M1K3MCP` stdio binary** — a knowledge-only fallback (3 tools:
   `search_knowledge`, `list_documents`, `get_document`) that reads the app's
   store directly, for clients that can't speak HTTP or when the app is closed.

## 1. Connect to the app (HTTP — recommended)

Turn the server on in the app: **Settings → Privacy → MCP server**. Then:

**Claude Code (CLI):**

```bash
claude mcp add --transport http m1k3 http://127.0.0.1:4242/mcp
```

Or per-project via `.mcp.json` (note `"type": "http"` — a bare `"url"` key is
silently rejected):

```json
{
  "mcpServers": {
    "m1k3": { "type": "http", "url": "http://127.0.0.1:4242/mcp" }
  }
}
```

When the app is closed the server is down — clients report the connection as
failed. That's benign; launch M1K3 and reconnect.

Notes for agents: `ask_m1k3` is submit-and-poll — ~8s inline grace, then a
`job_id` you poll via `get_answer` (~120s server-side deadline). Long thinking
turns can blow that cap; test those in-app instead.

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
`http://127.0.0.1:4242/mcp` (stateless — each POST carries one JSON-RPC call).

---
*Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown*
*Review: claude-fable-5, 2026-08-03 — restructured HTTP-first. The original doc
described only the stdio binary; by July the in-app HTTP server (15 tools,
127.0.0.1:4242) had become the primary surface and both READMEs pointed here
for it. Original stdio instructions preserved verbatim as the fallback path.
Confidence 0.9.*
