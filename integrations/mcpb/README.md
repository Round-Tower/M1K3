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

- **macOS only**, and only while the M1K3 app is running. If it is not (or no
  token is set yet), the bridge still answers the handshake and lists M1K3's tools
  from `server/tools.json`, so your client shows them; each call answers with a
  sentence saying what is missing. Once M1K3 answers, the bridge introduces your
  client to it and relays from then on. (A client introduced this way keeps the
  bridge's short instructions, not the app's longer ones, until it reconnects.)
- **One client at a time.** M1K3 serves one connected MCP client; a second one
  connecting ends the first one's session.
- The tools are M1K3's own (19 today). `server/tools.json` is generated from the
  app's Swift kit, and CI fails when it drifts (`MCPToolCatalogTests`); regenerate
  it with `M1K3_WRITE_TOOL_CATALOG=1 macos/tools/dev/tdd.sh M1K3MCPKitTests MCPToolCatalogTests`.

## Build and test

```sh
node --test integrations/mcpb/test/bridge.test.js integrations/mcpb/test/manifest.test.js integrations/mcpb/test/claude-plugin.test.js
integrations/mcpb/build.sh        # writes dist/m1k3.mcpb and prints its SHA-256
```

A bundle is a zip of `manifest.json`, `icon.png` (the site's icon, copied in by the
build), `server/index.js` and `server/tools.json`.

### In Docker (for directories)

Glama grades an MCP server by starting it in Docker and asking for its tools.
`Dockerfile` here does that for the bridge, from the repository root:

```sh
docker build -f integrations/mcpb/Dockerfile -t m1k3-bridge .
docker run -i --rm m1k3-bridge
```

There is no M1K3 inside a container, so the image only ever lists the tools and
answers each call with "open M1K3". It is for introspection, not a way to run M1K3.

The Claude Code plugin in `integrations/claude-plugin` does not carry the
bridge: Claude Code speaks HTTP, so the plugin is one loopback server entry.
Its test lives here (`test/claude-plugin.test.js`), outside the plugin's folder,
because the directory reads every file a plugin ships.

## Publishing

`server.json` is the listing on the [MCP Registry](https://registry.modelcontextprotocol.io),
where M1K3 is `app.m1k3/m1k3`: a namespace proven by a DNS record on `m1k3.app`.
A new version takes two steps:

1. The **MCP Registry** workflow (run by hand, a dry run unless `publish` is
   ticked) tests and builds the bundle and creates the `mcpb-v<version>` release
   that carries it. A run that fails after the release reuses that release's
   bundle when run again.
2. `integrations/mcpb/publish-listing.sh` on Kev's Mac takes the SHA-256 of the
   released bundle, writes it into the listing and validates it; `--confirm` logs
   in with the DNS signing key and publishes. The key never goes to CI.

A published version cannot be changed. For a new bundle, bump `version` in
`manifest.json` and the package's `version` and `identifier` in `server.json`
together (a test holds them equal), and bump the listing's own `version`, which
runs ahead of the bundle's because the listing began as a pointer at 1.0.0.

The first real run (2026-11-15) also published `io.github.Round-Tower/m1k3`, a
duplicate. It is marked deprecated with a pointer to `app.m1k3/m1k3` (2026-11-16);
an entry cannot be removed. The repository's `mcp-registry` environment allows only
protected branches (`master`) and needs Kev's approval, so a real run waits at
"Review deployments".

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
_Review: Kev + claude-fable-5.2, 2026-11-16. Publishing rewritten: the listing is
`app.m1k3/m1k3` (Kev: "Domain please pal"), published from Kev's Mac; 1.1.0 went out
by hand on 2026-11-16 with the steps publish-listing.sh now holds. The script's
`--confirm` path and the workflow's retire job have not run._
_Review: Kev + claude-fable-5.2, 2026-11-16. The retire job ran (run 43870575453) and
the registry reads the duplicate as deprecated; the job is deleted. The script's
`--confirm` path has still not run._
_Review: Kev + claude-fable-5.2, 2026-11-16. Kev restricted the `mcp-registry`
environment (read back over the API); Publishing says so._
_Review: Kev + claude-opus-5.5, 2026-11-28. Bundle 0.2.0 (listing 1.2.0): the bridge
answers the handshake and the tool list from `server/tools.json` while M1K3 can't be
reached, and a Dockerfile lets Glama grade it (Kev: "Build it"). Confidence 0.8. Open:
0.2.0 is not released yet; the workflow run and `publish-listing.sh --confirm` are Kev's._
