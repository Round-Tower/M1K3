#!/bin/zsh
# Publish server.json to the MCP Registry as app.m1k3/m1k3, from this Mac.
#   integrations/mcpb/publish-listing.sh            dry run: hash, validate, print
#   integrations/mcpb/publish-listing.sh --confirm  log in with the DNS key and publish
# The namespace is proven by a TXT record on m1k3.app, so the signing key stays on
# Kev's Mac and never goes to CI. The bundle must already be released (the MCP
# Registry workflow with `publish` ticked): the hash written into the listing is the
# hash of what a client will download. A published version cannot be changed.
#
# Signed: Kev + claude-fable-5.2, 2026-11-16, Confidence 0.7. Prior: Unknown (new file).
# Context: Kev, 2026-11-15, on finding two registry entries: "Domain please pal".
# 1.1.0 was published by hand with these same steps on 2026-11-16; the script's
# --confirm path itself has not run against the registry.
# Review: Kev + claude-fable-5.2, 2026-11-16 (#849, both passes): the seed check used
# (#c64), which needs EXTENDED_GLOB and so refused every key. Now a length and
# charset test, tried on a throwaway key.
set -eu
setopt pipefail
case ${1:-} in ''|--confirm) ;; *) print -u2 "unknown argument: $1 (only --confirm)"; exit 2 ;; esac
for tool in mcp-publisher jq xxd openssl curl; do
  command -v $tool > /dev/null || { print -u2 "missing: $tool (mcp-publisher 1.8.1 or newer: brew install mcp-publisher)"; exit 1 }
done
here=${0:A:h}
key=${M1K3_REGISTRY_KEY:-$HOME/.config/m1k3-registry/m1k3-registry.pem}
work=$(mktemp -d); trap 'rm -rf $work' EXIT
url=$(jq -r '.packages[0].identifier' $here/server.json)
curl --fail --location --silent --show-error --output $work/m1k3.mcpb $url \
  || { print -u2 "no released bundle at $url: run the MCP Registry workflow with publish ticked first"; exit 1 }
sha=$(/usr/bin/shasum -a 256 $work/m1k3.mcpb | cut -d' ' -f1)
jq --arg sha $sha '.packages[0].fileSha256 = $sha' $here/server.json > $work/server.json
print "listing $(jq -r '.name + " " + .version' $work/server.json), bundle sha256 $sha"
cd $work
mcp-publisher validate server.json
if [[ ${1:-} != --confirm ]]; then
  print "dry run: nothing published. Pass --confirm to publish."
  exit 0
fi
[[ -r $key ]] || { print -u2 "no signing key at $key (set M1K3_REGISTRY_KEY)"; exit 1 }
# The registry wants the raw Ed25519 seed in hex: the last 32 bytes of the DER key.
# It is in mcp-publisher's argument list for the length of the login (the tool takes
# it no other way), and nowhere else.
seed=$(openssl pkey -in $key -outform DER | tail -c 32 | xxd -p -c 64)
[[ ${#seed} -eq 64 && $seed != *[^0-9a-f]* ]] || { print -u2 "$key is not a plain Ed25519 private key"; exit 1 }
mcp-publisher login dns --domain m1k3.app --private-key $seed > /dev/null
unset seed
mcp-publisher publish
