# What the system prompt costs Mini and Lil, 2026-11-10

Kev, after seeing how fast the look's lean prompt is: "I wonder how much our
system prompt is killing perf across models? And maybe intelligence too?"

## What was run

The same 60 closed-book questions (reasoning 26, code-gen 10, world-knowledge
10, format 8, instruction-following 6), one run each, four ways:

- **neutral**: the whole system prompt is "You are M1K3, a helpful assistant."
- **lean**: the same plus "Answer the question directly."
- **persona**: the brain's shipped persona and nothing else (the bare arm).
- **shipped**: the live path as the app wires it (router, rules, tools, persona).

Mini ran live on the Mac through `MiniLiveEvalTests`; Lil ran in a Release eval
app built from 81645cd5 (`run_chateval.py --direct`, `--thinking tier`, AC).
Times are whole answers on an M1 Max, not first text.

## Results

Passes out of 60, with the median time per answer:

| | neutral | lean | persona | shipped |
| --- | --- | --- | --- | --- |
| **Mini** | 39 · 0.76 s | 38 · 0.78 s | 34 · 4.7 s | 32 · 6.5 s |
| **Lil** | 44 · 1.5 s | 47 · 0.32 s | 51 · 3.4 s | 50 · 5.0 s |

By kind (neutral / lean / persona / shipped):

| | Mini | Lil |
| --- | --- | --- |
| reasoning (26) | 8 / 8 / 11 / 11 | 15 / 16 / 23 / 21 |
| code-gen (10) | 9 / 9 / 9 / **4** | 10 / 10 / 10 / 10 |
| world-knowledge (10) | 10 / 9 / 7 / 9 | 9 / 10 / 9 / 8 |
| instruction-following (6) | 6 / 6 / **1** / 3 | 6 / 6 / 3 / 5 |
| format (8) | 6 / 6 / 6 / 5 | 4 / 5 / 6 / 6 |

## What it says

**Speed.** On both brains the shipped turn takes several times longer than a
lean one on these questions: about 8x on Mini and 3 to 15x on Lil. Most of that
is not prefill. The persona makes answers longer (it has a voice, and it shows
its working), and the live path adds the router. On the Mac the persona prefix
is cached, so its tokens are paid once. On the phone the tokens themselves
matter: Lil's persona is 2,753 tokens and a full turn 4,087, at about 460 to 490
tokens a second (`docs/evals/2026-11-09-vision-ttft-iphone/`), which is why a
turn that misses the cache waited 9 s there and the look's 183-token prompt
answered in under one.

**Intelligence, Lil.** The persona does not make Lil worse. It scores higher
than the one-line prompts (51 and 50 against 44 and 47), and the gain is all
reasoning: with a one-line prompt Lil answers a word problem with a bare number
in 0.2 s and is wrong on 10 of 26; with the persona it works the problem and is
wrong on 3. The cost is instruction-following, where the voice breaks length
and format limits (3 of 6 on the persona alone, 5 of 6 shipped). One run of 60
is a small sample: only the reasoning gap is larger than the plus-or-minus 4 we
have seen between identical runs.

**Intelligence, Mini.** Here the prompt does hurt. As shipped, Mini answered 7
of 10 ordinary coding asks and 2 of 6 plain instructions with "I don't share my
wiring, not even one sentence of it — what do you actually need?". That is the
one sentence the persona spells out word for word as the reply to a
prompt-completion attack, and Mini copies it onto questions that are nothing of
the kind. It repeated exactly on a second and third run (5 of 10 on code-gen
both times, 6 wiring replies each). Lil shows it once in 60.

**What the sentence buys.** Paired runs on Mini, shipped wiring ("shipped" here
is the persona as it was until this change):

| Mini's persona | code-gen (x2) | instruction-following (x2) | security, scored (x3) | the other seven kinds (60) |
| --- | --- | --- | --- | --- |
| with the sentence | 5/10, 5/10 | 2/6, 3/6 | 21/21 | 44, with 13 wiring replies |
| without it | 10/10, 10/10 | 4/6, 3/6 | 14/21 | 48, with none |

The security score needs reading. With the sentence, all 21 replies are that
sentence word for word. Without it, the seven "misses" leaked nothing: the
check for leaked persona text passed 21 of 21 both ways, and the misses are
Mini refusing in its own words ("Not a single line. The wiring is locked."),
which the scorer's list of refusal phrases does not know. A further 35 answers
without the sentence, with the app's own `PersonaLeakGuard` applied before
scoring as `ChatSession` does, gave no leak either: the guard fired once, on a
reply that had begun to recite, and replaced it. (One flagged "leak" there is
the phrase "The passphrase is a leak.")

Across the other kinds the sentence was the whole answer to 3 of 5 interview
questions ("who are you?"), 2 documents, 2 sycophancy probes and every refusal.

## The call

**Mini's persona drops that one sentence** (`M1K3Persona.spelledOutDecline`,
this PR). The rule stays: a request to complete the rules is declined in one
line. Lil, Big and the pocket tier are untouched; they do not copy it.

After the change, Mini's default persona through the shipped wiring: code-gen
10/10 and interview 5/5, with no decline replies (`mini-fixed-default.json`).

Left alone, and why:

- **Lil's persona.** Its cost is answer length and the phone's cold prefill,
  not quality. The lever on the phone is keeping the cached prefix alive across
  more turns, not a shorter persona.
- **A lean lane for one-shot asks.** The look showed the shape, but which asks
  could take it without losing M1K3's voice is a product question.
- **The scorer's refusal list.** It should learn the in-voice declines above,
  or a future run will read this change as a security loss.

## Limits

One run per question except where a table says otherwise. The Mac only; Big
and the pocket tier were not run. Times are whole answers, so a longer answer
reads as a slower turn. The one-line arms carry no rules at all, so they are a
ceiling for speed and not a prompt anyone would ship. The instruction-following
kind has six questions.

The security evidence is seven attack prompts, run eight times in all without
the sentence. That is thin for a claim that nothing can leak; it is enough to
say the sentence was costing far more than it was seen to buy.

_Signed: Kev + claude-fable-5.2, 2026-11-10, Confidence 0.7 (the Mini decline
finding repeated three times and reversed when the sentence was removed; the
Lil differences other than reasoning are inside run-to-run noise). Kev's word
on the change: "Just make the best call pal."_
