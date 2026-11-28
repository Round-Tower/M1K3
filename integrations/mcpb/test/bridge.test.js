// node --test integrations/mcpb/test
// Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85. Prior: Unknown.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { PassThrough } = require('node:stream');
const { MESSAGES, readToken, endpoint, parseEventStream, relay, serve } = require('../server/index.js');

/** A fake M1K3: records what it was sent, answers from `answer(request, body)`. */
function fakeM1K3(answer) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      seen.push({ url: req.url, method: req.method, headers: req.headers, body: body ? JSON.parse(body) : null });
      const { status = 200, type = 'application/json', text = '' } = answer(req, body ? JSON.parse(body) : null);
      res.writeHead(status, { 'Content-Type': type });
      res.end(text);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, seen, port: String(server.address().port) }));
  });
}

const call = (id, method, params = {}) => ({ jsonrpc: '2.0', id, method, params });

test('the endpoint is loopback, port 4242 unless a real port number is given', () => {
  assert.equal(endpoint({}), 'http://127.0.0.1:4242/mcp');
  assert.equal(endpoint({ M1K3_MCP_PORT: '5000' }), 'http://127.0.0.1:5000/mcp');
  assert.equal(endpoint({ M1K3_MCP_PORT: '${user_config.port}' }), 'http://127.0.0.1:4242/mcp');
  for (const bad of ['evil.example:80', '0', '70000', '42a', '-1', '4242/x@evil']) {
    assert.equal(endpoint({ M1K3_MCP_PORT: bad }), null, bad);
  }
});

test('a token the host never filled in counts as no token', () => {
  assert.equal(readToken({}), '');
  assert.equal(readToken({ M1K3_MCP_TOKEN: '${user_config.access_token}' }), '');
  assert.equal(readToken({ M1K3_MCP_TOKEN: '  abc  ' }), 'abc');
});

test('a request is posted to /mcp with the bearer token, and its answer comes back', async () => {
  const m1k3 = await fakeM1K3((_, body) => ({ text: JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { ok: true } }) }));
  try {
    const state = { protocolVersion: null };
    const env = { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port };
    const replies = await relay(call(7, 'tools/list'), { env, fetchImpl: fetch, state });
    assert.deepEqual(replies, [{ jsonrpc: '2.0', id: 7, result: { ok: true } }]);
    assert.equal(m1k3.seen[0].url, '/mcp');
    assert.equal(m1k3.seen[0].method, 'POST');
    assert.equal(m1k3.seen[0].headers.authorization, 'Bearer tok');
    assert.equal(m1k3.seen[0].headers.origin, undefined, 'no Origin: M1K3 refuses a foreign one');
    assert.match(m1k3.seen[0].headers.accept, /application\/json/);
  } finally {
    m1k3.server.close();
  }
});

test('the protocol version from initialize rides every later request', async () => {
  const m1k3 = await fakeM1K3((_, body) => ({
    text: JSON.stringify({ jsonrpc: '2.0', id: body.id, result: body.method === 'initialize' ? { protocolVersion: '2025-06-18' } : {} }),
  }));
  try {
    const state = { protocolVersion: null };
    const deps = { env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port }, fetchImpl: fetch, state };
    await relay(call(1, 'initialize'), deps);
    await relay(call(2, 'tools/list'), deps);
    assert.equal(m1k3.seen[0].headers['mcp-protocol-version'], undefined);
    assert.equal(m1k3.seen[1].headers['mcp-protocol-version'], '2025-06-18');
  } finally {
    m1k3.server.close();
  }
});

test('a notification (202, no body) writes nothing back', async () => {
  const m1k3 = await fakeM1K3(() => ({ status: 202 }));
  try {
    const deps = { env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port }, fetchImpl: fetch, state: {} };
    assert.deepEqual(await relay({ jsonrpc: '2.0', method: 'notifications/initialized' }, deps), []);
  } finally {
    m1k3.server.close();
  }
});

