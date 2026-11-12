// The bundle's manifest must describe the server the app really runs.
// Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85. Prior: Unknown.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));

test('the required fields are there, and the entry point and icon exist', () => {
  for (const field of ['manifest_version', 'name', 'version', 'description', 'author', 'server']) {
    assert.ok(manifest[field], field);
  }
  assert.ok(manifest.author.name);
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
  assert.equal(manifest.server.type, 'node');
  assert.ok(fs.existsSync(path.join(root, manifest.server.entry_point)));
  assert.ok(fs.existsSync(path.join(root, manifest.icon)));
  assert.deepEqual(manifest.server.mcp_config.args, ['${__dirname}/' + manifest.server.entry_point]);
});

test('the token is asked for as a secret and reaches the bridge under the name it reads', () => {
  const token = manifest.user_config.access_token;
  assert.equal(token.type, 'string');
  assert.equal(token.sensitive, true);
  assert.equal(token.required, true);
  const env = manifest.server.mcp_config.env;
  assert.equal(env.M1K3_MCP_TOKEN, '${user_config.access_token}');
  assert.equal(env.M1K3_MCP_PORT, '${user_config.port}');
  const source = fs.readFileSync(path.join(root, manifest.server.entry_point), 'utf8');
  for (const name of Object.keys(env)) assert.ok(source.includes(`env.${name}`), name);
});

test('it is a Mac extension with a privacy policy and a plain statement of what leaves', () => {
  assert.deepEqual(manifest.compatibility.platforms, ['darwin']);
  assert.ok(manifest.privacy_policies.every((url) => url.startsWith('https://')));
  assert.ok(manifest.privacy_policies.length >= 1);
  assert.match(manifest.long_description, /becomes part of your conversation with Claude/);
  assert.ok(manifest.description.length <= 100, 'the registry caps a description at 100 characters');
});

test('the tool list is the app\'s: the same names as the MCP kit serves', () => {
  const kit = path.join(root, '..', '..', 'macos', 'Sources', 'M1K3MCPKit');
  const declared = new Set(['ask_private_cloud']); // names itself through a constant
  for (const file of fs.readdirSync(kit).filter((f) => f.endsWith('.swift'))) {
    const source = fs.readFileSync(path.join(kit, file), 'utf8');
    for (const match of source.matchAll(/Tool\(\s*name:\s*"([a-z0-9_]+)"/g)) declared.add(match[1]);
  }
  const listed = manifest.tools.map((t) => t.name);
  assert.equal(new Set(listed).size, listed.length, 'no tool twice');
  assert.deepEqual([...listed].sort(), [...declared].sort());
  assert.ok(manifest.tools.every((t) => t.description && t.description.length <= 120));
});
