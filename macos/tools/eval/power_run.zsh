#!/bin/zsh
# One power-receipt run (#696), whole: zsh macos/tools/eval/power_run.zsh <lil|big|mini> <run number>
#
# Pick the brain in M1K3's Settings first; two runs per tier are the reproducibility gate. Needs a
# real Terminal (sudo asks for the password once, before the clock starts). The raw logs, turns and
# receipts land in ~/.cache/m1k3-power; copy the receipts into docs/evals/. The method and the
# figures it produced are docs/ENERGY_MEASUREMENT.md.
#
# Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.7. Kev ran a scratch copy for all six of
# 2026-10-27's receipts (Lil, Big, Mini × 2). This one adds the rates step, the running-build check,
# the powermetrics start check, a 20-minute sampling cap, an interrupt that stops the run, the idle
# warning and the tool found beside itself: that delta has NOT run end to end (UNVERIFIED until the
# next receipt). The python half is pinned in test_power_receipt.py; the sudo half is hand-run only.
# Prior: none (new file; it wraps the commands docs/ENERGY_MEASUREMENT.md listed as owed).
set -u
brain=${1:?usage: power_run.zsh <lil|big|mini> <run>}; run=${2:?usage: power_run.zsh <lil|big|mini> <run>}
[[ $brain == (lil|big|mini) && $run == <-> ]] || { print "usage: power_run.zsh <lil|big|mini> <run number>"; exit 2 }
dir=$HOME/.cache/m1k3-power
tool=${0:A:h}/power_receipt.py
m1k3=/Applications/M1K3.app/Contents/Helpers/m1k3
stamp=$(date +%F)
base=$dir/$brain-$stamp-run$run
mkdir -p $dir

# Preflight: a wasted run costs ten minutes, so refuse early.
pmset -g batt | head -1 | grep -q "AC Power" || { print "✗ On battery. Plug the charger in."; exit 1 }
pgrep -x powermetrics >/dev/null && { print "✗ powermetrics is already running (sudo pkill -x powermetrics)."; exit 1 }
pgrep -f "xcodebuild|swift-build|swift-frontend" >/dev/null && { print "✗ A build is running. Wait for a quiet Mac."; exit 1 }
live=$($m1k3 status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["brain"].lower())') \
  || { print "✗ M1K3 isn't answering. Open it and try again."; exit 1 }
