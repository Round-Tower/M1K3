#!/bin/zsh
# M1K3 — App Store plate capture (marketing/app-store/CAPTURE-PLAN.md).
#
#   tools/screengrab/capture.sh mac [plate ...]
#   tools/screengrab/capture.sh ios <device-udid> [plate ...]
#
# Runs the screengrab UI test suite (one XCUITest per plate) against the app
# launched under M1K3_SCREENGRAB=1 — an ISOLATED store root beside the live one
# plus the fictional demo persona, so nothing of yours is in a frame — then files
# the attachments into marketing/app-store/plates/<target>/<plate>.png and runs
# marketing/app-store/verify.py over them. Quit the live M1K3 app first on the
# Mac (same bundle id: the MCP port and the single-instance guard collide).
#
# Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.75 (Mac lane driven
# end-to-end; the iOS lane needs a physical device — verify-by-launch),
# Prior: Unknown
set -euo pipefail

target=${1:?mac|ios}; shift
root=${0:A:h:h:h}                       # macos/
repo=${root:h}
# marketing/ is gitignored (local-only) — point M1K3_MARKETING_DIR at it from a worktree.
marketing=${M1K3_MARKETING_DIR:-$repo/marketing/app-store}
plates=$marketing/plates/$target
scratch=${TMPDIR:-/tmp}/m1k3-screengrab
dd=${M1K3_SCREENGRAB_DD:-$scratch/dd-$target}   # reuse a warm DerivedData if you have one
xcresult=$scratch/$target.xcresult
[[ -d $marketing ]] || { echo "no marketing/app-store at $marketing — set M1K3_MARKETING_DIR"; exit 2; }
mkdir -p "$plates" "$scratch"
rm -rf "$xcresult"

case $target in
  mac)
    scheme=M1K3; testTarget=M1K3ScreengrabUITests; dest='platform=macOS'
    # Automatic (Apple Development) signing only: a Developer ID + hardened-runtime
    # build has no get-task-allow, so XCTest cannot drive it ("Running Background").
    sign=()
    if pgrep -x M1K3 >/dev/null && [[ ${M1K3_SCREENGRAB_ALLOW_LIVE:-0} != 1 ]]; then
      echo "quit the live M1K3 app first (pgrep -x M1K3), or M1K3_SCREENGRAB_ALLOW_LIVE=1 to run beside it (ports collide)"; exit 2
    fi
    ;;
  ios)
    udid=${1:?device udid}; shift
    scheme=M1K3iOS; testTarget=M1K3iOSScreengrabUITests; dest="id=$udid"
    sign=()
    ;;
  *) echo "target must be mac or ios"; exit 2 ;;
esac

# Plate names → test methods (kebab → CamelCase: voice-speaking → testVoiceSpeaking).
className=$([[ $target == mac ]] && echo ScreengrabUITests || echo ScreengrabiOSUITests)
only=()
for plate in "$@"; do
  method=test$(print -r -- "$plate" | perl -pe 's/(^|-)(\w)/\U$2/g')
  only+=(-only-testing:"$testTarget/$className/$method")
done

cd "$root"
xcodegen generate >/dev/null
set +e
xcodebuild test -project M1K3.xcodeproj -scheme "$scheme" -destination "$dest" \
  -derivedDataPath "$dd" -resultBundlePath "$xcresult" \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:"$testTarget" "${only[@]}" "${sign[@]}" \
  TEST_RUNNER_M1K3_SCREENGRAB_OUT="$([[ $target == mac ]] && print -r -- "$plates")" \
  2>&1 | xcbeautify --quiet
rc=$pipestatus[1]
set -e

# Attachments → plates (the Mac lane also wrote them directly; iOS only has these).
if [[ -d $xcresult ]]; then
  export_dir=$scratch/attachments-$target
  rm -rf "$export_dir"; mkdir -p "$export_dir"
  xcrun xcresulttool export attachments --path "$xcresult" --output-path "$export_dir" >/dev/null 2>&1 || true
  # manifest.json maps each attachment's suggested name (the plate) to its file.
  if [[ -f $export_dir/manifest.json ]]; then
    python3 - "$export_dir" "$plates" <<'PY'
import json, shutil, sys, os
export_dir, plates = sys.argv[1:3]
PLATES = {"onboarding", "chat", "voice-listening", "voice-speaking", "documents", "memories", "brain-at-home",
          "companion-fox", "companion-gecko", "companion-inkfish", "companion-colobus", "privacy-label"}
for test in json.load(open(os.path.join(export_dir, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a.get("exportedFileName", "")
        stem = name.split("_")[0].removesuffix(".png")
        src = os.path.join(export_dir, a["exportedFileName"])
        # Only the plates' own PNGs — XCTest also attaches screen recordings and
        # element debug descriptions on failure.
        if stem in PLATES and src.endswith(".png") and os.path.exists(src):
            shutil.copyfile(src, os.path.join(plates, f"{stem}.png"))
            print(f"plate {stem}.png")
PY
  fi
fi

echo "xcodebuild test exit=$rc"
ls -la "$plates"
python3 "$marketing/verify.py" "$marketing/out/$target/en-US" --target "$target" --plates "$plates" || true
exit $rc
