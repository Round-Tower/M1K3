# Polish pass: accurate re-run at the endpoint (2026-11-16, part of #852)

The live captions stay on SpeechTranscriber's fast mode. At the endpoint, the listen's captured
audio (in memory, never on disk, capped at 60 s) plus one second of trailing silence goes through
the same analyzer in accurate mode (`AppleBufferTranscriber`), and its text replaces the live final
when `VoicePolishPolicy` agrees. Apple's analyzer only: Whisper is an optional download, so the
pass never routes through it. Off unless launched with `-voicePolishPass YES`.

## Corpus 1 (2026-10-15, 30 clips, en_IE, one speaker, one mic, ~350 words)

`M1K3_STT_EVAL=1 M1K3_STT_CORPUS=~/.cache/m1k3-stt-corpus/2026-10-15 M1K3_STT_ARMS=fast,polish swift test --filter SpeechToTextEvalTests`

The "polish" arm is the shipped path: the shipped-fast text stands in for the live final,
`AppleBufferTranscriber` runs over the clip's samples (same padding as a live turn), and
`VoicePolisher`'s policy and 1 s budget pick the text. Audio and transcripts stay in `~/.cache`.

| arm | n | WER |
|---|---|---|
| analyzer as shipped (fast) | 30 | 10.7% |
| polish (fast live final, accurate pass over its audio) | 30 | **8.9%** |

That is 1.8 points, and the same 8.9% the file-mode accurate arm measured on 2026-10-15: the
buffer-fed pass reproduces it. The policy kept the live text on none of the 30 clips (no empty,
failed, timed-out or implausible result); the pass changed the text on 11 of 30.

Pass latency (the accurate pass alone, including analyzer setup and format conversion, a fresh
analyzer per clip, on a Mac, inside the `swift test` debug bundle): median 0.227 s, p90 0.326 s,
max 0.582 s, n = 30. The budget is 1.0 s, after which the live text stands. The 0.18 s quoted in
the 2026-10-15 eval came from a separate probe; this is the shipped code's own timing.

## Caveats

- One speaker, one session, one mic: 1.8 points on ~350 words is about six words. This does NOT
  clear the bar the polish pass was parked behind (accurate beats fast by at least 2 points on a
  SECOND real recording session), so the switch stays off. That call is Kev's.
- The eval feeds clean 16 kHz clips. The live path captures the tap's own buffer (VPIO on the
  Mac, the phone's mic on iOS) at the hardware rate; the pass converts it. Not measured on a device.
- The pass latency on an iPhone is unmeasured. The `.notice` breadcrumb (category `stt`, "polish
  pass: ...") logs the time, reason and word counts per turn (words private), so a device run
  reads it straight off the log.
