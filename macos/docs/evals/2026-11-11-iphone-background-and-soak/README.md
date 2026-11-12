# iPhone drills, 2026-11-11 to 11-12: the background exit, and the #768 heat soak

One night on one iPhone 17 Pro (iOS 27.2), driven from the Mac with no hands. A
local-only drill build (never pushed, never shipped) starts work in the app; the
Mac sends the app to the background by launching Settings and brings it back by
launching M1K3 again. Everything below is read off the phone: the app's own
drill lines, the system's crash reports and its memory log.

The drills left a handful of short test conversations on the phone and deleted
nothing. No frame was kept and no answer text was logged.

## 1. The background exit: three ways the app died, three fixes

| what was happening at the exit | what happened | cause | fix |
|---|---|---|---|
| M1K3's own voice (Kokoro) mid-sentence | a tester's crash on 1.3.0 (544) | MLX error with no handler in scope is a `fatalError` | #809 |
| Lil mid-answer | killed two seconds after the RETURN, 2 of 2 | the turn kept the brain alive through the shed; the return loaded a second copy | #812 |
| an answer being spoken | aborted at the exit, 2 of 10 | the audio player's start raised an NSException Swift cannot catch | #813 |

### 1a. Kokoro and the GPU refusal (#809)

The drill captured the error the tester's crash log could not show:

```
[METAL] Command buffer execution failed: Insufficient Permission
(to submit GPU work from background)
```

With the guarded read it is a throw: the sentence ends, the app lives, and the
next sentence after the return synthesises normally. The error does not stick.

### 1b. Two copies of Lil (#812)

Before: a generation in flight at the exit, the app killed with signal 9 about
two seconds after it came back, 2 runs of 2. The phone's memory log for that
minute lists M1K3 as the largest process at 3.9 GB.

After (an on-device turn is stopped at the exit, and the return takes back a
brain that is still loaded):

| run | result |
|---|---|
| a generation nothing stops (the control that was killed) | survives and runs on to the end |
| a real chat turn, exits from 0 to 12 s into the answer | none of 44 was killed on the return (2 of them aborted at the exit for the audio reason in 1c, before its guard); the brain is ready again and a second turn answers in 6 to 10 s |

### 1c. The audio player's start (#813)

```
*** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio',
    reason: 'player did not see an IO cycle.'
```

| | runs | aborted | refused starts caught |
|---|---|---|---|
| before the guard | 10 | 2 | (uncaught) |
| with the guard | 30 | 0 | 2, and the app survived both |

### What the phone says about background GPU

`BGTaskScheduler.supportedResources` has no `.gpu` on this phone. A
continued-processing task cannot keep a brain running in the background here,
so stopping the turn at the exit is the floor. Picking it up again on the
return is an idea for 1.5.

## 2. The #768 heat soak

Voice mode on (the mic and speech recognition listening), the eye open (the
camera running), and a look at the newest frame every six seconds for ten
minutes, straight through the on-device looker. The phone lay in a dark room,
so the frames were dark (about 10 KB each); the model does the same work on
them.

| run | looks | failed | first word (median, range) | thermal state |
|---|---|---|---|---|
| Mini, from cold | 87 | 0 | 0.88 s (0.76 to 1.67) | nominal for nine minutes, fair from 538 s |
| Lil, from cold | 70 | 0 | 0.75 s (0.70 to 0.89) | nominal, fair from 156 s, serious from 478 s |
| Mini, started hot | 85 | 0 | 1.00 s (0.84 to 1.72) | serious throughout (it began there) |

"From cold" is twenty minutes with the app in the background first. The "started
hot" run came straight after an hour of Lil drills.

Reading it:

- **Time to first word does not degrade** over ten minutes on either brain, hot
  or cold. It stays under the 2 s bar from #768.
- **No look failed**, and the phone never reported `critical`.
- **Lil heats the phone, Mini barely does.** Ten minutes of looks on Lil took the
  phone to `serious`; on Mini it reached `fair` in the last minute.

What this does NOT cover:

- **Battery.** The phone was on its cable for every run (the drill needs it), so
  the battery rose. The "battery" half of #768's item is still owed, on battery,
  in the hand.
- **Charging adds heat**, so these thermal readings are the warmer case.
- **Nobody spoke.** Speech recognition was listening to a quiet room; no voice
  turn ran beside the looks.
- **A real scene.** A lit, detailed view was not in front of the camera.
- One phone, one night.

The raw lines (times, sizes and thermal state only) are `soak-mini-cold.txt`,
`soak-lil-cold.txt` and `soak-mini-hot.txt`.

Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8, Prior: none (new file).
Context: Kev, 2026-11-11: "machine and iPhone are yours until the morning".
Open: the on-battery soak; a voice turn beside the looks; whether ambient eyes
(#768's next step) should be Mini-only on heat grounds, which these runs suggest.
