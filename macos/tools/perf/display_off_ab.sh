#!/bin/bash
# display_off_ab.sh — the display-off A/B that decides whether App Nap is the stall mechanism.
#
# 2026-10-07: with the display asleep a headless generation's decode fell 35 -> 0-3 tok/s and
# recovered ten seconds after wake. GenerationActivity (.userInitiatedAllowingIdleSystemSleep)
# is the App-Nap-only fix; this script is the test that says whether it works:
#   arm A  hold ON  (the shipping default)
#   arm B  hold OFF (M1K3 -generationActivity NO)
# Each arm runs the SAME long CHATEVAL generation on one brain, forces the display off
# 30 s in (pmset displaysleepnow), then reads decode tok/s from the unified log
# (the "@Ntok/s" line MLXBrainProvider logs at .notice) before and after the display went off.
#   A holds, B collapses  -> App Nap is the mechanism; the hold is the fix.
#   both collapse         -> display-off GPU/WindowServer throttling; the hold is not enough.
#   neither collapses     -> not reproduced (AC? run too short?); do not conclude.
#
# Usage:  macos/tools/perf/display_off_ab.sh [--dry-run] [--app <Debug M1K3.app>] [--yes-away]
#   --dry-run    print the plan and the commands each step would run; run nothing.
#   --yes-away   you are about to leave the keyboard (required; each arm also waits for HID idle).
# Env knobs: BRAIN (lil) KINDS (open-chat,reasoning,code-gen) REPEATS (3) MODEL (optional,
#   M1K3_SELFTEST_CHATEVAL_MLX_MODEL) OFF_AFTER (30 s) SETTLE (30 s after sleep before "off"
#   samples count) MAX_WAIT (1500 s per arm) MIN_OFF (120 s the run must outlive display-off).
#
# Preconditions (refused, not warned): live M1K3 not running (two MLX processes crawl);
# :4242 free; AC power. The weights must ALREADY be cached (never hf download for this).
# Keyboard/mouse activity wakes the display and voids an arm: walk away. Arm order is A then B,
# so a B collapse cannot be blamed on a cold weights cache.
#
# Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.6. Prior: Unknown (new file).
# Open: NEVER RUN. Only --dry-run and `bash -n` are checked; the log-line parse and the
# `open --env/--stdout` plumbing are verify-by-launch. Whether CHATEVAL on one brain outlives
# MIN_OFF with these defaults depends on the brain's speed (the script says "RUN TOO SHORT"
# and you raise REPEATS).
# Review: Kev + claude-fable-5.1, 2026-10-10 (#530) — the Open is CLOSED: it ran on 2026-10-10 and the
# verdict held (App Nap; hold off 29 → 4 tok/s, hold on 28.5 → 28). Two bugs from that run: the awk
# took RLENGTH-7 and dropped the last digit of `@NNtok/s` (column A read "2"); and arm B at MAX_WAIT
# `die`d before the verdict and before the display was woken. The timeout now stops the arm and
# keeps its samples, and the display is restored by an EXIT trap on every path.

set -u

APP=""
DRY=0
AWAY=0
BRAIN="${BRAIN:-lil}"
KINDS="${KINDS:-open-chat,reasoning,code-gen}"
REPEATS="${REPEATS:-3}"
MODEL="${MODEL:-}"
OFF_AFTER="${OFF_AFTER:-30}"
SETTLE="${SETTLE:-30}"
MAX_WAIT="${MAX_WAIT:-1500}"
MIN_OFF="${MIN_OFF:-120}"
MIN_IDLE="${MIN_IDLE:-60}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes-away) AWAY=1 ;;
    --app) shift; APP="${1:-}" ;;
    -h|--help) sed -n 2,28p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$APP" ]; then
  APP="$HERE/../../.build/out/Products/Debug/M1K3.app"
fi
BIN="$APP/Contents/MacOS/M1K3"
WORK="${TMPDIR:-/tmp}/display_off_ab.$$"

say() { printf '%s\n' "$*"; }
die() { printf 'refusing: %s\n' "$*" >&2; exit 2; }