test('an event-stream answer is unwrapped into its messages', async () => {
  const event = (o) => `event: message\ndata: ${JSON.stringify(o)}\n\n`;
  assert.deepEqual(parseEventStream(event({ a: 1 }) + ': comment\n\n' + event({ b: 2 })), [{ a: 1 }, { b: 2 }]);
  const m1k3 = await fakeM1K3((_, body) => ({ type: 'text/event-stream', text: event({ jsonrpc: '2.0', id: body.id, result: {} }) }));
  try {
    const deps = { env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port }, fetchImpl: fetch, state: {} };
    assert.deepEqual(await relay(call(3, 'ping'), deps), [{ jsonrpc: '2.0', id: 3, result: {} }]);
  } finally {
    m1k3.server.close();
  }
});

test('M1K3 not running: the request gets a plain sentence, a notification gets silence', async () => {
  const refuse = async () => {
    throw new TypeError('fetch failed');
  };
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: refuse, state: {} };
  const [reply] = await relay(call(9, 'tools/call'), deps);
  assert.equal(reply.id, 9);
  assert.equal(reply.error.message, MESSAGES.notRunning);
  assert.deepEqual(await relay({ jsonrpc: '2.0', method: 'notifications/initialized' }, deps), []);
});

test('no token, a refused token and a bad port each say what to do, and never dial out', async () => {
  let dialled = 0;
  const count = async () => {
    dialled += 1;
    return new Response('', { status: 401 });
  };
  const none = await relay(call(1, 'tools/call'), { env: {}, fetchImpl: count, state: {} });
  assert.equal(none[0].error.message, MESSAGES.noToken);
  const port = await relay(call(1, 'tools/call'), { env: { M1K3_MCP_TOKEN: 't', M1K3_MCP_PORT: 'evil.example' }, fetchImpl: count, state: {} });
  assert.equal(port[0].error.message, MESSAGES.badPort);
  assert.equal(dialled, 0);
  const refused = await relay(call(1, 'tools/call'), { env: { M1K3_MCP_TOKEN: 'wrong' }, fetchImpl: count, state: {} });
  assert.equal(refused[0].error.message, MESSAGES.badToken);
  assert.ok(!JSON.stringify(refused).includes('wrong'), 'the token is never echoed');
});

test('an HTTP error or an unreadable body becomes an error reply, not a hang', async () => {
  const m1k3 = await fakeM1K3((_, body) => (body.method === 'a' ? { status: 500, text: 'boom' } : { text: 'not json' }));
  try {
    const deps = { env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port }, fetchImpl: fetch, state: {} };
    assert.match((await relay(call(1, 'a'), deps))[0].error.message, /HTTP 500/);
    assert.match((await relay(call(2, 'b'), deps))[0].error.message, /could not read/);
  } finally {
    m1k3.server.close();
  }
});

test('serve: lines in, replies out in order, a broken line answered as a parse error', async () => {
  const m1k3 = await fakeM1K3((_, body) => ({ text: JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { method: body.method } }) }));
  try {
    const input = new PassThrough();
    const output = new PassThrough();
    let written = '';
    output.on('data', (c) => (written += c));
    const done = serve({ input, output, env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port }, fetchImpl: fetch });
    input.write(JSON.stringify(call(1, 'first')) + '\n{not json}\n' + JSON.stringify(call(2, 'second')));
    input.end('\n');
    await done;
    const lines = written.trim().split('\n').map((l) => JSON.parse(l));
    assert.equal(lines.length, 3);
    assert.equal(lines.find((l) => l.error).error.code, -32700);
    const results = lines.filter((l) => l.result).map((l) => l.result.method);
    assert.deepEqual(results, ['first', 'second']);
  } finally {
    m1k3.server.close();
  }
});

test('M1K3 quitting mid-answer: that request gets the plain sentence and the next one is still served', async () => {
  let calls = 0;
  const dropsFirst = async () => {
    calls += 1;
    if (calls === 1) {
      return { status: 200, ok: true, headers: new Headers(), text: async () => { throw new TypeError('terminated'); } };
    }
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: 2, result: { ok: true } }), { headers: { 'Content-Type': 'application/json' } });
  };
  const input = new PassThrough();
  const output = new PassThrough();
  let written = '';
  output.on('data', (c) => (written += c));
  const done = serve({ input, output, env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: dropsFirst });
  input.end(JSON.stringify(call(1, 'tools/call')) + '\n' + JSON.stringify(call(2, 'tools/list')) + '\n');
  await done;
  const lines = written.trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(lines[0].id, 1);
  assert.equal(lines[0].error.message, MESSAGES.notRunning);
  assert.deepEqual(lines[1].result, { ok: true });
});

