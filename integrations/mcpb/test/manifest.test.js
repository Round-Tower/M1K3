// The bundle's manifest must describe the server the app really runs.
// Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85. Prior: Unknown.
// Review: Kev + claude-fable-5.2, 2026-11-16. The listing is app.m1k3/m1k3 with its own
// version; a new test holds the split (CI releases, only Kev's Mac publishes).
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
  // The icon is copied in by build.sh from the site's, so there is one source.
  assert.equal(manifest.icon, 'icon.png');
  assert.ok(fs.existsSync(path.join(root, '..', '..', 'site', 'icon-512.png')));
  assert.match(fs.readFileSync(path.join(root, 'build.sh'), 'utf8'), /site\/icon-512\.png \$stage\/icon\.png/);
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

// The MCP Registry listing (server.json), published as app.m1k3/m1k3 (the namespace
// proven by m1k3.app's DNS). publish-listing.sh adds the bundle's SHA-256 from the
// released file, because a zip's bytes differ from build to build. The listing has
// its own version (it began as a pointer at 1.0.0, before there was a bundle); the
// PACKAGE's version is the bundle's.
test('the registry listing matches the bundle and keeps the registry\'s rules', () => {
  const listing = JSON.parse(fs.readFileSync(path.join(root, 'server.json'), 'utf8'));
  assert.equal(listing.name, 'app.m1k3/m1k3');
  assert.match(listing.version, /^\d+\.\d+\.\d+$/);
  const [major, minor] = listing.version.split('.').map(Number);
  assert.ok(major > 1 || (major === 1 && minor >= 1), 'never below 1.1.0, the first version with a bundle');
  assert.ok(listing.description.length <= 100, `description is ${listing.description.length} characters`);
  assert.equal(listing.repository.url, manifest.repository.url);
  assert.equal(listing.packages.length, 1);
  const [pkg] = listing.packages;
  assert.equal(pkg.registryType, 'mcpb');
  assert.equal(pkg.transport.type, 'stdio');
  assert.equal(pkg.version, manifest.version);
  assert.equal(
    pkg.identifier,
    `https://github.com/Round-Tower/M1K3/releases/download/mcpb-v${manifest.version}/m1k3.mcpb`,
  );
  assert.ok(pkg.identifier.includes('mcp'));
  assert.equal(pkg.fileSha256, undefined, 'the hash is set by publish-listing.sh from the released bundle, never by hand');
});

// The split this listing rests on: CI releases the bundle and may deprecate the old
// GitHub-namespace entry, but only Kev's Mac can publish app.m1k3/m1k3.
test('the workflow cannot publish the listing, and the script is what hashes it', () => {
  const repo = path.join(root, '..', '..');
  const workflow = fs.readFileSync(path.join(repo, '.github', 'workflows', 'mcp-registry.yml'), 'utf8');
  const jobs = workflow.slice(workflow.indexOf('\njobs:'));
  const retire = jobs.indexOf('\n  retire-github-listing:');
  assert.ok(retire > 0, 'the retire job is the last job');
  const beforeRetire = jobs.slice(0, retire).replace(/^\s*#.*$/gm, '');
  assert.ok(!beforeRetire.includes('id-token'), 'build and publish hold no registry identity');
  assert.ok(!beforeRetire.includes('./mcp-publisher'), 'build and publish never run the publisher');
  assert.ok(!workflow.includes('login dns') && !workflow.includes('secrets.'), 'the DNS key never goes to CI');
  const script = fs.readFileSync(path.join(root, 'publish-listing.sh'), 'utf8');
  assert.ok(script.includes(".packages[0].fileSha256 = $sha"));
  assert.ok(script.includes('login dns --domain m1k3.app'));
});