env_args() {
  # The CHATEVAL stage on one brain, the report streamed to --stdout (OUT=-).
  printf -- '--env M1K3_SELFTEST=1 --env M1K3_SELFTEST_CHATEVAL=1 --env M1K3_SELFTEST_CHATEVAL_BRAINS=%s ' "$BRAIN"
  printf -- '--env M1K3_SELFTEST_CHATEVAL_KINDS=%s --env M1K3_SELFTEST_CHATEVAL_REPEATS=%s --env M1K3_SELFTEST_OUT=- ' "$KINDS" "$REPEATS"
  if [ -n "$MODEL" ]; then printf -- '--env M1K3_SELFTEST_CHATEVAL_MLX_MODEL=%s ' "$MODEL"; fi
  return 0
}

plan() {
  say "display_off_ab plan (app: $APP)"
  say "  preconditions: no live M1K3 (pgrep -x M1K3), :4242 free (lsof -iTCP:4242), AC power (pmset -g batt), --yes-away, HID idle >= ${MIN_IDLE}s"
  for arm in A B; do
    if [ "$arm" = A ]; then flag="(hold ON)"; extra=""; else flag="(hold OFF)"; extra=" --args -generationActivity NO"; fi
    say "  arm $arm $flag:"
    say "    open -n $(env_args)--stdout <work>/$arm.out --stderr <work>/$arm.err \"$APP\"$extra"
    say "    +${OFF_AFTER}s: pmset displaysleepnow; every 30s: pmset -g assertions >> <work>/$arm.assert"
    say "    wait for exit (max ${MAX_WAIT}s; must outlive display-off by >= ${MIN_OFF}s); wake display (caffeinate -u)"
    say "    /usr/bin/log show --style compact --predicate 'subsystem == \"app.m1k3\"' --start <launch> -> decode tok/s before vs after display-off (+${SETTLE}s)"
  done
  say "  verdict: two columns (A hold ON | B hold OFF): median tok/s before, after, after/before, samples, display-off seconds, M1K3 assertion snapshots"
}

if [ "$DRY" = 1 ]; then
  plan
  exit 0
fi

# ---- preconditions --------------------------------------------------------
[ "$AWAY" = 1 ] || die "pass --yes-away once you are leaving the keyboard (input wakes the display and voids an arm)"
[ -x "$BIN" ] || die "no app binary at $BIN (pass --app <Debug M1K3.app>)"
if pgrep -x M1K3 >/dev/null; then die "an M1K3 is running (pgrep -x M1K3); quit it first"; fi
if lsof -iTCP:4242 -sTCP:LISTEN >/dev/null 2>&1; then die ":4242 is in use (another session's build?)"; fi
BATT="$(pmset -g batt)"
say "power: $(printf '%s' "$BATT" | head -1)"
printf '%s' "$BATT" | head -1 | grep -q "AC Power" || die "not on AC power (tok/s on battery is not comparable)"
mkdir -p "$WORK" || die "cannot create $WORK"

hid_idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }

# median of integers on stdin; prints "-" when empty
median() {
  sort -n | awk '{a[NR]=$1} END { if (NR==0) {print "-"} else if (NR%2) {print a[(NR+1)/2]} else {printf "%.0f\n", (a[NR/2]+a[NR/2+1])/2} }'
}

# The display is restored on EVERY exit path — a `die` after displaysleepnow used to leave
# the Mac dark until a hand woke it (2026-10-10 run, arm B at MAX_WAIT).
wake_display() { caffeinate -u -t 2 >/dev/null 2>&1; }
trap wake_display EXIT

