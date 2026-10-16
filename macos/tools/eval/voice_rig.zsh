#!/usr/bin/env zsh
# voice_rig.zsh — drive the running Mac M1K3's voice mode hands-free and read back what each turn cost.
#
#   macos/tools/eval/voice_rig.zsh [--turns FILE] [--out DIR] [--rate WPM] [--voice NAME] [--new-chat] [--leave-on]
#
# One spoken line per row of FILE (default: voice_rig_turns.txt; `#` lines and blanks skipped). The rig:
#   1. tees every app.m1k3 log line to <out>/app.log (`log stream`, from before the first word);
#   2. enters voice mode with ⌘⇧V through System Events, unless `m1k3 status` says it is already on.
#      --new-chat first starts a fresh conversation (⌘N, voice mode off): voice joins the open chat
#      otherwise, so its history replay starts however full that chat already is;
#   3. speaks each line with macOS `say` through the speakers. A separate process on purpose: M1K3's
#      echo canceller removes its own playback, so the `m1k3 speak` CLI cannot be the user;
#   4. paces on the app's own log, never on a timer: a turn is done when its `voice turn:` summary
#      lands AND the mic re-arms after it (`voice listening on`). `m1k3 status` does not move for
#      voice-mode turns (`answering` stays false), which is why a first draft talked over M1K3;
#   5. leaves voice mode (unless --leave-on) and prints one row per turn: route, prompt tokens read
#      past the persona seed, prefill, first audio, and any name repair or divergence line.
#
# Needs: the installed M1K3 running with its MCP server up (`m1k3 status` answers), speakers and the
# built-in mic in the same room, and Accessibility for the terminal app (the ⌘⇧V keystroke). It
# speaks out loud: run it when nobody is talking near the Mac. Kev's 2026-10-16 framing: "deeplink
# into voice-first mode and use the M1K3 cli to script tests". The Mac has no voice deep link on
# purpose (a web page could open the mic), so the keystroke is the door.
#
# Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.75 (three runs on master e632482d:
# the first two found the pacing bugs above; the third heard and answered 4/4). Prior: Unknown.
# Review: same day — --new-chat (⌘N), so a history measurement starts from an empty replay.

emulate -L zsh
setopt no_unset

here=${0:A:h}
turns_file=$here/voice_rig_turns.txt
out=""
rate=175
voice=""
leave_on=0
new_chat=0
while (( $# )); do
  case $1 in
    --turns|--out|--rate|--voice) (( $# >= 2 )) || { print -u2 -- "$1 needs a value"; exit 2 } ;;
  esac
  case $1 in
    --turns) turns_file=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --rate) rate=$2; shift 2 ;;
    --voice) voice=$2; shift 2 ;;
    --leave-on) leave_on=1; shift ;;
    --new-chat) new_chat=1; shift ;;
    -h|--help) sed -n '2,26p' $0; exit 0 ;;
    *) print -u2 "unknown argument: $1"; exit 2 ;;
  esac
done
[[ -r $turns_file ]] || { print -u2 "✗ no turns file: $turns_file"; exit 2 }
[[ -n $out ]] || out=${TMPDIR:-/tmp}/m1k3-voice-rig-$(date +%Y%m%d-%H%M%S)
mkdir -p $out
log=$out/app.log

status_of() { m1k3 status 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1'))" 2>/dev/null }
# grep -c prints 0 AND exits 1 on no match: never `|| print 0` (that printed "0\n0" and broke the maths).
count() { local c; c=$(grep -c -- "$1" $log 2>/dev/null); print ${c:-0} }
wait_count() { # pattern target timeout_s
  local i=0; while (( $(count "$1") < $2 )); do sleep 1; (( ++i >= $3 )) && return 1; done; return 0 }
wait_status() { # key value timeout_s
  local i=0; while [[ $(status_of $1) != $2 ]]; do sleep 1; (( ++i >= $3 )) && return 1; done; return 0 }
toggle_voice() {
  osascript -e 'tell application "M1K3" to activate' -e 'delay 1' \
    -e 'tell application "System Events" to keystroke "v" using {command down, shift down}' >/dev/null
}

[[ $(status_of brain) != None ]] || { print -u2 "✗ m1k3 status didn't answer: is M1K3 running with its MCP server up?"; exit 3 }
/usr/bin/log stream --level info --style compact --predicate 'subsystem == "app.m1k3"' > $log 2>&1 &
logpid=$!
trap 'kill $logpid 2>/dev/null' EXIT
sleep 2
if (( new_chat )); then
  if [[ $(status_of in_conversation) == True ]]; then toggle_voice; wait_status in_conversation False 20; fi
  osascript -e 'tell application "M1K3" to activate' -e 'delay 1' \
    -e 'tell application "System Events" to keystroke "n" using {command down}' >/dev/null
  sleep 2
fi
if [[ $(status_of in_conversation) != True ]]; then
  toggle_voice || { print -u2 "✗ the ⌘⇧V keystroke was refused: give the terminal Accessibility"; exit 3 }
  wait_count "voice listening on" 1 30 || print "! the mic never armed"
fi
wait_status speaking False 120
sleep 3

say_args=(-r $rate)
[[ -n $voice ]] && say_args+=(-v $voice)
n=0
while IFS= read -r line; do
  [[ -z $line || $line == \#* ]] && continue
  (( ++n ))
  print "▸ [$n] $line"
  print "$(date +%T) RIG SAY [$n] $line" >> $out/rig.log
  turns=$(count "voice turn:"); listens=$(count "voice listening on")
  say $say_args "$line"
  wait_count "voice turn:" $(( turns + 1 )) 240 || print "  ! no voice-turn line within 240 s"
  wait_count "voice listening on" $(( listens + 1 )) 120 || print "  ! the mic did not re-arm within 120 s"
  print "$(date +%T) RIG DONE [$n]" >> $out/rig.log
  sleep 2
done < $turns_file

(( leave_on )) || toggle_voice
sleep 2
kill $logpid 2>/dev/null
python3 $here/voice_rig_summary.py $log
print "✓ $n turns → $out"
