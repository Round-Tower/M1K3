// The Claude plugin must carry the same bridge as the MCP Bundle, ask for the
// token as a secret, and say what it runs and sends.
// Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: none (new file).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const repo = path.join(root, '..', '..');
const read = (...parts) => fs.readFileSync(path.join(...parts), 'utf8');
const plugin = JSON.parse(read(root, '.claude-plugin', 'plugin.json'));
const mcp = JSON.parse(read(root, '.mcp.json'));
const bundle = JSON.parse(read(repo, 'integrations', 'mcpb', 'manifest.json'));

test('the bridge is the bundle\'s bridge, byte for byte', () => {
  assert.equal(read(root, 'server', 'index.js'), read(repo, 'integrations', 'mcpb', 'server', 'index.js'));
});

test('the manifest names the plugin, its licence and where its policy and help live', () => {
  assert.equal(plugin.name, 'm1k3');
  assert.equal(plugin.version, bundle.version);
  assert.equal(plugin.license, bundle.license);
  assert.ok(plugin.description.length > 20);
  assert.ok(plugin.author.name);
  assert.equal(plugin.privacyPolicyUrl, 'https://m1k3.app/privacy');
  assert.match(plugin.supportUrl, /^https:\/\/github\.com\/Round-Tower\/M1K3\/issues/);
});

test('the token is asked for as a secret; the port has a default so nothing else is asked', () => {
  const { access_token: token, port } = plugin.userConfig;
  assert.deepEqual([token.type, token.sensitive, token.required], ['string', true, true]);
  assert.ok(token.title && token.description);
  assert.deepEqual([port.type, port.default], ['string', '4242']);
  assert.notEqual(port.sensitive, true);
});

test('the server is started with plain node from the plugin\'s own folder, with the env the bridge reads', () => {
  assert.deepEqual(Object.keys(mcp.mcpServers), ['m1k3']);
  const server = mcp.mcpServers.m1k3;
  assert.equal(server.command, 'node');
  assert.deepEqual(server.args, ['${CLAUDE_PLUGIN_ROOT}/server/index.js']);
  assert.deepEqual(server.env, { M1K3_MCP_TOKEN: '${user_config.access_token}', M1K3_MCP_PORT: '${user_config.port}' });
  const source = read(root, 'server', 'index.js');
  for (const name of Object.keys(server.env)) assert.ok(source.includes(`env.${name}`), name);
  assert.equal(plugin.mcpServers, undefined, 'one place for the server: .mcp.json');
});

test('the README says what the plugin runs and sends, and carries a privacy policy', () => {
  const readme = read(root, 'README.md');
  assert.ok(readme.split(/\s+/).length >= 40);
  for (const phrase of ['127.0.0.1', 'becomes part of your conversation with Claude', '## Privacy Policy', 'https://m1k3.app/privacy', 'one client at a time']) {
    assert.ok(readme.includes(phrase), phrase);
  }
});

test('the repository is its own marketplace, and its entry points at this folder', () => {
  const market = JSON.parse(read(repo, '.claude-plugin', 'marketplace.json'));
  assert.ok(market.name && market.owner.name);
  assert.deepEqual(market.plugins.map((p) => [p.name, p.source]), [['m1k3', './integrations/claude-plugin']]);
});

test('the icon is the one on the site, so the listing and the site show one fox', () => {
  const icon = fs.readFileSync(path.join(root, '.claude-plugin', 'icon.png'));
  assert.ok(icon.equals(fs.readFileSync(path.join(repo, 'site', 'icon-512.png'))));
});
