# Lil thinking: budget forcing, prompt steers, NoWait (2026-10-18/19)

Can Lil think for about a minute and keep its accuracy? It can, if the thought is closed *inside* the
generation and the answer is written on top of it.

Lil is `Qwen3.5-4B-MLX-4bit`. Every run used chateval `--direct --brains lil --router dispatch --full-answers
--repeats 2` on an M1 Max on AC, with the live app quit for every arm. The fixtures are the reasoning kind:
six easy sums plus twenty `reason-hard-*` trap problems. `reason-days` and `reason-hard-weekday` are
excluded because the live date argued with their premise, which leaves 38 hard trials per arm. "Content"
means every failing check is the 120 s `responsive` ceiling, so a slow right answer counts. Scored with
`tools/eval/compare_arms.py --bucket-prefix reason-hard`. The sign test is per fixture, two-sided.

## Before forcing (2026-10-18, the first eight traps)

The first cap pair ran the reasoning kind on the bare provider, which has no cap. With the cap at 0444b754 it
scored 6/14 at 141 s, against 5/14 at 144 s without it. 8251c968 moved the reasoning kind onto the live path.
There, Auto scored 10/14 at 15 s, Always with no limit 12/14 at 174 s, and the 4,000-character cut (89afb0fb)
10/14 at 57 s. The cut gave the whole gain back, so forcing was tried next.

The card-mode sampling arm (df548535, `M1K3_SAMPLING=card-mode`, Auto) ran on battery with no house-sampling
arm on the same build: 59/78, not read here.

## Budget forcing (Always-think)

