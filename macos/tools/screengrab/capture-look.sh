#!/bin/zsh
# The look plate (1.4, #768): a REAL look at a still you choose, captured on an iPhone simulator.
#
#   tools/screengrab/capture-look.sh <simulator-udid> <still.jpg> [out.png]
#
# Why not the XCUITest lane (capture.sh): a test install gives the app a NEW data container, and a
# simulator app on macOS 27 reads only inside its own container, so a still placed for the test is gone
# by launch (measured 2026-11-11: exists=false, "container changed"). `simctl install` keeps the
# container, so this lane installs, copies the still in, launches the plate and screenshots.
#
# The brain is Mini (a simulator has no MLX): the answer is whatever Mini says about YOUR still, so
# read the frame before it goes anywhere. Use a photo that is yours to publish.
#
# Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.7, Prior: none (new file).
# Context: Kev, 2026-11-11: "we might need to add a screenshot of the vision too". Run once by hand on
# an iPhone 17 Pro Max simulator (the answer appeared, with the chips); the launch flags mirror
# ScreengrabPlate.launchRecipe by hand, so a recipe change must be copied here.
# Review: Kev + claude-fable-5.2, 2026-11-11 (review fold): the still and the output resolve against the
# caller's directory, the log's folder is made first, and the status bar is restored on any exit. Not re-run.
set -euo pipefail

udid=${1:?simulator udid}; still=${2:?path to a JPEG}; out=${3:-look.png}
still=${still:A}; out=${out:A}          # absolute before the cd below: relative paths are the caller's
root=${0:A:h:h:h}                       # macos/
dd=${M1K3_SCREENGRAB_DD:-${TMPDIR:-/tmp}/m1k3-screengrab/dd-look}
[[ -f $still ]] || { echo "no still at $still"; exit 2; }

cd "$root"
mkdir -p "${dd:h}"                      # the build log opens beside the derived data, before xcodebuild makes it
xcodegen generate >/dev/null
xcodebuild build -project M1K3.xcodeproj -scheme M1K3iOS -destination "id=$udid" -derivedDataPath "$dd" \
  -skipPackagePluginValidation -skipMacroValidation > "$dd.log" 2>&1 \
  || { grep -E "error:" "$dd.log" | head; echo "build failed: $dd.log"; exit 1; }

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl terminate "$udid" app.m1k3 2>/dev/null || true
xcrun simctl install "$udid" "$dd/Build/Products/Debug-iphonesimulator/M1K3.app"
container=$(xcrun simctl get_app_container "$udid" app.m1k3 data)
mkdir -p "$container/tmp"
cp "$still" "$container/tmp/look-still.jpg"
trap 'xcrun simctl status_bar "$udid" clear 2>/dev/null || true' EXIT   # a failed run leaves no 9:41 behind
xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 2>/dev/null || true

started=$(date "+%Y-%m-%d %H:%M:%S")
SIMCTL_CHILD_M1K3_SCREENGRAB=1 SIMCTL_CHILD_M1K3_SCREENGRAB_PLATE=look \
SIMCTL_CHILD_M1K3_SCREENGRAB_RUN="look-$(date +%s)" \
SIMCTL_CHILD_M1K3_SCREENGRAB_LOOK_FRAME="$container/tmp/look-still.jpg" \
  xcrun simctl launch "$udid" app.m1k3 -hasChosenBrain YES -selectedBrain mini \
    -voiceMode.companion PhosphorFox -companion.shadingStyle off -chat.avatarDisplay background \
    -chatEgressAllowed NO -webSearchEnabled YES -memoryAutoCapture NO >/dev/null

line=""
for _ in {1..48}; do
  line=$(xcrun simctl spawn "$udid" log show --start "$started" --style compact \
    --predicate 'subsystem == "app.m1k3" AND category == "screengrab"' 2>/dev/null | grep "look:" | tail -1 || true)
  [[ -n $line ]] && break
  sleep 5
done
print -r -- "${line:-look: no line in four minutes}"
[[ $line == *"answered=true"* ]] || { echo "the look was not answered: no frame taken"; exit 1; }
sleep 3
xcrun simctl io "$udid" screenshot "$out" >/dev/null
echo "wrote $out"
