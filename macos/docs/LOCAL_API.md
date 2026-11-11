# The Local API

M1K3 can lend the brain it has loaded to other apps on the same Mac, through the
wire shape OpenAI clients already speak. It is **off by default**: turn it on in
**Settings ▸ Server ▸ Local API**.

```
Base URL   http://127.0.0.1:4141/v1
API key    Settings ▸ Server ▸ Local API ▸ API key ▸ Copy
Model      mini-m1k3, lil-m1k3 or big-m1k3: whichever brain M1K3 has ready
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:4141/v1", api_key="<the key from Settings>")
models = [m.id for m in client.models.list()]
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

The **raw brain**. Your system message is the whole system prompt. There is no
M1K3 personality, no memory, no knowledge base and no tools in the context, and
nothing you send is written to chat history or turned into a memory. If you want
the assistant itself (memory, knowledge, voice), that is the
[MCP server](MCP_SETUP.md).

M1K3 chooses and tests the brains it ships, inside M1K3. How one behaves under
another app's instructions has not been evaluated; that is yours to judge.

## The rules

- **Loopback only.** The listener binds 127.0.0.1. Nothing on your network can
  reach it, and web pages are refused (any request with an `Origin` gets a 403).
- **Its own key.** Not the MCP server's token, which also unlocks memory and
  speech. Make a new key any time in Settings; the old one stops working.
- **You go first.** One call at a time. A call that arrives while you are
  chatting or in voice mode gets `429` with `Retry-After`, and a call in flight
  ends when you start a turn. OpenAI SDKs retry a 429 by themselves.
- **Each call re-reads the conversation.** Nothing is kept between calls, in
  memory or on disk, so a long history costs the same wait for the first word
  on every turn (measured 2026-11-11 on an M1 Debug build with a second brain
  loaded: about 6 s on Lil and 8 s on Big for 2,000 tokens; a short prompt
  starts in about 0.3 s). Keep the history short where your tool lets you.
- **No brain swaps.** `/v1/models` lists the brain that is ready. Asking for
  another one gets `404 model_not_found`; switch brain in M1K3 itself.
- **Reasoning is off** on this route for the brains that have a switch for it
  (Lil), so no thinking text arrives in an answer.

## What v1 offers

| | |
| --- | --- |
| `GET /v1/models` | the ready brain |
| `POST /v1/chat/completions` | text chat, streamed (`"stream": true`) or whole |
| honoured | `messages` (system, developer, user, assistant; text parts), `max_tokens` / `max_completion_tokens` (a caller can shorten an answer, never lengthen it past the brain's cap), `temperature`, `stop` (up to four), `stream_options.include_usage` |
| refused with a 400 | `tools` / `functions`, `n` above 1, image or audio content, tool messages, JSON-schema response formats |
| not offered (404) | `/v1/completions`, `/v1/embeddings`, `/v1/responses`, audio and image endpoints |

`usage` is reported for every brain. Lil and Big report exact counts. Mini's are
taken from Apple's tokenizer once the answer is complete, so they are close, not
exact, and read zero on a system that cannot count.

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
