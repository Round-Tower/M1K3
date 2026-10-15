#!/usr/bin/env zsh
# stt_record.sh — record the speech-to-text eval corpus: one clip per prompt, your voice.
#
#   macos/tools/eval/stt_record.sh [--out DIR] [--prompts FILE] [--device N] [--list-devices] [--from N]
#
# Shows each line of stt_prompts.txt (plus ~/.cache/m1k3-stt-corpus/extra.txt, if present) in
# large type. Enter starts recording, Enter stops; r re-records the last clip; s skips; q quits.
# Each clip is saved as clip-NN.wav (16 kHz mono) beside clip-NN.txt (the reference). The corpus
# is your voice: it lives in ~/.cache/m1k3-stt-corpus/<date>/ and never in the repo.
#
# Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.7 (ffmpeg's avfoundation input;
# verify-by-run: the mic grant goes to the terminal app on the first take). Prior: Unknown.
# Review: claude-opus-5-5, 2026-10-15: Kev's first run printed nothing; the device listing's
# exit 251 tripped err_return. list_devices swallows it.
# Review: claude-opus-5-5, 2026-10-15: the first take then quit at "Enter to stop": ffmpeg's
# exit 255 on SIGINT tripped err_return (and it held the terminal; now -nostdin). Two takes
# and a quit driven through a pty. Confidence 0.8.
# Review: claude-opus-5-5, 2026-10-15: the no-microphone message and empty prompt files no
# longer trip err_return (grep's exit 1, head's SIGPIPE on grep); code-quality-reviewer.
# Review: claude-opus-5-5, 2026-10-15: --prompts FILE, for the held-out set
# (stt_prompts_heldout.txt). The default stays stt_prompts.txt.
# Review: claude-opus-5-5, 2026-10-15: extra.txt joins the default set only, never a --prompts set
# (#613 bot nit: personal lines would leak into a held-out run).

emulate -L zsh
setopt err_return pipe_fail

here=${0:A:h}
# ffmpeg's -list_devices always exits non-zero (no input to open): under err_return and
# pipe_fail that quit the script silently before its first line (2026-10-15), so swallow it.
list_devices() { ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true }
out=~/.cache/m1k3-stt-corpus/$(date +%F)
device=default
from=1
prompts_file=''
while (( $# )); do
  case $1 in
    --out) out=$2; shift 2 ;;
    --device) device=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    --prompts) prompts_file=$2; shift 2 ;;
    --list-devices) list_devices | grep -A20 'audio devices' || true; return 0 ;;
    *) print -u2 "unknown flag $1"; return 2 ;;
  esac
done
command -v ffmpeg >/dev/null || { print -u2 "needs ffmpeg (brew install ffmpeg)"; return 2 }
if [[ $device == default ]]; then
  # The first device named a microphone: index 0 is often a virtual device (Zoom's records silence).
  device=$(list_devices \
    | sed -n '/audio devices/,$p' | { grep -i 'microphone' || true } | sed -n '1s/.*\[\([0-9]*\)\].*/\1/p')
  [[ -n $device ]] || { print -u2 "no microphone found: pick one with --list-devices, then --device N"; return 2 }
fi

custom_prompts=${prompts_file:+1}
[[ -n $prompts_file ]] || prompts_file=$here/stt_prompts.txt
[[ -f $prompts_file ]] || { print -u2 "no prompts file: $prompts_file"; return 2 }
prompts=( ${(f)"$(grep -v -e '^#' -e '^[[:space:]]*$' $prompts_file || true)"} )
extra=~/.cache/m1k3-stt-corpus/extra.txt
# Personal extras join the default corpus only: a --prompts set (held-out) stays exactly as written.
[[ -z $custom_prompts && -f $extra ]] && prompts+=( ${(f)"$(grep -v -e '^#' -e '^[[:space:]]*$' $extra || true)"} )
mkdir -p $out
print "Recording ${#prompts} prompts into $out (mic: $device). q quits, s skips, r redoes the last."

take() {  # $1 = clip path stem; records until Enter
  local stem=$1
  # -nostdin and </dev/null: ffmpeg otherwise takes the terminal for its own q key and the
  # read below fails, which err_return turned into a silent quit after the first take.
  ffmpeg -nostdin -hide_banner -loglevel error -y -f avfoundation -i ":$device" -ac 1 -ar 16000 "$stem.wav" </dev/null &
  local pid=$!
  read -s "?  ● recording… Enter to stop" || true
  # ffmpeg exits 255 on SIGINT, a clean stop: under err_return a bare wait quit the script.
  kill -INT $pid 2>/dev/null; wait $pid 2>/dev/null || true
  print "\r  ✓ saved $(basename $stem).wav                "
}

i=$from
while (( i <= ${#prompts} )); do
  line=${prompts[i]}
  stem=$out/clip-$(printf %02d $i)
  print -P "\n%B[$i/${#prompts}]%b"
  print -P "%B%F{yellow}  $line%f%b"
  read -k1 -s "key?  Enter: record · s: skip · r: redo previous · q: quit "
  print
  case $key in
    q) break ;;
    s) (( i++ )); continue ;;
    r) (( i > from )) && (( i-- )); continue ;;
  esac
  print -r -- "$line" > "$stem.txt"
  take $stem
  (( i++ ))
done
print "\nDone: $(ls $out/*.wav 2>/dev/null | wc -l | tr -d ' ') clips in $out"