# run_arm <A|B> [extra open args...]; leaves $WORK/<arm>.{pre,post,assert,meta}
run_arm() {
  arm="$1"; shift
  say "== arm $arm: waiting for HID idle >= ${MIN_IDLE}s (hands off)"
  waited=0
  while [ "$(hid_idle)" -lt "$MIN_IDLE" ]; do
    sleep 5; waited=$((waited + 5))
    [ "$waited" -le 300 ] || die "keyboard/mouse never went idle"
  done
  start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  # shellcheck disable=SC2046
  open -n $(env_args) --stdout "$WORK/$arm.out" --stderr "$WORK/$arm.err" "$APP" "$@" || die "open failed"
  sleep 3
  pgrep -f "$BIN" >/dev/null || die "arm $arm: the app did not start"
  t0=$(date +%s)
  slept_at=0
  off_ts=""
  : > "$WORK/$arm.assert"
  while pgrep -f "$BIN" >/dev/null; do
    now=$(date +%s); el=$((now - t0))
    if [ "$el" -gt "$MAX_WAIT" ]; then
      pkill -f "$BIN"
      say "   arm $arm: exceeded ${MAX_WAIT}s — stopped; the samples so far still count (raise MAX_WAIT or lower REPEATS)"
      break
    fi
    if [ "$slept_at" = 0 ] && [ "$el" -ge "$OFF_AFTER" ]; then
      slept_at="$now"; off_ts="$(date '+%Y-%m-%d %H:%M:%S')"
      pmset displaysleepnow
      say "   arm $arm: display off at $off_ts"
    fi
    { printf '## +%ss\n' "$el"; pmset -g assertions; } >> "$WORK/$arm.assert"
    sleep 30
  done
  end=$(date +%s)
  wake_display
  [ "$slept_at" != 0 ] || die "arm $arm: the run ended before display-off (${OFF_AFTER}s); raise REPEATS"
  off_for=$((end - slept_at))
  settle_ts="$(date -j -v+"${SETTLE}"S -f '%Y-%m-%d %H:%M:%S' "$off_ts" '+%Y-%m-%d %H:%M:%S')"
  : > "$WORK/$arm.pre"; : > "$WORK/$arm.post"
  /usr/bin/log show --style compact --predicate 'subsystem == "app.m1k3"' --start "$start_ts" 2>/dev/null \
    | awk -v off="$off_ts" -v settle="$settle_ts" -v pre="$WORK/$arm.pre" -v post="$WORK/$arm.post" '
        /tok\/s/ && match($0, /@[0-9]+tok\/s/) {
          ts = substr($0, 1, 19); v = substr($0, RSTART + 1, RLENGTH - 6)
          if (ts < off) print v >> pre
          else if (ts >= settle) print v >> post
        }'
  printf '%s\n' "$off_for" > "$WORK/$arm.meta"
  if [ "$off_for" -lt "$MIN_OFF" ]; then
    say "   arm $arm: RUN TOO SHORT — outlived display-off by only ${off_for}s (< ${MIN_OFF}s); raise REPEATS"
  fi
}

say "== display-off A/B — brain=$BRAIN kinds=$KINDS repeats=$REPEATS  (work dir $WORK)"
run_arm A
sleep 30
run_arm B --args -generationActivity NO

# ---- verdict --------------------------------------------------------------
col() { # <arm> <field>
  arm="$1"
  case "$2" in
    n)    wc -l < "$WORK/$arm.post" | tr -d ' ' ;;
    pre)  median < "$WORK/$arm.pre" ;;
    post) median < "$WORK/$arm.post" ;;
    off)  cat "$WORK/$arm.meta" ;;
    snap) grep -c "M1K3" "$WORK/$arm.assert" ;;
  esac
}
ratio() { # <pre> <post>
  case "$1$2" in *-*) echo "-" ;; *) awk -v a="$1" -v b="$2" 'BEGIN { if (a > 0) printf "%.2f", b / a; else print "-" }' ;; esac
}
preA=$(col A pre); postA=$(col A post); preB=$(col B pre); postB=$(col B post)
say ""
say "                              A: hold ON      B: hold OFF"
printf '%-28s  %-14s  %s\n' "decode tok/s before off"     "$preA" "$preB"
printf '%-28s  %-14s  %s\n' "decode tok/s after off"      "$postA" "$postB"
printf '%-28s  %-14s  %s\n' "after / before"              "$(ratio "$preA" "$postA")" "$(ratio "$preB" "$postB")"
printf '%-28s  %-14s  %s\n' "samples after off"           "$(col A n)" "$(col B n)"
printf '%-28s  %-14s  %s\n' "seconds display was off"     "$(col A off)" "$(col B off)"
printf '%-28s  %-14s  %s\n' "assertion snapshots w/ M1K3" "$(col A snap)" "$(col B snap)"
say ""
say "read: A holds & B collapses -> App Nap is the mechanism. Both collapse -> display-off throttling."
say "      Neither -> not reproduced (do not conclude). Empty cells -> the log parse found nothing: check $WORK/*.err"
say "raw: $WORK  (pmset -g assertions snapshots: $WORK/A.assert, $WORK/B.assert)"