[[ $live == "$brain" ]] || { print "✗ Settings has ${(C)live} picked, not ${(C)brain}. Switch it, then re-run."; exit 1 }
[[ -e $base.log ]] && { print "✗ $base.log exists. Use the next run number."; exit 1 }
# The receipt names the installed build, so the app answering must be that build: one M1K3, from
# /Applications, launched after the binary was last replaced (an installer keeps the old process).
exe=/Applications/M1K3.app/Contents/MacOS/M1K3
pids=(${(f)"$(pgrep -x M1K3)"})
(( ${#pids} == 1 )) || { print "✗ ${#pids} M1K3 processes are running. Quit all but /Applications/M1K3.app."; exit 1 }
[[ "$(ps -o comm= -p $pids[1])" == "$exe" ]] || { print "✗ The M1K3 running is not /Applications/M1K3.app."; exit 1 }
launched=$(LC_ALL=C date -j -f "%a %b %e %T %Y" "$(LC_ALL=C ps -o lstart= -p $pids[1] | awk '{$1=$1; print}')" +%s)
(( launched > $(stat -f %m $exe) )) || { print "✗ M1K3 is running an older build than the one installed. Relaunch it."; exit 1 }
plist=/Applications/M1K3.app/Contents/Info.plist
app="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $plist) ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $plist))"
machine="$(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
provenance="{\"machine\":\"$machine\",\"power_source\":\"ac\",\"app\":\"$app\"}"

print "${(C)brain} run $run · M1K3 $app · $machine · on AC"
print "Hide M1K3 (⌘H), close other apps, then hands off for ~5–10 minutes."
read -r "?Press Return to start… "

sudo -v || exit 1                                 # the password now, before the clock starts
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
keepalive=$!
cleanup() { kill $keepalive 2>/dev/null; sudo -n pkill -INT -x powermetrics 2>/dev/null }
trap cleanup EXIT
# An interrupt must end the run. A trap that returns 0 would let it carry on, unmeasured.
trap 'exit 130' INT; trap 'exit 129' HUP; trap 'exit 143' TERM

# 20 minutes of samples at most; the run stops it once the last answer is in.
sudo -b powermetrics --samplers cpu_power,gpu_power -i 500 -n 2400 -o $base.log
for _ in {1..12}; do
  sleep 0.5
  pgrep -x powermetrics >/dev/null && grep -q "Sampled system activity" $base.log 2>/dev/null && break
done
pgrep -x powermetrics >/dev/null && grep -q "Sampled system activity" $base.log 2>/dev/null \
  || { print "✗ powermetrics isn't sampling (no sample in $base.log after 6 s)."; exit 1 }
python3 $tool drive --brain $brain --out $base-turns.json || { print "✗ drive failed"; exit 1 }

# Every answer must have text: an empty one means the ask failed, not that it was cheap.
python3 - $base-turns.json <<'PY' || exit 1
import json, sys
t = json.load(open(sys.argv[1]))["turns"]
empty = [x["question"][:40] for x in t if not x["answer"].strip()]
sys.exit(f"✗ {len(empty)} empty answers: {empty}") if empty else print(f"✓ {len(t)} answers, none empty")
PY

# Stop powermetrics once its log holds a sample past the last answer (no 10-minute wait).
print "waiting for the power log to pass the last answer…"
python3 - $base.log $base-turns.json <<'PY' || exit 1
import json, re, sys, time
from datetime import datetime, timedelta
end = datetime.fromisoformat(json.load(open(sys.argv[2]))["turns"][-1]["end"]) + timedelta(seconds=3)
pat = re.compile(r"Sampled system activity \((.+?)\) \(")
for _ in range(120):
    stamps = pat.findall(open(sys.argv[1], errors="replace").read())
    if stamps and datetime.strptime(stamps[-1], "%a %b %d %H:%M:%S %Y %z") > end:
        sys.exit(0)
    time.sleep(2)
sys.exit("✗ the power log never reached the last answer")
PY
sudo pkill -INT -x powermetrics
for _ in {1..30}; do pgrep -x powermetrics >/dev/null || break; sleep 1; done

start=$(python3 -c 'import json,sys; from datetime import datetime; print(datetime.fromisoformat(json.load(open(sys.argv[1]))["idle_window"]["start"]).strftime("%Y-%m-%d %H:%M:%S"))' $base-turns.json)
/usr/bin/log show --style compact --start "$start" --predicate 'subsystem == "app.m1k3" AND category == "ttft"' > $base-ttft.log
gens=$(grep -c 'tok/s' $base-ttft.log)
turns=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["turns"]))' $base-turns.json)
print "✓ $gens ttft lines for $turns answers"

receipt=$dir/$stamp-power-receipt-$brain-run$run.json
python3 $tool report --log $base.log --turns $base-turns.json --out $receipt --provenance $provenance || exit 1
python3 - $receipt <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["summary"]
if s["idle_watts"] > 1 or s["idle_max_watts"] > s["idle_watts"] + 3:
    print(f"⚠ the idle was not quiet: median {s['idle_watts']} W, max {s['idle_max_watts']} W. Say so, or run it again.")
PY
# Mini logs no ttft lines (it reports no tokens), so only an MLX tier gets per-token rates.
if [[ $brain != mini ]]; then
  (( gens >= turns )) || { print "✗ $gens ttft lines for $turns answers: the token counts are missing."; exit 1 }
  python3 $tool rates --log $base.log --turns $base-turns.json --ttft $base-ttft.log \
    --out $dir/$stamp-power-rates-$brain-run$run.json --provenance $provenance || exit 1
fi
print "\n✓ ${(C)brain} run $run done → $dir/$stamp-power-*-$brain-run$run.json"
