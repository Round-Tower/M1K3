#!/bin/zsh
# Direct Mac plate capture — no XCUITest (2026-09-23).
#
#   tools/screengrab/direct/capture-direct.sh <path/to/M1K3.app> [marketing/app-store dir]
#   PSEUDO=1 | RTL=1 | LOCALE=<code> tools/screengrab/direct/capture-direct.sh <path/to/M1K3.app>
#   PLATES=agent-scripts,brain-picker tools/screengrab/direct/capture-direct.sh <path/to/M1K3.app>
#
# PLATES (comma list of plate files) shoots only those, after the same warm-up seed; unset shoots all.
#
# Localisation passes (opt-in, ../l10n-args.zsh): PSEUDO=1 adds -NSDoubleLocalizedStrings YES,
# RTL=1 forces right-to-left, LOCALE=de adds -AppleLanguages "(de)" -AppleLocale de. They combine,
# ride after the recipe's own arguments on every launch, and file into plates/mac-<suffix> so the
# English plates are never overwritten. None set = the launches are exactly as before.
# The AX waits match English labels ("brain", "Privacy", "Memory Constellation"): under LOCALE a
# translated label times out and the constellation plate misses its window; PSEUDO keeps them.
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
# Review: claude-opus-5-5, 2026-11-19 — l10n Phase 0: PSEUDO=1 / RTL=1 / LOCALE=<code> append ../l10n-args.zsh's
# arguments to every launch and file under plates/mac-<suffix>; defaults unchanged. Not run.
# Review: claude-opus-5-5, 2026-11-20 — first real run: under `set -u`, mainWin's optional $2 and shoot's optional $3
# aborted every plate ("parameter not set"), and a relative app path broke once the script cds into $S. Both fixed.
# Review: Kev + claude-opus-5-5, 2026-11-24 — a fourteenth Mac plate, `brain-picker`: the onboarding harness launched at
# the brain step, so the Mac "Pick a brain" frame shows the picker, not the hello card. Confidence 0.75 (run once).
# Review: Kev + claude-opus-5-5, 2026-11-25 — a fifteenth, `agent-scripts`: Settings ▸ Privacy scrolled to the scripts'
# Approve rows by the app itself (the old brain-at-home plate lost them when Settings grew panes). The app now
# pins dark itself under the harness (a midday run on Auto came out light; -AppleInterfaceStyle Dark never reached it).
# PLATES=a,b shoots only those plates after the warm-up (a one-plate recapture was hand-sliced four times). Confidence 0.75.
set -u
here=${0:A:h}
source ${here:h}/l10n-args.zsh   # l10n_args + l10n_suffix from PSEUDO / RTL / LOCALE (empty by default)
APP=${${1:?path to a built M1K3.app}:A}/Contents/MacOS/M1K3   # :A — the script cds into $S
OUT=${2:-${here:h:h:h:h}/marketing/app-store}/plates/mac${l10n_suffix:+-$l10n_suffix}
S=${TMPDIR:-/tmp}/m1k3-direct-capture; mkdir -p $S
[[ -n $l10n_suffix ]] && mkdir -p $OUT   # a localised run's folder is new; the English one is left as it was
for tool in ax winlist wheel; do
  [[ $S/$tool -nt $here/$tool.swift ]] || swiftc -O $here/$tool.swift -o $S/$tool || exit 2
