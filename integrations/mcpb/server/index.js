#!/usr/bin/env node
// M1K3 bridge: lets an MCP client that launches a local command (Claude Desktop,
// Claude Code, any stdio client) talk to the M1K3 app running on this Mac.
//
// It speaks newline-delimited JSON-RPC on stdin/stdout and relays each message to
// M1K3's own MCP server on 127.0.0.1, with the access token from M1K3's Settings.
// It talks to this Mac only: the address is fixed to loopback, and nothing is sent
// anywhere else. It holds no state beyond the negotiated protocol version.
//
// Zero dependencies (Node 18+: global fetch), so the bundle is this one file.
//
// Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.75 (pinned by
// test/bridge.test.js against a fake server; tried against the live app by hand).
// Prior: Unknown.
// Review: Kev + claude-fable-5.2, 2026-11-12 (PR #823 bot pass): the body read is
// guarded like the dial (M1K3 quitting mid-answer crashed the bridge), a relay
// fault cannot poison the queue, redirects are refused, and a call ends after ten
// minutes. Open: a cancellation still queues behind the call it cancels.
// Context: Kev, 2026-11-12, on listing M1K3 for Claude users: "Let's go it pal".
// M1K3's full server lives inside the app behind a token; a listing needs
// something a client can launch.
// Review: Kev + claude-opus-5.5, 2026-11-28. While M1K3 can't be reached (closed, no
// token yet, or the token refused), the bridge answers initialize, tools/list and ping
// itself, from tools.json (pinned to the app's kit by MCPToolCatalogTests), so a client
// lists M1K3's tools before the app is open and Glama can introspect it in Docker.
// Calls still answer with what to do. When M1K3 answers later, the client's handshake
// is replayed once before the first relayed call. Confidence 0.8 (pinned by the
// bridge tests against fakes, and introspected in Docker: initialize, 19 tools, a call).
// Open: the replay has not met the live app (closed at start, opened mid-session).
// Context: Kev, 2026-11-28, on the awesome-mcp-servers listing, which needs a Glama
// quality grade: "Build it".
'use strict';

const path = require('node:path');
const fs = require('node:fs');

/** The bundle's version (manifest.json), named to clients that the bridge answers itself. */
const BRIDGE_VERSION = '0.2.0';

const DEFAULT_PORT = '4242';
// A local brain can take minutes over a long answer; ten is a hang, not an answer.
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;

const MESSAGES = {
  notRunning:
    "M1K3 isn't answering on this Mac. Open the M1K3 app and check that Settings > Server > MCP server is switched on, then try again.",
  noToken:
    'M1K3 needs its access token. In M1K3, open Settings > Server, copy the access token, and paste it into this extension\'s settings.',
  badToken:
    'M1K3 refused the access token. In M1K3, open Settings > Server, copy the access token again, and paste it into this extension\'s settings.',
  badPort: 'The M1K3 port must be a number between 1 and 65535.',
  timedOut: 'M1K3 took too long to answer, so this call was dropped. Check the M1K3 app and try again.',
  bridgeFault: 'The M1K3 bridge hit a fault relaying this call. Try again.',
  offline:
    "This is M1K3's tool list, answered by the bridge because it can't reach the M1K3 app on this Mac yet. "
    + 'To use the tools, open the M1K3 app, switch on Settings > Server > MCP server, and paste its access token '
    + "into this extension's settings. Until then, each call says what is missing.",
};

/** What the bridge answers by itself while M1K3 can't be reached. */
const LOCAL_METHODS = new Set(['initialize', 'tools/list', 'ping']);
const HANDSHAKE_ID = 'm1k3-bridge-handshake';
/** How long the handshake, the list and a replay wait for M1K3 before the bridge answers
 * them itself: well inside a client's own start-up deadline. */
const LOCAL_TIMEOUT_MS = 8 * 1000;
/** The MCP versions the bridge will echo when it answers a handshake itself. */
const KNOWN_PROTOCOL_VERSIONS = new Set(['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']);
const FALLBACK_PROTOCOL_VERSION = '2025-06-18';

