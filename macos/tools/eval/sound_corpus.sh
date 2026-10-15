#!/usr/bin/env zsh
# sound_corpus.sh — build the SoundContext eval corpus from audio already on this Mac.
#
#   macos/tools/eval/sound_corpus.sh [--out DIR] [--speech DIR]
#
# Folders are the expected verdict: speech/ and speech-over-music/ and other/ should be taken,
# music/ should read as music without a speaker. Sources: Kev's STT clips (--speech, default the
# newest ~/.cache/m1k3-stt-corpus/<date>), GarageBand's Apple Loops (every loop named vocal, choir
# or vox, the spoken FX included on purpose, plus 40 instrumental loops picked with a fixed seed),
# Photos' Memories soundtracks, pink noise and the app's own dial-up. Nothing leaves the Mac and
# nothing lands in the repo.
#
# Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.75. Prior: Unknown.
# (Pre-push review folded: --out must sit under ~/.cache, empty sources are handled, silence
# measures finite, mixes are limited before 16-bit, loop names carry their pack.)

emulate -L zsh
setopt err_return pipe_fail

here=${0:A:h}
out=~/.cache/m1k3-sound-corpus
speech=''
while (( $# )); do
  case $1 in
    --out) out=$2; shift 2 ;;
    --speech) speech=$2; shift 2 ;;
    *) print -u2 "unknown flag $1"; return 2 ;;
  esac
done
command -v ffmpeg >/dev/null || { print -u2 "needs ffmpeg (brew install ffmpeg)"; return 2 }
[[ -n $speech ]] || speech=( ~/.cache/m1k3-stt-corpus/20*(N/On[1]) )
[[ -d $speech ]] || { print -u2 "no speech clips: record with stt_record.sh or pass --speech"; return 2 }
clips=( $speech/clip-*.wav(N) )
(( ${#clips} >= 30 )) || { print -u2 "need 30 clips in $speech (have ${#clips})"; return 2 }
# The folder is wiped and rebuilt: only ever one under ~/.cache named for this corpus.
[[ ${out:A} == $HOME/.cache/* && ${out:t} == m1k3-sound-corpus* ]] \
  || { print -u2 -- "--out must be ~/.cache/m1k3-sound-corpus*: refusing to wipe $out"; return 2 }
loops="/Library/Audio/Apple Loops/Apple"
[[ -d $loops ]] || { print -u2 "no Apple Loops (install GarageBand's sound library)"; return 2 }

rm -rf $out
mkdir -p $out/{speech,music,speech-over-music,other}
mono() { ffmpeg -hide_banner -loglevel error -y -i "$1" -t 10 -ac 1 -ar 16000 "$2" }

for clip in $clips; do mono $clip $out/speech/${clip:t}; done

vocal=( "${(@f)$(find $loops -type f \( -iname '*vocal*' -o -iname '*choir*' -o -iname '*vox*' \) -size +100k | sort || true)}" )
# Named for their genre folder too: two packs can ship a loop under the same name.
named() { print -r -- "${${1:h:t}// /-}--${${1:t:r}// /-}" }
for f in $vocal; do [[ -n $f ]] && mono "$f" "$out/music/vocal-$(named $f).wav"; done
# Instrumental: a fixed-seed pick (awk srand) so two runs build the same corpus.
instr=( "${(@f)$(find $loops -type f -size +200k ! -iname '*vocal*' ! -iname '*choir*' ! -iname '*vox*' | sort \
  | awk 'BEGIN { srand(1015) } { if (rand() < 0.01) print }' | head -40 || true)}" )
for f in $instr; do [[ -n $f ]] && mono "$f" "$out/music/loop-$(named $f).wav"; done
n=0
for m in /System/Library/Photos/Resources/FlexAudio/*/*.m4a(N); do
  (( n += 1 ))
  mono $m $out/music/memories-$n.wav
done

# Talking over music at measured speech-to-music ratios (0, -5, -10 dB: the music as loud as the
# voice, then louder), ten clips each over the Memories tracks and the loops. A fixed gain buried
# the voice under dense loops (2026-10-15), which measured the mixing, not the classifier.
# Mean loudness in dB; digital silence ("-inf") counts as -91 so the gain stays finite.
loudness() {
  local db=$(ffmpeg -hide_banner -i "$1" -af volumedetect -f null - 2>&1 | sed -n 's/.*mean_volume: \(-*[0-9.inf]*\) dB/\1/p')
  [[ $db == *inf* || -z $db ]] && db=-91
  print -r -- $db
}
beds=( $out/music/memories-*.wav(N) $out/music/loop-*.wav(N) )
for snr in 0 -5 -10; do
  for i in {1..10}; do
    clip=${clips[i * 3]}
    bed=${beds[$(( (i - 1) % ${#beds} + 1 ))]}
    gain=$(python3 -I -c "print(10 ** ((($(loudness $clip)) - ($(loudness $bed)) - ($snr)) / 20))")
    # ${gain} braced: zsh reads $gain[m] as a subscript.
    ffmpeg -hide_banner -loglevel error -y -i $clip -stream_loop -1 -i $bed \
      -filter_complex "[1]volume=${gain}[m];[0][m]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95" \
      -ac 1 -ar 16000 \
      $out/speech-over-music/snr${snr}-$(printf %02d $i).wav
  done
done

ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anoisesrc=color=pink:duration=6:amplitude=0.2" -ar 16000 $out/other/pink-noise.wav
mono $here/../../Sources/M1K3Avatar/SoundEffects/dialup.caf $out/other/dialup.wav

for d in $out/*(/); do print "${d:t}: $(ls $d | wc -l | tr -d ' ')"; done