done
RUN=capture-$(date +%s)
cd $S
log() { print -r -- "$(date +%H:%M:%S) $*"; }
appPid() { pgrep -f "$APP" | head -1; }
quitApp() { local p=$(appPid); [[ -n $p ]] && kill -TERM $p; for i in {1..20}; do [[ -z $(appPid) ]] && return; sleep 0.5; done; pkill -9 -f "$APP" ; sleep 1; }
mainWin() { $S/winlist $1 | awk -v want="${2:-}" '$5>=1000 || (want!="" && index($0,want)) {print $1; exit}'; }
namedWin() { $S/winlist $1 | awk -v want="$2" 'index($0,want) {print $1; exit}'; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" >/dev/null 2>&1; }
waitFor() { local p=$1 needle=$2 t=${3:-90}; for i in $(seq 1 $t); do $S/ax $p find "$needle" >/dev/null 2>&1 && return 0; sleep 1; done; log "timeout waiting for [$needle]"; return 1; }
launch() { # plate companion hasChosen [extra args...]
  local plate=$1 comp=$2 chosen=$3; shift 3
  M1K3_SCREENGRAB=1 M1K3_SCREENGRAB_PLATE=$plate M1K3_SCREENGRAB_RUN=$RUN M1K3_SCREENGRAB_ALLOW_LIVE=1 \
    $APP -hasChosenBrain $chosen -selectedBrain lil -voiceMode.companion $comp -companion.shadingStyle off \
    -brainServe.enabled NO -notchHUD.enabled NO -mcpServer.enabled NO -memoryAutoCapture NO \
    -ApplePersistenceIgnoreState YES -chatEgressAllowed NO -webSearchEnabled YES "$@" "${l10n_args[@]}" > $S/plate-$plate.log 2>&1 &
  local p=""; for i in {1..60}; do p=$(appPid); [[ -n $p ]] && [[ -n $(mainWin $p) ]] && break; sleep 1; done
  print -r -- $p
}
shoot() { # pid plate [windowName]
  local p=$1 plate=$2 name=${3:-} w
  if [[ -n $name ]]; then w=$(namedWin $p "$name"); else w=$(mainWin $p); fi
  front $p; sleep 1
  screencapture -x -o -l $w $OUT/$plate.png && log "shot $plate (win $w) $(sips -g pixelWidth -g pixelHeight $OUT/$plate.png | awk '/pixel/{printf "%s ", $2}')"
}

osascript -e 'tell application "System Events" to set visible of every process whose visible is true and name is not "M1K3" and name is not "Finder" to false' >/dev/null 2>&1
trap 'osascript -e "tell application \"System Events\" to set visible of every process whose visible is false and background only is false to true" >/dev/null 2>&1' EXIT

# PLATES=a,b shoots only those plate files (the warm-up always runs: a fresh run token needs its seed).
want() { [[ -z ${PLATES:-} ]] || [[ ",$PLATES," == *",$1,"* ]]; }

log "warm-up: fresh root + seed ($RUN)"
p=$(launch chat PhosphorFox YES); sleep 75; quitApp

for plate in chat documents memories; do
  want $plate || continue
  p=$(launch $plate PhosphorFox YES); sleep 30; shoot $p $plate; quitApp
done

want onboarding && { p=$(launch onboarding PhosphorFox NO -onboarding.startAtBrain NO); waitFor $p "brain" 60; sleep 5; shoot $p onboarding; quitApp; }

# brain-picker: the same onboarding harness, landed on the brain step (Settings → "Change brain…" sets the same two
# defaults, here shadowed by argument): the real Mini / Lil / Big picker for the Mac "Pick a brain" frame (Kev, 2026-11-24).
want brain-picker && { p=$(launch onboarding PhosphorFox NO -onboarding.startAtBrain YES); waitFor $p "Lil" 60; sleep 5; shoot $p brain-picker; quitApp; }

want voice-listening && { p=$(launch voice-listening PhosphorFox YES); sleep 40; shoot $p voice-listening; quitApp; }

# voice-speaking: the karaoke line moves fast and the AX probe is slow — burst from
# launch and keep the frame you want ($S/voice-speaking-NN.png), then copy it over.
if want voice-speaking; then
  p=$(launch voice-speaking PhosphorFox YES); w=$(mainWin $p); front $p; sleep 8
  for k in $(seq -w 1 40); do screencapture -x -o -l $w $S/voice-speaking-$k.png; sleep 0.8; done
  cp $S/voice-speaking-12.png $OUT/voice-speaking.png; quitApp
fi

for pair in companion-fox:PhosphorFox companion-gecko:Gecko companion-inkfish:Inkfish companion-colobus:Colobus; do
  plate=${pair%%:*}; comp=${pair##*:}
  want $plate || continue
  p=$(launch $plate $comp YES); sleep 30; shoot $p $plate; quitApp
done

want privacy-label && { p=$(launch privacy-label PhosphorFox YES); waitFor $p "Privacy" 60; sleep 20; shoot $p privacy-label; quitApp; }

# agent-scripts: the Mac "It proposes. You approve." frame. The scripts' Approve rows sit at the foot of
# Settings ▸ Privacy (since the 1.6 panes, Brain at Home is its own tab). Nothing out here can scroll that
# SwiftUI Form (AXScrollToVisible returns 0 and moves nothing; wheel events missed, 2026-11-24), so the
# plate's own recipe makes the pane scroll itself (ScreengrabHarness.settingsAnchor). The rows are the
# owner's installed scripts, read only; -scriptToolsEnabled YES shadows the switch so they render.
want agent-scripts && { p=$(launch agent-scripts PhosphorFox YES -scriptToolsEnabled YES); waitFor $p "Open Scripts Folder" 60; sleep 4; shoot $p agent-scripts; quitApp; }

want brain-at-home && { p=$(launch brain-at-home PhosphorFox YES); sleep 25; front $p; sleep 2; shoot $p brain-at-home; quitApp; }

want constellation && { p=$(launch constellation PhosphorFox YES); sleep 25; $S/ax $p press "Memory Constellation" AXMenuItem; sleep 25; shoot $p constellation "Memory Constellation"; quitApp; }

log CAPTURE_DONE