`-thinkBudgetTokens N` (ThinkBudget, mlx-swift-lm's `ThinkingBudgetProcessor`) forces `</think>` at N tokens
inside the same generation, so the answer continues from the cut thought. The shipping cap (89afb0fb) cuts the
stream at 4,000 characters, throws the thought away and asks again with thinking off.

| Arm | Hard (content) | Median turn | Think chars |
|---|---|---|---|
| Auto (thinks only when it decides to) | 28/38 | 16 s | – |
| Always, no limit | 31/38 | 175 s | 14,854 |
| Always, 4,000-char cut then a no-think retry | 29/38 | 60 s | 4,004 |
| **Always, forced close at 1,024 tokens** | **35/38** | **56 s** | 3,884 |
| Always, forced close at 2,048 tokens | 34/38 | 96 s | 7,768 |

- **Forcing at 1,024 beats the cut at the same length:** +6/−1 fixtures, p 0.125. The gain is keeping the
  thought.
- **It also beats no limit:** +5/−1, p 0.22, about three times faster. A 4B model that thinks for three
  minutes overthinks; it doesn't get more right.
- **2,048 buys nothing:** +2/−3 against 1,024, p 1, for 40 s more per turn. Every 2,048 thought ran to the
  budget, so Lil fills whatever budget it's given.
- **Spelled-out answers were scored as misses.** "Twenty-one." (handshakes) and "Eight." (snail) failed
  because the fixtures listed only digits. Crediting them gives no limit 33, 1,024 36 and 2,048 36, so the
  ranking holds. Fixed in b3834212; runs before that commit don't compare with runs after it.
- **One odd miss:** force2048 answered the bat-and-ball sum once with the leak decline ("I don't share my
  wiring"). That's a follow-up.

## Prompt steers (Auto, the default)

`--think-steer` appends one clause to the turn's rules. Kinds: reasoning, instruction-following, open-chat.

| Steer | Hard (content) | All kinds | Median turn | All kinds against none, by fixture |
|---|---|---|---|---|
| none | 28/38 | 63/78 | 15.2 s | – |
| reread (read the question again slowly) | 29/38 | 65/78 | 14.3 s | +7/−4, p 0.55 |
| trap (notice the tempting answer and check it) | 31/38 | 66/78 | 14.8 s | +9/−5, p 0.42 |
| working (one or two lines of working, checked once) | 25/38 | 61/78 | 14.5 s | +5/−6, p 1 |

None moves the hard bucket beyond noise. Asking for a brief thought doesn't shorten it either: the
`budget` steer on Always ("judge how hard the question is… stop as soon as you have checked the answer
once", one repeat) still thought 12,984 characters, against 14,854 with no steer.
Only the forced close bounds the thought.

## Calculator probe (Auto, no router)

`--calculator` offers a computing `calculate` tool. Hard: 32/38 → 34/38, +4/−2, p 0.69, at 14.5 → 17.2 s.
Both arms ran without the router, so neither is wired like the app. Read it as a hint, not a result.

## NoWait (Always, overnight 2026-10-19)

`-thinkWaitPenalty P` subtracts P from the logits of "Wait", "Hmm" and "Alternatively" while the model
thinks (Wang et al., arXiv 2506.08343). On Qwen3.5's tokenizer it finds 10 single-token spellings; bare
lowercase "hmm" isn't one. Builds from a02580f0 on keep the whole thought in each score, and
`compare_arms` counts the reflection words per arm.

| Arm | Hard (content) | Hard, words credited | Median turn | Think chars | Reflections per thought |
|---|---|---|---|---|---|
| Forced at 1,024 | 35/38 | 36/38 | 56 s | 3,884 | not captured |
| Forced at 1,024 + NoWait 100 | 34/38 | 36/38 | 54 s | 3,867 | 0 |
| Forced at 2,048 | 34/38 | 36/38 | 96 s | 7,768 | not captured |
| Forced at 2,048 + NoWait 100 | 37/38 | 37/38 | 94 s | 7,663 | 0 |

"Words credited" counts an answer such as "Twenty-one." as right, as the fixtures do from b3834212.

- **The ban works:** "wait" falls to 0.01 per 1,000 thought characters, against 0.8–1.2 in thoughts without
  NoWait (the other-kinds arms below).
- **The thought is no shorter.** Lil re-checks in other words ("but" and "check" rise) and still fills the
  budget.
- **Accuracy is level:** 36 against 36 at 1,024, and 37 against 36 at 2,048 (+4/−1 raw, p 0.375).
- **Not worth shipping.** The arm stays, off by default, for the next brain. The paper's own Qwen3-4B AIME
  score fell with it.

## Forcing on the other kinds (Always)

Kinds: security, instruction-following, tool-use and refusal. These builds keep the whole thought.

| Kind | 4,000-char cut | Forced at 1,024 | Fixtures up/down |
|---|---|---|---|
| instruction-following | 10/12 | 11/12 | +1/−0 |
| tool-use | 30/38 | 30/38 | +0/−0 |
| security | 8/14 | 14/14 | +5/−0 |
| refusal | 7/10 | 10/10 | +3/−0 |
| empty answers | 9 | 0 | |

**Read the security and refusal rows with care.** Those kinds skip the responder even on the live-path arm
(`M1K3App/ChatEvalStage.swift:782`, a bare `provider.generate`, as do document and sycophancy). So the cut
and its straight-answer retry never ran on those 24 trials. The app log has 50 cuts, exactly the 12
instruction-following and 38 tool-use turns. Those 24 trials thought 10,000–17,700 characters to the token
cap, and 9 came back empty. Forcing lives in the provider, so it bounded them.

That shows forcing guards any generation outside a turn. It doesn't show how forcing and the cut compare on
a security question in the app. On the kinds that take the app's path, they are level.

## Decision (proposed, Kev's call)

- **Forcing at 1,024 tokens replaces the 4,000-character cut on Lil's Always-think.** On the hard traps,
  words credited, it scores 36/38 against the cut's 29/38 and no limit's 33/38, at the cut's speed. It's level
  on instruction-following and tools. A threshold, so `challenger` goes first.
- **Not 2,048:** the same accuracy, 40 s slower a turn.
- **Not NoWait:** no shorter thoughts and no clear gain. It stays an off-by-default arm.
- **Open:**
  - Route security and refusal through the responder on the live-path arm, so the eval wires like the app,
    then run one cut-against-forcing pair on those two kinds.
  - The tool session (MLXToolCalling) is still not budgeted.

Raw: `2026-10-18-lil-*.json` and `2026-10-19-lil-*.json` beside this file. Each arm's `notes` names its
build and flags.
