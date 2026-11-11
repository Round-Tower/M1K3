# The Local API

M1K3 can lend the brain it has loaded to other apps on the same Mac, through the
wire shape OpenAI clients already speak. It is **off by default**: turn it on in
**Settings ▸ MCP Server ▸ Local API**.

```
Base URL   http://127.0.0.1:4141/v1
API key    Settings ▸ Local API ▸ API key ▸ Copy
Model      m1k3-mini, m1k3-lil or m1k3-big: whichever brain M1K3 has ready
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
  -d '{"model":"m1k3-lil","stream":true,"messages":[{"role":"user","content":"Hello"}]}'
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
- **No brain swaps.** `/v1/models` lists the brain that is ready. Asking for
  another one gets `404 model_not_found`; switch brain in M1K3 itself.
- **Reasoning is off** on this route, so no thinking text arrives in an answer.

## What v1 offers

| | |
| --- | --- |
| `GET /v1/models` | the ready brain |
| `POST /v1/chat/completions` | text chat, streamed (`"stream": true`) or whole |
| honoured | `messages` (system, developer, user, assistant; text parts), `max_tokens` / `max_completion_tokens` (a caller can shorten an answer, never lengthen it past the brain's cap), `temperature`, `stop` (up to four), `stream_options.include_usage` |
| refused with a 400 | `tools` / `functions`, `n` above 1, image or audio content, tool messages, JSON-schema response formats |
| not offered (404) | `/v1/completions`, `/v1/embeddings`, `/v1/responses`, audio and image endpoints |

`usage` is reported for Lil and Big. Apple's model reports no token counts, so
Mini's `usage` reads zero.

Errors use OpenAI's shape: `{"error": {"message", "type", "code", "param"}}`.
A conversation too long for the brain is `400 context_length_exceeded`; a
request Apple's safety filter declines is `400 content_filter`.

_Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.7 (the behaviour
described is pinned by M1K3LocalAPITests; a real brain behind a real client is
verify-by-launch)._