test('serve: a relay that throws still answers the request and keeps the queue alive', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  let written = '';
  output.on('data', (c) => (written += c));
  // A response object with no `headers` makes relay itself throw after the body read.
  const broken = async () => ({ status: 200, ok: true, text: async () => '{}' });
  const done = serve({ input, output, env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: broken });
  input.end(JSON.stringify(call(1, 'a')) + '\n' + JSON.stringify(call(2, 'b')) + '\n');
  await done;
  const lines = written.trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(lines.map((l) => l.id), [1, 2]);
  assert.ok(lines.every((l) => l.error));
});

test('a redirect is refused, so the token cannot follow one off this Mac', async () => {
  const m1k3 = await fakeM1K3(() => ({ status: 307, text: '' }));
  m1k3.server.removeAllListeners('request');
  m1k3.server.on('request', (req, res) => {
    m1k3.seen.push(req.url);
    // Back to this same server: a followed redirect would show up in `seen`.
    res.writeHead(req.url === '/mcp' ? 307 : 200, { Location: '/elsewhere', 'Content-Type': 'application/json' });
    res.end(req.url === '/mcp' ? '' : '{"jsonrpc":"2.0","id":1,"result":{}}');
  });
  try {
    const deps = { env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: m1k3.port }, fetchImpl: fetch, state: {} };
    const [reply] = await relay(call(1, 'tools/call'), deps);
    assert.equal(reply.error.message, MESSAGES.notRunning);
    assert.deepEqual(m1k3.seen, ['/mcp']);
  } finally {
    m1k3.server.close();
  }
});

test('a call M1K3 never answers ends with a plain sentence instead of blocking the queue for ever', async () => {
  const sockets = new Set();
  const silent = http.createServer(() => {});
  silent.on('connection', (s) => sockets.add(s));
  await new Promise((resolve) => silent.listen(0, '127.0.0.1', resolve));
  try {
    const deps = { env: { M1K3_MCP_TOKEN: 'tok', M1K3_MCP_PORT: String(silent.address().port) }, fetchImpl: fetch, state: {}, timeoutMs: 100 };
    const [reply] = await relay(call(1, 'tools/call'), deps);
    assert.equal(reply.error.message, MESSAGES.timedOut);
  } finally {
    for (const s of sockets) s.destroy();
    silent.close();
  }
});

// --- While M1K3 can't be reached: the bridge answers the handshake and the tool list
// itself, from server/tools.json (pinned to the app's kit by MCPToolCatalogTests), so a
// client sees M1K3's tools before the app is open and Glama can introspect the bridge
// in Docker. Calls still say what to do. Kev, 2026-11-28: "Build it".

const { BRIDGE_VERSION, catalog } = require('../server/index.js');
const refused = async () => {
  throw new TypeError('fetch failed');
};

test('no app: initialize is answered by the bridge, in the client\'s protocol version', async () => {
  const state = {};
  const params = { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'glama', version: '1' } };
  const [reply] = await relay(call(1, 'initialize', params), { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: refused, state });
  assert.equal(reply.id, 1);
  assert.equal(reply.result.protocolVersion, '2025-06-18');
  assert.deepEqual(reply.result.capabilities, { tools: {} });
  assert.deepEqual(reply.result.serverInfo, { name: 'm1k3', title: 'M1K3', version: BRIDGE_VERSION });
  assert.match(reply.result.instructions, /open the M1K3 app/i);
  assert.deepEqual(state.pendingHandshake, params, 'kept, to replay to M1K3 once it answers');
});

test('no app: tools/list is the catalog, and ping is answered', async () => {
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: refused, state: {} };
  const [list] = await relay(call(2, 'tools/list'), deps);
  assert.deepEqual(list.result, { tools: catalog() });
  assert.ok(catalog().length >= 19);
  assert.ok(catalog().every((t) => t.name && t.title && t.description && t.inputSchema.type === 'object'));
  const [pong] = await relay(call(3, 'ping'), deps);
  assert.deepEqual(pong, { jsonrpc: '2.0', id: 3, result: {} });
});

