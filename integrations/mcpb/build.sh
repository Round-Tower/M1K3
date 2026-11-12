#!/bin/zsh
# Build dist/m1k3.mcpb: an MCP Bundle is a zip of the manifest, the server and the icon.
#   integrations/mcpb/build.sh
# The icon is the site's (site/icon-512.png), copied in at build time: one source.
# Prints the file's SHA-256, which the MCP Registry's server.json must carry.
set -eu
here=${0:A:h}
repo=${here:h:h}
out=$here/dist/m1k3.mcpb
stage=$here/dist/stage
node --test $here/test/bridge.test.js $here/test/manifest.test.js > /dev/null || { print -u2 "tests failed: not building"; exit 1 }
rm -rf $stage $out; mkdir -p $stage/server
cp $here/manifest.json $stage/manifest.json
cp $here/server/index.js $stage/server/index.js
cp $repo/site/icon-512.png $stage/icon.png
(cd $stage && /usr/bin/zip -q -X -r $out manifest.json icon.png server/index.js)
rm -rf $stage
print "built $out"
print "sha256 $(/usr/bin/shasum -a 256 $out | cut -d' ' -f1)"
