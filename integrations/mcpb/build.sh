#!/bin/zsh
# Build dist/m1k3.mcpb: an MCP Bundle is a zip of the manifest, the server and the icon.
#   integrations/mcpb/build.sh
# Prints the file's SHA-256, which the MCP Registry's server.json must carry.
set -eu
here=${0:A:h}
out=$here/dist/m1k3.mcpb
node --test $here/test/bridge.test.js $here/test/manifest.test.js > /dev/null || { print -u2 "tests failed: not building"; exit 1 }
mkdir -p $here/dist; rm -f $out
(cd $here && /usr/bin/zip -q -X -r $out manifest.json icon.png server/index.js)
print "built $out"
print "sha256 $(/usr/bin/shasum -a 256 $out | cut -d' ' -f1)"