test('no token at all (Glama\'s Docker check): the handshake and the list work, and nothing dials out', async () => {
  let dialled = 0;
  const count = async () => {
    dialled += 1;
    throw new TypeError('unreachable');
  };
  const deps = { env: {}, fetchImpl: count, state: {} };
  assert.ok((await relay(call(1, 'initialize', { protocolVersion: '2025-06-18' }), deps))[0].result.serverInfo);
  assert.deepEqual(await relay({ jsonrpc: '2.0', method: 'notifications/initialized' }, deps), []);
  assert.equal((await relay(call(2, 'tools/list'), deps))[0].result.tools.length, catalog().length);
  assert.equal((await relay(call(3, 'tools/call', { name: 'get_status' }), deps))[0].error.message, MESSAGES.noToken);
  assert.equal(dialled, 0);
});

test('M1K3 opens later: the bridge replays the handshake once, then relays the call', async () => {
  let up = false;
  const sent = [];
  const fetchImpl = async (_, init) => {
    if (!up) throw new TypeError('fetch failed');
    const body = JSON.parse(init.body);
    sent.push({ method: body.method, version: init.headers['MCP-Protocol-Version'], params: body.params });
    if (body.id === undefined) return new Response(null, { status: 202 });
    const result = body.method === 'initialize' ? { protocolVersion: '2025-03-26', capabilities: { tools: {} } } : { ok: body.method };
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, result }), { headers: { 'Content-Type': 'application/json' } });
  };
  const state = {};
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl, state };
  await relay(call(1, 'initialize', { protocolVersion: '2025-06-18', clientInfo: { name: 'c' } }), deps);
  assert.deepEqual(await relay({ jsonrpc: '2.0', method: 'notifications/initialized' }, deps), [], 'held back for the replay');
  up = true;
  const [first] = await relay(call(2, 'tools/call', { name: 'get_status' }), deps);
  assert.deepEqual(first, { jsonrpc: '2.0', id: 2, result: { ok: 'tools/call' } });
  const [second] = await relay(call(3, 'tools/list'), deps);
  assert.deepEqual(second.result, { ok: 'tools/list' }, 'the live list, once M1K3 answers');
  assert.deepEqual(sent.map((s) => s.method), ['initialize', 'notifications/initialized', 'tools/call', 'tools/list']);
  assert.deepEqual(sent[0].params, { protocolVersion: '2025-06-18', clientInfo: { name: 'c' } }, 'the client\'s own handshake');
  assert.equal(sent[2].version, '2025-03-26', 'M1K3\'s own version rides the relayed calls');
  assert.equal(state.pendingHandshake, null);
});

test('M1K3 answers at the start: nothing is held back or replayed', async () => {
  const methods = [];
  const fetchImpl = async (_, init) => {
    const body = JSON.parse(init.body);
    methods.push(body.method);
    if (body.id === undefined) return new Response(null, { status: 202 });
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-06-18' } }), { headers: { 'Content-Type': 'application/json' } });
  };
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl, state: {} };
  await relay(call(1, 'initialize', { protocolVersion: '2025-06-18' }), deps);
  await relay({ jsonrpc: '2.0', method: 'notifications/initialized' }, deps);
  await relay(call(2, 'tools/call'), deps);
  assert.deepEqual(methods, ['initialize', 'notifications/initialized', 'tools/call']);
});

test('a refused token still lists the tools, and the handshake says why calls will fail', async () => {
  const deny = async () => new Response('', { status: 401 });
  const deps = { env: { M1K3_MCP_TOKEN: 'stale' }, fetchImpl: deny, state: {} };
  const [hello] = await relay(call(1, 'initialize', { protocolVersion: '2025-06-18' }), deps);
  assert.ok(hello.result.instructions.includes(MESSAGES.badToken));
  assert.equal((await relay(call(2, 'tools/list'), deps))[0].result.tools.length, catalog().length);
  assert.equal((await relay(call(3, 'tools/call'), deps))[0].error.message, MESSAGES.badToken);
});

test('M1K3 up but broken (HTTP 500): the list is an error, never the catalog', async () => {
  const broken = async () => new Response('boom', { status: 500 });
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: broken, state: {} };
  const [list] = await relay(call(1, 'tools/list'), deps);
  assert.match(list.error.message, /HTTP 500/);
  const [hello] = await relay(call(2, 'initialize', { protocolVersion: '2025-06-18' }), deps);
  assert.match(hello.error.message, /HTTP 500/);
  assert.equal(deps.state.pendingHandshake ?? null, null);
});

