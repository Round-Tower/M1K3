#!/bin/zsh
# Direct Mac plate capture — no XCUITest (2026-09-23).
#
#   tools/screengrab/direct/capture-direct.sh <path/to/M1K3.app> [marketing/app-store dir]
#
# capture.sh drives the plates through XCUITest, which needs macOS "automation mode"
# — an admin authorization that times out when nobody is at the Mac ("Timed out while
# enabling automation mode"). Every plate's SETUP already runs inside the app (the
# screengrab harness beat), so this launches the built app once per plate with the
# recipe's arguments, waits, and captures the window with screencapture -l. The
# helpers (ax / winlist / wheel) are compiled on first use into $TMPDIR.
#
# Quit the live M1K3 first (same bundle id). Other apps are hidden for the run.
# Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.75 (drove all 13 Mac plates
# once; the voice-speaking timing is a burst you pick from). Prior: Unknown
set -u
here=${0:A:h}
APP=${1:?path to a built M1K3.app}/Contents/MacOS/M1K3
OUT=${2:-${here:h:h:h:h}/marketing/app-store}/plates/mac
S=${TMPDIR:-/tmp}/m1k3-direct-capture; mkdir -p $S
for tool in ax winlist wheel; do
  [[ $S/$tool -nt $here/$tool.swift ]] || swiftc -O $here/$tool.swift -o $S/$tool || exit 2
done
RUN=capture-$(date +%s)
cd $S
log() { print -r -- "$(date +%H:%M:%S) $*"; }
appPid() { pgrep -f "$APP" | head -1; }
quitApp() { local p=$(appPid); [[ -n $p ]] && kill -TERM $p; for i in {1..20}; do [[ -z $(appPid) ]] && return; sleep 0.5; done; pkill -9 -f "$APP" ; sleep 1; }
mainWin() { $S/winlist $1 | awk -v want="$2" '$5>=1000 || (want!="" && index($0,want)) {print $1; exit}'; }
namedWin() { $S/winlist $1 | awk -v want="$2" 'index($0,want) {print $1; exit}'; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" >/dev/null 2>&1; }
waitFor() { local p=$1 needle=$2 t=${3:-90}; for i in $(seq 1 $t); do $S/ax $p find "$needle" >/dev/null 2>&1 && return 0; sleep 1; done; log "timeout waiting for [$needle]"; return 1; }
launch() { # plate companion hasChosen [extra args...]
  local plate=$1 comp=$2 chosen=$3; shift 3
  M1K3_SCREENGRAB=1 M1K3_SCREENGRAB_PLATE=$plate M1K3_SCREENGRAB_RUN=$RUN M1K3_SCREENGRAB_ALLOW_LIVE=1 \
    $APP -hasChosenBrain $chosen -selectedBrain lil -voiceMode.companion $comp -companion.shadingStyle off \
    -brainServe.enabled NO -notchHUD.enabled NO -mcpServer.enabled NO -memoryAutoCapture NO \
    -ApplePersistenceIgnoreState YES -chatEgressAllowed NO -webSearchEnabled YES "$@" > $S/plate-$plate.log 2>&1 &
  local p=""; for i in {1..60}; do p=$(appPid); [[ -n $p ]] && [[ -n $(mainWin $p) ]] && break; sleep 1; done
  print -r -- $p
}
shoot() { # pid plate [windowName]
  local p=$1 plate=$2 name=$3 w
  if [[ -n $name ]]; then w=$(namedWin $p "$name"); else w=$(mainWin $p); fi
  front $p; sleep 1
  screencapture -x -o -l $w $OUT/$plate.png && log "shot $plate (win $w) $(sips -g pixelWidth -g pixelHeight $OUT/$plate.png | awk '/pixel/{printf "%s ", $2}')"
}

osascript -e 'tell application "System Events" to set visible of every process whose visible is true and name is not "M1K3" and name is not "Finder" to false' >/dev/null 2>&1
trap 'osascript -e "tell application \"System Events\" to set visible of every process whose visible is false and background only is false to true" >/dev/null 2>&1' EXIT

log "warm-up: fresh root + seed ($RUN)"
p=$(launch chat PhosphorFox YES); sleep 75; quitApp

for plate in chat documents memories; do
  p=$(launch $plate PhosphorFox YES); sleep 30; shoot $p $plate; quitApp
done

p=$(launch onboarding PhosphorFox NO -onboarding.startAtBrain NO); waitFor $p "brain" 60; sleep 5; shoot $p onboarding; quitApp

p=$(launch voice-listening PhosphorFox YES); sleep 40; shoot $p voice-listening; quitApp

# voice-speaking: the karaoke line moves fast and the AX probe is slow — burst from
# launch and keep the frame you want ($S/voice-speaking-NN.png), then copy it over.
p=$(launch voice-speaking PhosphorFox YES); w=$(mainWin $p); front $p; sleep 8
for k in $(seq -w 1 40); do screencapture -x -o -l $w $S/voice-speaking-$k.png; sleep 0.8; done
cp $S/voice-speaking-12.png $OUT/voice-speaking.png; quitApp

for pair in companion-fox:PhosphorFox companion-gecko:Gecko companion-inkfish:Inkfish companion-colobus:Colobus; do
  plate=${pair%%:*}; comp=${pair##*:}
  p=$(launch $plate $comp YES); sleep 30; shoot $p $plate; quitApp
done

p=$(launch privacy-label PhosphorFox YES); waitFor $p "Privacy" 60; sleep 20; shoot $p privacy-label; quitApp

p=$(launch brain-at-home PhosphorFox YES); sleep 25; front $p; $S/wheel $p 14 -300; sleep 2; shoot $p brain-at-home; quitApp

p=$(launch constellation PhosphorFox YES); sleep 25; $S/ax $p press "Memory Constellation" AXMenuItem; sleep 25; shoot $p constellation "Memory Constellation"; quitApp

log CAPTURE_DONE
