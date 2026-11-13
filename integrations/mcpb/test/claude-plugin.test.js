// The Claude plugin (integrations/claude-plugin) must carry no code at all: one
// loopback HTTP server entry, the token asked for as a secret and sent only in
// that entry's header, and a README that says what it sends.
// It lives here, not in the plugin's folder: the directory's validator reads
// every file a plugin ships, and a test file there put the listing on hold.
// Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: Unknown.
// Review: Kev + claude-fable-5.2, 2026-11-13 — the plugin dropped the Node bridge
// for a direct loopback HTTP entry (the directory holds a plugin that runs a
// script unless its organisation is Verified); the byte-equal bridge test went
// with it, and "nothing but these files" replaced it.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repo = path.join(__dirname, '..', '..', '..');
const root = path.join(repo, 'integrations', 'claude-plugin');
const read = (...parts) => fs.readFileSync(path.join(...parts), 'utf8');
const plugin = JSON.parse(read(root, '.claude-plugin', 'plugin.json'));
const mcp = JSON.parse(read(root, '.mcp.json'));
const bundle = JSON.parse(read(repo, 'integrations', 'mcpb', 'manifest.json'));

function filesUnder(dir, base = dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? filesUnder(full, base) : [path.relative(base, full)];
  }).sort();
}

test('the plugin ships four files and nothing that runs', () => {
  assert.deepEqual(filesUnder(root), ['.claude-plugin/icon.png', '.claude-plugin/plugin.json', '.mcp.json', 'README.md']);
});

test('the manifest names the plugin, its licence and where its policy and help live', () => {
  assert.equal(plugin.name, 'm1k3');
  assert.match(plugin.version, /^\d+\.\d+\.\d+$/);
  assert.equal(plugin.license, bundle.license);
  assert.ok(plugin.description.length > 20);
  assert.ok(plugin.author.name);
  assert.equal(plugin.privacyPolicyUrl, 'https://m1k3.app/privacy');
  assert.match(plugin.supportUrl, /^https:\/\/github\.com\/Round-Tower\/M1K3\/issues/);
});

test('the token is the only thing asked for, and it is asked for as a secret', () => {
  assert.deepEqual(Object.keys(plugin.userConfig), ['access_token']);
  const token = plugin.userConfig.access_token;
  assert.deepEqual([token.type, token.sensitive, token.required], ['string', true, true]);
  assert.ok(token.title && token.description);
});

test('the one server is M1K3 on loopback, and the token goes only in its header', () => {
  assert.deepEqual(Object.keys(mcp.mcpServers), ['m1k3']);
  assert.deepEqual(mcp.mcpServers.m1k3, {
    type: 'http',
    url: 'http://127.0.0.1:4242/mcp',
    headers: { Authorization: 'Bearer ${user_config.access_token}' },
  });
  assert.equal(plugin.mcpServers, undefined, 'one place for the server: .mcp.json');
  const everythingElse = read(root, '.claude-plugin', 'plugin.json') + read(root, 'README.md');
  assert.ok(!everythingElse.includes('${user_config'), 'the token is referenced nowhere else');
});

test('the README says what the plugin sends, and carries a privacy policy', () => {
  const readme = read(root, 'README.md');
  assert.ok(readme.split(/\s+/).length >= 40);
  for (const phrase of ['127.0.0.1:4242', 'becomes part of your conversation with Claude', '## Privacy Policy', 'https://m1k3.app/privacy', 'one client at a time']) {
    assert.ok(readme.includes(phrase), phrase);
  }
});

test('the repository is its own marketplace, and its entry points at the plugin folder', () => {
  const market = JSON.parse(read(repo, '.claude-plugin', 'marketplace.json'));
  assert.ok(market.name && market.owner.name);
  assert.deepEqual(market.plugins.map((p) => [p.name, p.source]), [['m1k3', './integrations/claude-plugin']]);
});

test('the icon is the one on the site, so the listing and the site show one fox', () => {
  const icon = fs.readFileSync(path.join(root, '.claude-plugin', 'icon.png'));
  assert.ok(icon.equals(fs.readFileSync(path.join(repo, 'site', 'icon-512.png'))));
});