let catalogCache = null;
/** M1K3's tools as the app declares them (tools.json, generated from the Swift kit). */
function catalog() {
  if (!catalogCache) catalogCache = JSON.parse(fs.readFileSync(path.join(__dirname, 'tools.json'), 'utf8'));
  return catalogCache;
}

/** The token as configured; a placeholder the host never filled in counts as none. */
function readToken(env) {
  const raw = (env.M1K3_MCP_TOKEN || '').trim();
  return raw.startsWith('${') ? '' : raw;
}

/** The loopback endpoint. Only the port can change, and only to a real port number. */
function endpoint(env) {
  const raw = (env.M1K3_MCP_PORT || '').trim();
  const port = raw === '' || raw.startsWith('${') ? DEFAULT_PORT : raw;
  if (!/^\d{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535) return null;
  return `http://127.0.0.1:${port}/mcp`;
}

function errorFor(id, message) {
  return { jsonrpc: '2.0', id, error: { code: -32000, message } };
}

/** The JSON-RPC messages inside a text/event-stream body. */
function parseEventStream(text) {
  const out = [];
  for (const block of text.split(/\r?\n\r?\n/)) {
    const data = block
      .split(/\r?\n/)
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).replace(/^ /, ''))
      .join('\n');
    if (data.trim() === '') continue;
    try {
      out.push(JSON.parse(data));
    } catch {
      // A malformed event is dropped; the caller answers the request with an error.
    }
  }
  return out;
}

/** The bridge's own answer to a LOCAL_METHODS request; `reason` is why M1K3 didn't answer. */
function answerLocally(message, reason) {
  const reply = (result) => ({ jsonrpc: '2.0', id: message.id, result });
  if (message.method === 'tools/list') return reply({ tools: catalog() });
  if (message.method === 'ping') return reply({});
  const params = message.params || {};
  return reply({
    protocolVersion: KNOWN_PROTOCOL_VERSIONS.has(params.protocolVersion) ? params.protocolVersion : FALLBACK_PROTOCOL_VERSION,
    capabilities: { tools: {} },
    serverInfo: { name: 'm1k3', title: 'M1K3', version: BRIDGE_VERSION },
    instructions: `${MESSAGES.offline} Right now: ${reason}`,
  });
}

/**
 * Relay one parsed message. Returns the messages to write back (possibly none).
 * `state.protocolVersion` is filled from M1K3's initialize result and sent thereafter.
 * `state.pendingHandshake` holds the client's initialize params while the bridge
 * answered it alone; it is replayed to M1K3 before the first message M1K3 answers.
 * The bridge answers alone only when M1K3 is out of reach (no token, nothing listening,
 * no answer in time, the token refused); an M1K3 that answers with an error says so.
 */
async function relay(message, deps) {
  const { state } = deps;
  const id = message && Object.prototype.hasOwnProperty.call(message, 'id') ? message.id : undefined;
  const wantsReply = id !== undefined && id !== null && typeof message.method === 'string';
  const method = message && message.method;

  if (method === 'initialize') state.pendingHandshake = null;
  if (state.pendingHandshake) {
    // The replay sends its own `initialized`; the client's one is spent on the bridge.
    if (method === 'notifications/initialized') return [];
    await replayHandshake(deps);
  }

  const local = wantsReply && LOCAL_METHODS.has(method);
  const { ok, replies, unreachable, reason } = await forward(message, local ? shortWait(deps) : deps);
  if (ok || !local || !unreachable) return replies;
  if (method === 'initialize') state.pendingHandshake = message.params || {};
  return [answerLocally(message, reason)];
}

function shortWait(deps) {
  const cap = deps.localTimeoutMs ?? LOCAL_TIMEOUT_MS;
  return { ...deps, timeoutMs: Math.min(deps.timeoutMs ?? DEFAULT_TIMEOUT_MS, cap) };
}

/** Introduce the client to M1K3, now that it answers. A failure leaves it pending. */
async function replayHandshake(deps) {
  const init = { jsonrpc: '2.0', id: HANDSHAKE_ID, method: 'initialize', params: deps.state.pendingHandshake };
  const { ok, replies } = await forward(init, shortWait(deps));
  if (!ok || !replies.some((r) => r && r.id === HANDSHAKE_ID && r.result)) return;
  const { ok: sent } = await forward({ jsonrpc: '2.0', method: 'notifications/initialized' }, shortWait(deps));
  if (sent) deps.state.pendingHandshake = null;
}

