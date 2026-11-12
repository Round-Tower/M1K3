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
// Context: Kev, 2026-11-12, on listing M1K3 for Claude users: "Let's go it pal".
// M1K3's full server lives inside the app behind a token; a listing needs
// something a client can launch.
'use strict';

const DEFAULT_PORT = '4242';

const MESSAGES = {
  notRunning:
    "M1K3 isn't answering on this Mac. Open the M1K3 app and check that Settings > Server > MCP server is switched on, then try again.",
  noToken:
    'M1K3 needs its access token. In M1K3, open Settings > Server, copy the access token, and paste it into this extension\'s settings.',
  badToken:
    'M1K3 refused the access token. In M1K3, open Settings > Server, copy the access token again, and paste it into this extension\'s settings.',
  badPort: 'The M1K3 port must be a number between 1 and 65535.',
};

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

/**
 * Relay one parsed message. Returns the messages to write back (possibly none).
 * `state.protocolVersion` is filled from the initialize result and sent thereafter.
 */
async function relay(message, { env, fetchImpl, state }) {
  const id = message && Object.prototype.hasOwnProperty.call(message, 'id') ? message.id : undefined;
  const wantsReply = id !== undefined && id !== null && typeof message.method === 'string';
  const fail = (text) => (wantsReply ? [errorFor(id, text)] : []);

  const url = endpoint(env);
  if (!url) return fail(MESSAGES.badPort);
  const token = readToken(env);
  if (!token) return fail(MESSAGES.noToken);

  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${token}`,
  };
  if (state.protocolVersion) headers['MCP-Protocol-Version'] = state.protocolVersion;

  let response;
  try {
    response = await fetchImpl(url, { method: 'POST', headers, body: JSON.stringify(message) });
  } catch {
    return fail(MESSAGES.notRunning);
  }

  if (response.status === 401) return fail(MESSAGES.badToken);
  if (response.status === 202 || response.status === 204) return [];
  const body = await response.text();
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
  return replies;
}

/** Read lines from `input`, relay each in order, write replies to `output`. */
function serve({ input, output, env, fetchImpl }) {
  const state = { protocolVersion: null };
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
    chain = chain.then(async () => {
      const replies = await relay(message, { env, fetchImpl, state });
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

module.exports = { MESSAGES, readToken, endpoint, parseEventStream, relay, serve };

if (require.main === module) {
  serve({ input: process.stdin, output: process.stdout, env: process.env, fetchImpl: fetch }).then(() => process.exit(0));
}
