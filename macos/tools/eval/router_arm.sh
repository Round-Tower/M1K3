#!/usr/bin/env zsh
# router_arm.sh — the tool-router arm: Lil and Big, kinds tool-use + open-chat, x3, in four
# configurations, one brain per launch. Measures whether each router flag earns its default.
#
#   macos/tools/eval/router_arm.sh --app /path/to/M1K3.app [--date YYYY-MM-DD] [--brains lil,big]
#                                  [--repeats 3] [--dry-run]
#
# Configurations (ChatEvalStage keys, see tools/eval/run_chateval.py --router*):
#   off      --router off: the same live path, no route — Lil/Big as they ship (every flag off). Before
#            2026-10-10 it set no key, and tool-use took LocalAgent, a different path from the other cells.
#   routing  --router dispatch                              (toolRouterAllTiers)
#   head     --router dispatch --router-head                (+ toolGroupRouter)
#   chain    --router dispatch --router-chain               (+ toolChain)
# Each cell is saved to docs/evals/<date>-router-arm-<brain>-<config>-x3-ac.json (full answers).
# A cell whose file already exists is skipped, so an interrupted evening resumes where it stopped.
# Afterwards:  python3 macos/tools/eval/router_arm_summary.py --date <date>
#
# --app must be a build of THIS branch (the committed group-head weights and the chain fixtures
# ride in the bundle), not whatever is installed. The run needs AC power and the live M1K3 QUIT:
# two MLX processes crawl, and :4242 must be free. This script refuses to start otherwise and
# never quits the app for you.
#
# zsh traps respected (GEMMA_1_1_PLAN.md §5): --kinds=<list> as ONE word (never ${x:+--kinds $x}),
# pkill -f, not kill $(pgrep ...) (two pids = one bad argument), and no variable named `path`
# (it is tied to PATH).
#
# Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.6 (dry-run and the refusals checked;
# the launches themselves are tonight's first real run). Prior: none (new file).
# Review: same day, code-quality fold — a flag without its value is refused (NO_UNSET aborted on $2).
# Review: Kev + claude-opus-5-5, 2026-10-10 — the `off` cell passes `--router off`, so every cell takes the live path.
# Review: Kev + claude-opus-5-5, 2026-10-10 — Mini joins (`--brains lil,big,mini`): the head sits in front of
# Mini's picker too, and the summary measures Mini against its shipping `routing` cell.

setopt PIPE_FAIL NO_UNSET

here=${0:A:h}
macos=${here:h:h}
date_stamp=$(date +%Y-%m-%d)
brains=(lil big)
repeats=3
app=""
dry=0

while (( $# )); do
  case $1 in
    --app|--date|--brains|--repeats) (( $# >= 2 )) || { print -u2 -- "$1 needs a value"; exit 2 } ;;
  esac
  case $1 in
    --app) app=$2; shift 2 ;;
    --date) date_stamp=$2; shift 2 ;;
    --brains) brains=(${(s:,:)2}); shift 2 ;;
    --repeats) repeats=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,28p' $0; exit 0 ;;
    *) print -u2 "unknown argument: $1"; exit 2 ;;
  esac
done

configs=(off routing head chain)
typeset -A flags
flags[off]="--router off"
flags[routing]="--router dispatch"
flags[head]="--router dispatch --router-head"
flags[chain]="--router dispatch --router-chain"

for b in $brains; do
  # Mini too (2026-10-10): the group head sits in front of Mini's picker, so a head flip changes Mini's
  # tool turns. Mini already routes in shipping, so router_arm_summary.py measures it against `routing`.
  [[ $b == lil || $b == big || $b == mini ]] || { print -u2 "brain $b: this arm is lil, big and mini"; exit 2 }
done
[[ $repeats == <-> && $repeats -ge 1 ]] || { print -u2 -- "--repeats must be a positive integer"; exit 2 }
[[ $date_stamp == <->-<->-<-> ]] || { print -u2 -- "--date must be YYYY-MM-DD"; exit 2 }

if [[ -z $app ]]; then
  (( dry )) && app="<--app required for a real run>" || { print -u2 -- "--app is required (a build of this branch)"; exit 2 }
fi

out_dir=$macos/docs/evals
cell_path() { print -r -- "$out_dir/${date_stamp}-router-arm-$1-$2-x${repeats}-ac.json" }

# ── the plan ────────────────────────────────────────────────────────────────
print "router arm · $date_stamp · brains: ${brains[*]} · configs: ${configs[*]} · x$repeats · kinds tool-use,open-chat"
print "app: $app"
typeset -i total=0 todo=0
for b in $brains; do
  for c in $configs; do
    total+=1
    cell_file=$(cell_path $b $c)
    if [[ -e $cell_file ]]; then
      print "  skip  $b/$c (exists: ${cell_file:t})"
    else
      todo+=1
      print "  run   $b/$c  flags: ${flags[$c]:-<none>}  → ${cell_file:t}"
    fi
  done
done
print "$todo of $total cells to run (each: a 120 s AFM cool-down + one launch)."
(( dry )) && { print "dry run — nothing launched."; exit 0 }

# ── refusals ────────────────────────────────────────────────────────────────
if pgrep -f "/M1K3.app/Contents/MacOS/M1K3" >/dev/null; then
  print -u2 "✗ an M1K3 is running — quit it yourself first (this script never does)."; exit 3
fi
if lsof -nP -iTCP:4242 -sTCP:LISTEN >/dev/null 2>&1; then
  print -u2 "✗ port 4242 is busy (another M1K3 or session) — free it first."; exit 3
fi
[[ -x $app/Contents/MacOS/M1K3 ]] || { print -u2 "✗ no binary at $app/Contents/MacOS/M1K3"; exit 2 }
if ! pmset -g batt | grep -q "AC Power"; then
  print -u2 "✗ not on AC power — latency is the verdict, and battery numbers do not count."; exit 3
fi

# ── run ─────────────────────────────────────────────────────────────────────
# Hold the machine awake for the script's life (run_chateval --direct also holds it per launch).
caffeinate -dis -w $$ &
trap 'pkill -f "$app/Contents/MacOS/M1K3" 2>/dev/null; exit 130' INT TERM

mkdir -p $out_dir
for b in $brains; do
  for c in $configs; do
    cell_file=$(cell_path $b $c)
    [[ -e $cell_file ]] && continue
    print "▸ $b/$c"
    python3 $here/run_chateval.py --direct --no-relaunch --full-answers \
      --name="router-arm-$b-$c" --app=$app --brains=$b --kinds=tool-use,open-chat \
      --repeats=$repeats --save-to=$cell_file --notes="router arm $c (${flags[$c]:-flags off})" \
      ${=flags[$c]}
    rc=$?
    if (( rc != 0 )); then
      print -u2 "✗ $b/$c exited $rc — stopping (a partial arm is worse than a clear stop)."
      rm -f -- "$cell_file"
      exit $rc
    fi
    [[ -s $cell_file ]] || { print -u2 "✗ $b/$c wrote no JSON at $cell_file"; exit 7 }
  done
done

print "✓ all cells saved. Summarise:"
print "  python3 $here/router_arm_summary.py --date $date_stamp"
