#!/bin/zsh
# upload-local.zsh <dir> — validate + upload release-local.sh's Mac .pkg and iOS .ipa to App
# Store Connect. Kev's, via `!` (the classifier reads altool --upload-app as a production deploy).
# Reads the ASC API key file inside the script and never prints it.
#
# Signed: Kev + claude-opus-5.5, 2026-10-21
# Context: replaces the per-build upload-537/538/539.zsh scratch copies; same commands.
# Confidence: 0.85 — the body is the script that uploaded 538 and 539.
# Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
set -euo pipefail
OUT=${1:?usage: upload-local.zsh <release-local.sh output dir>}
J=$HOME/.appstoreconnect/private_keys/asc_api_key.json
K=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['key_id'])" $J)
I=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['issuer_id'])" $J)
MAC=($OUT/mac/export/*.pkg(N))
IOS=($OUT/ios/export/*.ipa(N))
(( $#MAC && $#IOS )) || { print "✗ need one .pkg in $OUT/mac/export and one .ipa in $OUT/ios/export"; exit 1 }
for pair in "macos:$MAC[1]" "ios:$IOS[1]"; do
  t=${pair%%:*}; f=${pair#*:}
  print "== $t: validate $f"
  xcrun altool --validate-app -f "$f" -t "$t" --apiKey "$K" --apiIssuer "$I"
  print "== $t: upload"
  xcrun altool --upload-app -f "$f" -t "$t" --apiKey "$K" --apiIssuer "$I"
done
print "== both uploaded. An exit code is not a build: check ASC for the number (tools/asc/builds.py)."