/**
 * Send one message to M1K3. `ok` is false when it failed; `unreachable` says M1K3 was out of
 * reach (as opposed to answering with an error), and `reason` is the sentence for the user.
 */
async function forward(message, { env, fetchImpl, state, timeoutMs = DEFAULT_TIMEOUT_MS }) {
  const id = message && Object.prototype.hasOwnProperty.call(message, 'id') ? message.id : undefined;
  const wantsReply = id !== undefined && id !== null && typeof message.method === 'string';
  const failWith = (unreachable) => (text) => ({ ok: false, unreachable, reason: text, replies: wantsReply ? [errorFor(id, text)] : [] });
  const outOfReach = failWith(true);
  const fail = failWith(false);
  const done = (replies) => ({ ok: true, replies });

  const url = endpoint(env);
  if (!url) return outOfReach(MESSAGES.badPort);
  const token = readToken(env);
  if (!token) return outOfReach(MESSAGES.noToken);

  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${token}`,
  };
  if (state.protocolVersion) headers['MCP-Protocol-Version'] = state.protocolVersion;

  // The body read sits inside the same guard as the dial: M1K3 quitting mid-answer
  // rejects there, not at fetch. A redirect is an error, so the token stays on loopback.
  let response;
  let body = '';
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(message),
      redirect: 'error',
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (response.status === 401) return outOfReach(MESSAGES.badToken);
    if (response.status === 202 || response.status === 204) return done([]);
    body = await response.text();
  } catch (error) {
    return outOfReach(error && error.name === 'TimeoutError' ? MESSAGES.timedOut : MESSAGES.notRunning);
  }
  if (!response.ok) {
    return fail(`M1K3 answered with an error (HTTP ${response.status}).`);
  }

  const type = (response.headers.get('content-type') || '').toLowerCase();
  let replies;
  if (type.includes('text/event-stream')) {
    replies = parseEventStream(body);
  } else if (body.trim() === '') {
    replies = [];
  } else {
    try {
      const parsed = JSON.parse(body);
      replies = Array.isArray(parsed) ? parsed : [parsed];
    } catch {
      return fail('M1K3 sent an answer this bridge could not read.');
    }
  }
  if (wantsReply && replies.length === 0) return fail('M1K3 sent no answer.');

  if (message.method === 'initialize') {
    const version = replies.find((r) => r && r.result && r.result.protocolVersion);
    if (version) state.protocolVersion = String(version.result.protocolVersion);
  }
  return done(replies);
}

/** Read lines from `input`, relay each in order, write replies to `output`. */
function serve({ input, output, env, fetchImpl }) {
  const state = { protocolVersion: null, pendingHandshake: null };
  let buffer = '';
  let chain = Promise.resolve();

  const handle = (line) => {
    const text = line.trim();
    if (text === '') return;
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      output.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }) + '\n');
      return;
    }
    // One at a time, in order: M1K3 serves one request per connection.
    // A fault in one relay answers that request and never poisons the queue.
    chain = chain.then(async () => {
      let replies;
      try {
        replies = await relay(message, { env, fetchImpl, state });
      } catch {
        const id = message && typeof message === 'object' ? message.id : undefined;
        replies = id === undefined || id === null ? [] : [errorFor(id, MESSAGES.bridgeFault)];
      }
      for (const reply of replies) output.write(JSON.stringify(reply) + '\n');
    });
  };

  input.setEncoding('utf8');
  input.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      handle(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
    }
  });
  return new Promise((resolve) => {
    input.on('end', () => {
      if (buffer.trim() !== '') handle(buffer);
      chain.then(resolve);
    });
  });
}

module.exports = { BRIDGE_VERSION, MESSAGES, catalog, readToken, endpoint, parseEventStream, relay, serve };

if (require.main === module) {
  serve({ input: process.stdin, output: process.stdout, env: process.env, fetchImpl: fetch }).then(() => process.exit(0));
}
