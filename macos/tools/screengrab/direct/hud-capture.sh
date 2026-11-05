#!/bin/zsh
# HUD capture: the notch HUD in Light and Dark, on every screen, without anyone watching.
#
#   tools/screengrab/direct/hud-capture.sh [path/to/M1K3.app] [out dir]
#
# With no app path it asks xcodebuild for the Debug product of the M1K3 scheme. The app MUST be a
# Debug build: -hudDemo / -hudDemoScreen / -hudDemoText exist only under #if DEBUG
# (M1K3App/NotchHUDDemo.swift; HUDDemoScanTests pins it).
#
# For each appearance (light, dark) and each NSScreen index it launches the built app isolated
# (M1K3_SCREENGRAB=1), finds the HUD window by pid (level .screenSaver = 1000, ~460 wide),
# captures it with screencapture -l, and kills THAT pid only (never `tell application`, so Kev's
# live app is never touched). Writes hud-<appearance>-screen<i>.png and screens.txt (which index
# has a notch) into the out dir (default: <TMPDIR>/m1k3-hud-capture).
#
# Cost of running beside the live app: the launch args below switch the MCP server, Brain Serve and
# the onboarding gate off, and demo mode skips the launch-time brain warm-up (DEBUG guard in
# M1K3App.swift), so :4242 is not contended and no MLX model loads. Still prefer to quit the live
# app if you can: two M1K3 processes share the bundle id, and the screengrab harness isolates the
# STORES, not UserDefaults.
#
# Refuses an installed app or a binary without HUDDemoConfig (HUD_CAPTURE_CHECK_ONLY=1 stops after that
# check). The new pid is matched by this launch's -hudDemo argv, so a live app can never be picked up.
# Unverified until run once on the notched laptop: the 400-520 width band and layer 1000 are assumptions;
# record the real widths here after the first run.
#
# Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.6 (written and zsh -n checked, NOT run:
# window-finding and timing are verify-by-launch). Prior: none (new file).
# Review: Kev + claude-opus-5.5, 2026-11-05 — review fold: Debug-app guard, argv-matched pid, PNG size check,
# layer-1000 dump on a miss (test_hud_capture.py). Confidence 0.65, still not run.
set -u
here=${0:A:h}
repo=${here:h:h:h}                                  # macos/
APP=${1:-}
OUT=${2:-${TMPDIR:-/tmp}/m1k3-hud-capture}
S=${TMPDIR:-/tmp}/m1k3-direct-capture; mkdir -p $S $OUT

if [[ -z $APP ]]; then
  bd=$(cd $repo && xcodebuild -scheme M1K3 -destination 'platform=macOS' -configuration Debug \
        -skipPackagePluginValidation -skipMacroValidation -showBuildSettings 2>/dev/null)
  dir=$(print -r -- $bd | awk -F' = ' '/^ *TARGET_BUILD_DIR =/ {print $2; exit}')
  name=$(print -r -- $bd | awk -F' = ' '/^ *FULL_PRODUCT_NAME =/ {print $2; exit}')
  APP=$dir/$name
fi
BIN=$APP/Contents/MacOS/M1K3
[[ -x $BIN ]] || { print -u2 "no built app at $APP (build Debug first)"; exit 2; }

# Guard (review fold): a Release build ignores -hudDemo, so it would open as a real, non-demo instance on
# Kev's container and defaults. Refuse an installed app, and any binary that lacks the Debug-only demo type.
if [[ $APP == */Applications/* ]]; then
  print -u2 "refusing $APP: an installed app (/Applications); build Debug and pass that"; exit 2
fi
if ! LC_ALL=C grep -aq HUDDemoConfig $BIN; then
  print -u2 "refusing $APP: not a Debug build (no HUDDemoConfig in the binary; -hudDemo is #if DEBUG)"; exit 2
fi
[[ -n ${HUD_CAPTURE_CHECK_ONLY:-} ]] && exit 0

for tool in winlist screens; do
  [[ $S/$tool -nt $here/$tool.swift ]] || swiftc -O $here/$tool.swift -o $S/$tool || exit 2
done

log() { print -r -- "$(date +%H:%M:%S) $*"; }
$S/screens > $OUT/screens.txt
log "screens (index notch size name):"; cat $OUT/screens.txt
N=$(wc -l < $OUT/screens.txt | tr -d ' ')

RUN=hud-$(date +%s)
# Match THIS run's launch by its argv (appearance + screen), never all instances: a live app is never a match.
pids() { pgrep -f -- "$BIN .*-hudDemo $1 -hudDemoScreen $2 " | sort; }
minpng=2000 # bytes; an empty or wallpaper-only capture (no Screen Recording grant) is smaller or absent
# The HUD: layer 1000 (last winlist field), width ~460 (third from last).
hudWin() { $S/winlist $1 | awk '$NF==1000 && $(NF-2)>=400 && $(NF-2)<=520 {print $1; exit}'; }

fail=0
for a in light dark; do
  for ((i = 0; i < N; i++)); do
    open -n --env M1K3_SCREENGRAB=1 --env M1K3_SCREENGRAB_RUN=$RUN-$a-$i $APP --args \
      -hudDemo $a -hudDemoScreen $i \
      -hasChosenBrain NO -mcpServer.enabled NO -brainServe.enabled NO -memoryAutoCapture NO \
      -ApplePersistenceIgnoreState YES -chatEgressAllowed NO
    pid=""
    for t in {1..30}; do
      pid=$(pids $a $i | head -1)
      [[ -n $pid ]] && break; sleep 1
    done
    if [[ -z $pid ]]; then log "FAIL $a screen$i: no new process"; fail=1; continue; fi
    w=""
    for t in {1..40}; do w=$(hudWin $pid); [[ -n $w ]] && break; sleep 1; done
    if [[ -z $w ]]; then
      log "FAIL $a screen$i: no HUD window for pid $pid; layer-1000 windows it owns (id ... width ... layer):"
      $S/winlist $pid | awk '$NF==1000' | sed 's/^/    /'; fail=1
    else
      sleep 2 # let the grow-in spring settle
      png=$OUT/hud-$a-screen$i.png; rm -f $png
      if screencapture -x -o -l $w $png \
         && [[ $(stat -f %z $png 2>/dev/null || echo 0) -ge $minpng ]]; then
        log "shot hud-$a-screen$i.png (pid $pid win $w)"
      else
        log "FAIL screencapture $a screen$i: missing or tiny PNG (does this terminal have Screen Recording?)"; fail=1
      fi
    fi
    kill -TERM $pid 2>/dev/null; sleep 1; kill -9 $pid 2>/dev/null
  done
done
log "HUD_CAPTURE_DONE fail=$fail out=$OUT"
exit $fail