test('a protocol version the bridge does not know is answered with one it does', async () => {
  const deps = { env: {}, fetchImpl: refused, state: {} };
  const [hello] = await relay(call(1, 'initialize', { protocolVersion: '2099-01-01' }), deps);
  assert.equal(hello.result.protocolVersion, '2025-06-18');
});

test('a hung M1K3 cannot stall the handshake: the bridge answers once the short wait ends', async () => {
  // A real hung socket keeps Node's event loop alive; AbortSignal.timeout's timer does not,
  // so the fake holds a timer of its own until the abort (CI's Node ended the run without it).
  const hangs = (_, init) => new Promise((_, reject) => {
    const hold = setInterval(() => {}, 1000);
    init.signal.addEventListener('abort', () => {
      clearInterval(hold);
      reject(init.signal.reason);
    });
  });
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl: hangs, state: {}, timeoutMs: 600000, localTimeoutMs: 50 };
  const [hello] = await relay(call(1, 'initialize', { protocolVersion: '2025-06-18' }), deps);
  assert.ok(hello.result.instructions.includes(MESSAGES.timedOut));
  assert.equal((await relay(call(2, 'tools/list'), deps))[0].result.tools.length, catalog().length);
});

test('a replay M1K3 answers with an error stays pending and is tried again', async () => {
  let initErrors = 2;
  const methods = [];
  const fetchImpl = async (_, init) => {
    const body = JSON.parse(init.body);
    methods.push(body.method);
    if (body.id === undefined) return new Response(null, { status: 202 });
    if (body.method === 'initialize' && body.id === 1) throw new TypeError('fetch failed');
    if (body.method === 'initialize' && initErrors-- > 0) {
      return new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, error: { code: -32603, message: 'not yet' } }), { headers: { 'Content-Type': 'application/json' } });
    }
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-06-18' } }), { headers: { 'Content-Type': 'application/json' } });
  };
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl, state: {} };
  await relay(call(1, 'initialize', { protocolVersion: '2025-06-18' }), deps);
  const [refusedCall] = await relay(call(2, 'tools/call'), deps);
  assert.equal(refusedCall.error.message, MESSAGES.handshakeRefused, 'never sent to a session that was not introduced');
  assert.ok(deps.state.pendingHandshake, 'the refused replay is still owed');
  const [listed] = await relay(call(3, 'tools/list'), deps);
  assert.equal(listed.error.message, MESSAGES.handshakeRefused, 'M1K3 answered, so its refusal shows, not the catalog');
  await relay(call(4, 'tools/call'), deps);
  assert.equal(deps.state.pendingHandshake, null);
  assert.deepEqual(methods, ['initialize', 'initialize', 'initialize', 'initialize', 'notifications/initialized', 'tools/call']);
});

test('while M1K3 is out of reach, a failed replay is the only dial: the message is not sent again', async () => {
  let dials = 0;
  const fetchImpl = async () => {
    dials += 1;
    throw new TypeError('fetch failed');
  };
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl, state: {} };
  await relay(call(1, 'initialize', { protocolVersion: '2025-06-18' }), deps);
  dials = 0;
  assert.equal((await relay(call(2, 'tools/list'), deps))[0].result.tools.length, catalog().length);
  assert.equal((await relay(call(3, 'tools/call'), deps))[0].error.message, MESSAGES.notRunning);
  assert.equal(dials, 2, 'one replay attempt per message, nothing more');
});

test('a client that says initialize again is introduced directly, with no stale replay', async () => {
  let up = false;
  const methods = [];
  const fetchImpl = async (_, init) => {
    if (!up) throw new TypeError('fetch failed');
    const body = JSON.parse(init.body);
    methods.push([body.method, body.params && body.params.clientInfo && body.params.clientInfo.name]);
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-06-18' } }), { headers: { 'Content-Type': 'application/json' } });
  };
  const deps = { env: { M1K3_MCP_TOKEN: 'tok' }, fetchImpl, state: {} };
  await relay(call(1, 'initialize', { clientInfo: { name: 'old' } }), deps);
  up = true;
  await relay(call(2, 'initialize', { clientInfo: { name: 'new' } }), deps);
  assert.deepEqual(methods, [['initialize', 'new']]);
  assert.equal(deps.state.pendingHandshake, null);
});
