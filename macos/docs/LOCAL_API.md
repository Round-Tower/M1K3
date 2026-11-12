# The Local API

M1K3 can lend the brain it has loaded to other apps on the same Mac, through the
wire shape OpenAI clients already speak. It is **off by default**: turn it on in
**Settings ▸ Server ▸ Local API**.

Everything here stays on your Mac, with one exception you have to switch on
yourself: the optional `cloud-m1k3` model sends a call to Apple's Private Cloud
Compute ([below](#the-cloud-model-private-cloud-compute)).

```
Base URL   http://127.0.0.1:4141/v1
API key    Settings ▸ Server ▸ Local API ▸ API key ▸ Copy
Model      mini-m1k3, lil-m1k3 or big-m1k3: whichever brain M1K3 has ready
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:4141/v1", api_key="<the key from Settings>")
models = [m.id for m in client.models.list()]  # the brain on this Mac is always first
reply = client.chat.completions.create(
    model=models[0],
    messages=[{"role": "user", "content": "Say hello in five words."}],
)
print(reply.choices[0].message.content)
```

```sh
curl http://127.0.0.1:4141/v1/chat/completions \
  -H "Authorization: Bearer $M1K3_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"lil-m1k3","stream":true,"messages":[{"role":"user","content":"Hello"}]}'
```

## What a caller gets

The **raw brain**. On Lil and Big your system message is the whole system
prompt. On the two Apple models (Mini, and `cloud-m1k3`) one fixed line of
M1K3's comes first, then your system message, whole:

> This model is provided under Apple's acceptable use requirements for the
> Foundation Models framework. Keep every answer within them: nothing unlawful,
> harmful, hateful or deceptive.

Apple's licence asks an app that lends its models to keep a guardrail for
[Apple's acceptable use requirements](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework);
that line is it, on top of Apple's own safety filter. Those requirements apply
to what you send, too. Mini's `usage` counts the line. There is no
M1K3 personality, no memory, no knowledge base and no tools in the context, and
nothing you send is written to chat history or turned into a memory. If you want
the assistant itself (memory, knowledge, voice), that is the
[MCP server](MCP_SETUP.md).

M1K3 chooses and tests the brains it ships, inside M1K3. How one behaves under
another app's instructions has not been evaluated; that is yours to judge.

## The cloud model: Private Cloud Compute

Off by default, with its own switch: **Settings ▸ Server ▸ Local API ▸ Also
offer Private Cloud Compute**. It appears only on a Mac where M1K3 has Private
Cloud Compute (the App Store build, Apple Intelligence on) and only while
**Settings ▸ Privacy ▸ Private Cloud Compute** is on. Turn either off and no
new call is served (one already in flight finishes).

With it on, `/v1/models` lists a second id, `cloud-m1k3`, always last. A call
that names it is answered by Apple's Private Cloud Compute, a larger model than
the ones on your Mac. The id stays listed while Private Cloud Compute is
unreachable or its limit is spent; a call then gets the error below.

- **What leaves your Mac:** the messages in that call, behind the one fixed
  acceptable-use line above, and nothing else. M1K3 adds no personality,
  memory, knowledge or history, and keeps nothing.
- **What Apple says about it:** see Apple's own
  [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/)
  page. M1K3 makes no claim beyond it.
- **You can see it happening:** the Settings pane counts the calls that have
  left since M1K3 opened.
- **It spends your daily limit.** Apple limits Private Cloud Compute use per
  day, and these calls count against the same limit M1K3's own chat uses. A
  spent limit answers `429 insufficient_quota`; retrying will not help until it
  resets.
- **M1K3 caps it too:** 30 lent calls an hour (the Local API and the MCP tool
  together), so a tool in a loop cannot spend your day. Over that is
  `429 rate_limit_exceeded` with a `Retry-After`.
- **Not honoured on this model:** `max_tokens` and `temperature`. `usage` reads
  zero. `stop` works.
- Unreachable for the moment is `503 service_unavailable`, which OpenAI SDKs
  retry by themselves.
- The same queue as the local brains in this version: one call at a time, and
  you go first.

## The rules

- **Loopback only.** The listener binds 127.0.0.1. Nothing on your network can
  reach it, and web pages are refused (any request with an `Origin` gets a 403).
  A call to a brain on this Mac goes nowhere else.
- **Its own key.** Not the MCP server's token, which also unlocks memory and
  speech. Make a new key any time in Settings; the old one stops working.
- **You go first.** One call at a time. A call that arrives while you are
  chatting or in voice mode gets `429` with `Retry-After`, and a call in flight
  ends when you start a turn. OpenAI SDKs retry a 429 by themselves.
- **Each call re-reads the conversation.** Nothing is kept between calls, in
  memory or on disk, so a long history costs the same wait for the first word
  on every turn (measured 2026-11-11 on an M1 Max, an optimised build with
  the one brain loaded: about 4 s on Lil and 8.6 s on Big for 2,000 tokens; a
  short prompt starts in about 0.15 s on Lil and 0.3 s on Big, and answers run
  at about 70 and 25 tokens a second). Keep the history short where your tool
  lets you.
- **No brain swaps.** `/v1/models` lists the brain that is ready (and
  `cloud-m1k3` when you have switched that on). Asking for another one gets
  `404 model_not_found`; switch brain in M1K3 itself.
- **Reasoning is off** on this route for the brains that have a switch for it
  (Lil), so no thinking text arrives in an answer.

## What v1 offers

| | |
| --- | --- |
| `GET /v1/models` | the ready brain, then `cloud-m1k3` if you offer it |
| `POST /v1/chat/completions` | text chat, streamed (`"stream": true`) or whole |
| honoured | `messages` (system, developer, user, assistant; text parts), `max_tokens` / `max_completion_tokens` (a caller can shorten an answer, never lengthen it past the brain's cap), `temperature`, `stop` (up to four), `stream_options.include_usage` |
| refused with a 400 | `tools` / `functions`, `n` above 1, image or audio content, tool messages, JSON-schema response formats |
| not offered (404) | `/v1/completions`, `/v1/embeddings`, `/v1/responses`, audio and image endpoints |

`usage` is reported for every brain. Lil and Big report exact counts. Mini's are
taken from Apple's tokenizer once the answer is complete, so they are close, not
exact, and read zero on a system that cannot count. On any brain, `usage` reads
zero when one of your `stop` sequences ends the answer: the call is cut there,
before the count.

`finish_reason` is `length` when an answer ran into `max_tokens` and `stop`
otherwise. Apple's model names no reason, so Mini's is read off its token
count: an answer within one token of the ceiling says `length`, and on a system
that cannot count, a cut Mini answer says `stop`.

Errors use OpenAI's shape: `{"error": {"message", "type", "code", "param"}}`.
A conversation over 200,000 characters is refused with `400
context_length_exceeded` before it reaches a brain, and Mini says the same when
a conversation overflows its window. Lil and Big do not yet check a shorter
conversation against their own window. A request Apple's safety filter declines
is `400 content_filter`.

_Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.7 (the behaviour
described is pinned by M1K3LocalAPITests; a real brain behind a real client is
verify-by-launch)._

_Review: Kev + claude-fable-5.2, 2026-11-11: all three brains answered a real
client by launch (curl and a streaming Python client; Kev's own curl on Big).
Mini reports usage. The cost of a long conversation is stated; a cache between
calls was challenged and deferred until after the launch (it needs its own
memory slot, a cut at the last user turn, and Release-build numbers)._

_Review: Kev + claude-fable-5.2, 2026-11-11 (night): the timings above are
re-measured on an optimised build with one brain loaded (the earlier ones were
a Debug build beside the live app). Mini says `length` when cut. The slow first
call after idle did not recur on the optimised build (0.1 to 0.3 s)._

_Review: Kev + claude-fable-5.2, 2026-11-12: the optional `cloud-m1k3` model
(ADR 0011). The first paragraph now says the one way a call can
leave the Mac. Pinned by the package tests and tried by launch against the
Debug stand-in; the real service is verify-owed on a store-lane build._

_Review: Kev + claude-fable-5.2, 2026-11-12 (later): a lent Apple model (Mini,
`cloud-m1k3`) now runs behind one fixed acceptable-use line of M1K3's, quoted
above (`LentAppleModelGuardrail`; Kev: "Please do that"). "Your system message
is the whole system prompt" is true of Lil and Big only._
