# The pass word on a blind set (#768 follow-ups), 2026-11-10

With the eye open in voice mode every turn used to be a look. The follow-up
lets the brain that sees the frame answer with one word, PASS, when the
question is not about the view; the turn then goes on as an ordinary one
(`LookPrompt.passClause`, `LookPassGate`). This is the score of that clause.

## The set

`blind-set.json`: 90 spoken questions, 45 that need the view (deictic, plain,
detail) and 45 that do not (commands, general knowledge, weather and time,
small talk, explicit web searches). Written by an agent that was told only the
task and read no file in this repository. The clause was chosen beforehand on
a separate 20-question set; two rewordings tried there were worse (one passed
on 10 of 30 view questions) and were dropped before this set was run.

## The runs

The instructions were the shipping ones: the look prompt, the date line, the
pass clause. Pictures are the repo's synthetic vision fixtures.

| Brain | Where | Pictures | View questions passed (wrong) | Others handed back |
| --- | --- | --- | --- | --- |
| Mini (Apple's model) | Mac, live | receipt, sign, shapes | 0 of 135 | 69 of 135 |
| Lil (Qwen3.5-4B) | iPhone 17 Pro | receipt, sign | 0 of 90 | 29 of 90 |

A pass is the word alone. Lil also wrote an answer and then the word on 12 of
180 turns, three of them real answers about the view; under the first draft of
the gate those three counted as passes, so the gate was made strict and the
stray word is trimmed from the shown answer. Mini never did this.

## What it means

- The harmful direction is clean on this set: no question about the view was
  sent away from the camera.
- The helpful direction is partial: about half of the unrelated turns on Mini
  and a third on Lil are handed back. The rest are answered as a look, which
  is what every eye-open turn did before. Commands are the weak spot (Mini
  10 of 27, Lil 8 of 18).
- A passed turn costs one short generation first: about 0.8 s on Mini (one reading on the
  phone) and 2.1 s median on Lil on the phone (the phone reported thermal state
  "serious" by the end of the session, after some 500 looks).

`results.tsv` has every row: brain, picture, kind, passed, question and the
first 80 characters of the answer.

Limits: one run per question, two or three synthetic pictures, English, and
Lil was not run on the third picture. The 20-question tuning set is not kept.

_Signed: Kev + claude-fable-5.2, 2026-11-10, Confidence 0.7 (one run per
question; the pictures are synthetic)._
