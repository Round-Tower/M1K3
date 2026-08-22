# Model Contracts — what each brain expects, and what we actually send

> **Read this before touching prompting, tool calling, or sampling on Android.**
>
> Every brain we ship has a *published contract*: a chat template, a tool-call
> wire format, a thinking switch, stop tokens, and recommended sampling. This
> document establishes each contract from primary sources, then audits our code
> against it line by line.
>
> Status: **in progress — 2026-08-22.** The audit below stands as written;
> §8 tracks what has since landed. Findings are ranked in §5 with a proposed
> fix and the eval fixture that would prove each one.
>
> See **§8 Progress** (bottom) for the re-baseline numbers and the current
> state of the work list.

---

## 0. Scope, method, and how to trust this

**Audited:** Qwen3.5-0.8B (Mini), Qwen3.5-2B (Lil), Gemma 4 E2B (Big).
LFM2.5 is covered as a **candidate** (§4) because the Mac's bake-off rates it —
it is not shipped on Android.

**Method — primary sources only:**

1. **The templates the GGUFs actually carry** were read out of the shipped
   weights over HTTP range requests (GGUF metadata lives in the file header, so
   this needs ~30 MB, not the whole 1.3 GB). Both Qwen3.5 GGUFs carry a
   **byte-identical 7 816-char template**.
2. **Google's and Qwen's published templates** were diffed against those.
3. **llama.cpp's behaviour** was read at our exact pin, `e85caa81e`
   (`app/composeApp/src/androidMain/cpp/llama.cpp`), not from upstream docs —
   this pin ships the **new PEG/auto-parser** chat stack, which is a
   significantly different world from the per-model `COMMON_CHAT_FORMAT_*`
   enums older notes describe.
4. **Our code** was read in the working tree on `feat/kmp-align-reduce`.

> ⚠️ **Line numbers are from the 2026-08-22 working tree**, which carried
> uncommitted edits to `ma_core.cpp`, `LlamaCppEngine.kt`, `MaBridge.kt` and
> `ThinkingPolicy.kt` from a parallel session. Re-grep the quoted symbol rather
> than trusting the number if it doesn't land.

**Verdict vocabulary:** **MATCH** (we do what the contract says) ·
**MISMATCH** (we demonstrably do something else) · **UNKNOWN** (not
determinable without a device run).

---

## 1. The headline: one bug plausibly explains all three of today's symptoms

Kev's observations on the Pixel 9a, 2026-08-22:

- Qwen3.5-0.8B "wrote its tool call as prose" and the Kotlin fallback extractor
  rescued it.
- Thinking had to be force-disabled with a pre-closed `<think></think>` block.
- Gemma 4 E2B has **never** had a tool-calling turn on Android.

All three are downstream of **F1**.

### F1 — `common_chat_parse` is called with an EMPTY parser, and fails silently

`ma_core_generate_chat` parses the model's output like this:

```cpp
// ma_core.cpp:848-850
common_chat_parser_params pparams(params);
pparams.parse_tool_calls = true;
common_chat_msg msg = common_chat_parse(accumulated, /*is_partial=*/false, pparams);
```

The converting constructor copies **two fields and no more**:

```cpp
// llama.cpp common/chat.h:300-303
common_chat_parser_params(const common_chat_params & chat_params) {
    format  = chat_params.format;
    generation_prompt = chat_params.generation_prompt;
}
```

`common_chat_params.parser` is a *serialised* PEG program (`std::string`);
`common_chat_parser_params.parser` is a *loaded* `common_peg_arena`. The ctor
bridges neither, and we never do it ourselves. So `pparams.parser` is empty, and:

```cpp
// llama.cpp common/chat.cpp:3822-3831
common_chat_msg common_chat_peg_parse(const common_peg_arena & src_parser, ...) {
    const common_peg_arena & parser = src_parser.empty() ?
        build_chat_peg_parser([](common_chat_peg_builder & p) { return p.content(p.rest()) + p.end(); }) :
        src_parser;
    if (src_parser.empty()) {
        LOG_DBG("No parser definition detected, assuming pure content parser.");
    }
```

**It does not throw. It degrades to a pure-content parser** and says so only at
`LOG_DBG`, which Android never surfaces. Consequences, every turn, every model:

| | |
|---|---|
| `msg.tool_calls` | **always empty** |
| `msg.reasoning_content` | **always empty** |
| `msg.content` | the whole raw stream, **with `generation_prompt` prepended** (`effective_input = params.generation_prompt + input`, chat.cpp:3835) |

The reference usage is three lines away in llama.cpp's own tests:

```cpp
// llama.cpp tests/test-chat.cpp:4433-4435
common_peg_arena arena;
arena.load(params.parser);
common_chat_parser_params pp(params);
```

★ **We already build that arena — for a log line.** `ma_core.cpp:716` does
`arena.load(params.parser)` purely to `dump()` the parser into logcat. The
instrument was wired correctly; the actual call path was not.

**This is a two-line fix**, and it retires a pile of compensating machinery:

- `QwenXmlToolCallExtractor` / `Gemma4ToolCallExtractor` — the "PEG parser under
  LENIENT mode swallows the block into content" comments in both files describe
  *this* bug, not a llama.cpp quirk.
- `LlamaCppEngine.stripNativeTemplatePrefix` and its comment "common_chat_parse
  prepends `params.generation_prompt` … to the parsed content" — that is the
  empty-arena fallback's signature, exactly.
- **Corroborating historical evidence:** `app/.claude/project-memory.md`
  (2026-04-20) records "*378c parsed content vs 348c accumulated = exactly 30c
  of `<|im_start|>assistant\n<think>\n`*" and attributes it to
  `common_chat_parse`'s PEG root. It was this. The `LlmOutputSanitizer` ChatML
  patterns added that day were papering over it.

**Confidence: high.** Read off the pin's source; the failure mode is
non-throwing and log-silent by construction, which is why four months of
symptom-patching never found it.

---

## 2. Qwen3.5 — Mini (0.8B) and Lil (2B)

Both ship `unsloth/…-GGUF` Q4_K_M and carry the **same** chat template.

### 2.1 Official contract

| Aspect | Contract | Source |
|---|---|---|
| Architecture id | `qwen35` | GGUF `general.architecture` |
| Native context | **262 144** | GGUF `qwen35.context_length`; card line 64 |
| BOS | **none** (`add_bos_token: false`, `bos_token: null`) | `tokenizer_config.json` |
| EOS / stop | `<|im_end|>` (id 248046) | GGUF `tokenizer.ggml.eos_token_id` |
| System role | supported, **exactly one, at index 0**; template raises otherwise | template |
| System role *with tools* | system content is **folded into the tools system turn**, never a second turn | template |
| Tool schema injection | `<|im_start|>system\n# Tools\n\nYou have access to the following functions:\n\n<tools>\n{json}\n…</tools>` + an `<IMPORTANT>` reminder block | template |
| **Tool-call output** | **XML, not JSON:**<br>`<tool_call>`<br>`<function=NAME>`<br>`<parameter=KEY>`<br>`VALUE`<br>`</parameter>`<br>`</function>`<br>`</tool_call>` | template |
| Tool-result turn | role `tool` → `<|im_start|>user\n<tool_response>\n…\n</tool_response><|im_end|>`; consecutive tool messages **batch into one user turn** | template |
| Thinking switch | Jinja var `enable_thinking`. **Undefined ⇒ OFF** — the template emits a pre-closed `<think>\n\n</think>\n\n` | template |
| Thinking ON generation prompt | `<|im_start|>assistant\n<think>\n` (model starts *inside* the block) | template |
| Default mode | **non-thinking** ("Qwen3.5-2B operates in non-thinking mode by default", card line 585) | model card |
| Sampling (non-thinking, text) | `temp=1.0, top_p=1.00, top_k=20, min_p=0.0, presence_penalty=2.0, repetition_penalty=1.0` | card line 705 |
| Sampling (thinking, text) | `temp=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0` | card line 707 |
| Reference tool parser | `--tool-call-parser qwen3_coder` (vLLM & SGLang) | card lines 624/655 |

**GGUF vs published template:** functionally identical. The only diff is an
unsloth robustness tweak (`tool_call.arguments is mapping` instead of
`is defined`) in the branch that *re-renders prior* assistant tool calls — a
Minja-compat fix, not a behaviour change. **Our weights carry a current
template.** No Android equivalent of the Mac's `Gemma4TemplateFix` is needed
for Qwen.

### 2.2 What llama.cpp at `e85caa81e` does with it

The dispatcher matches on template *content*:

```cpp
// common/chat.cpp:3590-3594
if (src.find("<tool_call>")   != npos &&
    src.find("<function=")    != npos &&
    src.find("<parameter=")   != npos) {
    return common_chat_params_init_qwen3_coder(tmpl, params);
}
```

All three markers are present ⇒ **Qwen3.5 resolves to
`common_chat_params_init_qwen3_coder` → `COMMON_CHAT_FORMAT_PEG_NATIVE`**,
matching the vendor's own vLLM guidance. It sets `thinking_start_tag = "<think>"`,
`thinking_end_tags = {"</think>", "<tool_call>"}`, `grammar_lazy = true` for
`tool_choice=AUTO`, and pushes **WORD** grammar triggers on the tool-call starts
(chat.cpp:1325-1327).

Note what a **lazy** grammar is and is not: it constrains tokens *after* the
trigger string appears, so the emitted JSON/XML can't be malformed. **It cannot
make the model decide to call a tool.** Any design that expects the grammar to
*raise the trigger rate* is misreading it.

### 2.3 Our code, audited

| # | Our code | Contract says | Verdict |
|---|---|---|---|
| a | `ma_core.cpp:848` parses with an unloaded arena | load the arena (test-chat.cpp:4433) | **MISMATCH — F1** |
| b | `ma_core.cpp` never sets `inputs.reasoning_format` ⇒ struct default `NONE` (chat.h:261) ⇒ `extract_reasoning=false` (chat.cpp:1198) | llama.cpp's own server defaults to `DEEPSEEK` (common.h:633); header advises `AUTO` | **MISMATCH — F2** |
| c | `ChatFormat.ChatML.formatToolSchema` teaches `<tool_call>{"tool":"x","args":{}}</tool_call>` (ChatFormat.kt:114) | XML `<function=`/`<parameter=` | **MISMATCH — F4** |
| d | `ToolCallGrammarBuilder.rootRule()` constrains to that same JSON shape | XML | **MISMATCH — F4** |
| e | `DefaultChatFormatter` emits tool schema as its **own** `<|im_start|>system` turn (ChatFormat.kt:107-115) **and then** a second system turn for the persona (DefaultChatFormatter.kt:96) | one system turn, tools and persona folded together | **MISMATCH — F7** |
| f | `DefaultChatFormatter.kt:186` thinking-OFF ⇒ `<|im_start|>assistant\n<think>\n\n</think>\n\n` | byte-identical to the template's soft switch | **MATCH** ✅ |
| g | `DefaultChatFormatter.kt:186` thinking-ON ⇒ `<|im_start|>assistant\n` (no `<think>\n`) | template always opens `<think>\n` | **MISMATCH** (minor; model usually self-opens) |
| h | `ma_core.cpp:733` tokenizes the rendered prompt with `add_special=false, parse_special=true` | correct — `apply_jinja` already bakes BOS via `tmpls->add_bos` (chat.cpp:3624/828). Qwen has none anyway | **MATCH** ✅ |
| i | `install_chat_grammar_sampler` (ma_core.cpp:120-184) escapes WORD triggers, passes PATTERN through, anchors PATTERN_FULL | byte-for-byte the same logic as `common/sampling.cpp:224-244` | **MATCH** ✅ |
| j | Grammar sits **in** the sampler chain; state advances because `llama_sampler_sample` calls `llama_sampler_accept` on the chain (`src/llama-sampler.cpp:960`) | upstream default is grammar-*rejection* sampling; in-chain is upstream's `grammar_first=true` mode | **MATCH** (supported variant) ✅ |
| k | Generation-prompt prefill into the grammar is not done | upstream only prefills when `!grammar_lazy` (sampling.cpp:297); ours are lazy | **MATCH by construction** ✅ |
| l | `topK` default 64, `buildForToolInvocation` forces `temp=0.3, topK=20, minP=0.05` | `top_k=20, min_p=0.0, temp=1.0` | **MISMATCH — F12** |
| m | `penalty_present`/`penalty_freq` hardcoded `0.0f` (ma_core.cpp:775-776), not exposed | `presence_penalty=2.0` (non-thinking) is an explicit vendor recommendation | **MISMATCH — F11** |
| n | Sampler order: top_k → top_p → min_p → **temp → penalties** → dist | canonical is **PENALTIES first** (common.h:260-261) | **MISMATCH — F10** |
| o | `maxContextTokens` 4096 (Lil) / 8192 (Mini) | 262 144 native | **MATCH** (deliberate KV-cost cap; noted, not a bug) ✅ |
| p | Tool results are flattened to `"[Tool: id] output"` prose (`DefaultChatFormatter.formatToolResult`) on the raw path | `<tool_response>…</tool_response>` in a user turn | **MISMATCH** (raw path only; F14 makes it reachable) |

---

## 3. Gemma 4 E2B — Big

`unsloth/gemma-4-E2B-it-GGUF`, `gemma-4-E2B-it-Q4_K_M.gguf`.

### 3.1 Official contract

Read from `google/gemma-4-E2B-it`'s own `tokenizer_config.json` and
`chat_template.jinja` (header: *"Google Gemma 4 Canonical Chat Template,
Published 2026-07-09, Context: Fixed tool-calling loops, turn closures, and
thinking content-ordering"* — the same canonical template the Mac vendors as
`Gemma4TemplateFix`).

| Aspect | Contract |
|---|---|
| Turn markers | **`<|turn>role` … `<turn|>`** — *not* `<start_of_turn>` / `<end_of_turn>` |
| BOS | `<bos>`, emitted by the template itself (`{{- bos_token -}}`) |
| EOS / eot | `<eos>` / `<turn|>` |
| System role | **supported** as `<|turn>system`, emitted only when `enable_thinking or tools or messages[0] is system/developer` |
| Thinking enable | `<|think|>` injected at the **top of the first system turn** |
| Thinking output | **`<|channel>thought\n…\n<channel|>`** — *not* `<think>`, *not* `<start_of_thinking>` |
| Thinking default | `enable_thinking \| default(false)` ⇒ **OFF** |
| Tool declarations | `<|tool>{declaration}<tool|>` inside the system turn, via the template's own `format_function_declaration` — **not** raw JSON schema |
| **Tool-call output** | **`<|tool_call>call:NAME{key:value,…}<tool_call|>`**, strings wrapped in the escape token `<|"|>` |
| Tool responses | `<|tool_response>` … `<tool_response|>` |
| Generation prompt | `<|turn>model\n` (or `<|channel>thought\n` after a tool response when thinking) |
| Sampling | `temperature=1.0, top_k=64, top_p=0.95` (`generation_config.json`) |

llama.cpp detects it by `src.find("'<|tool_call>call:'")` (chat.cpp:3571) →
`common_chat_params_init_gemma4` → `COMMON_CHAT_FORMAT_PEG_GEMMA4`, trigger
`{WORD, "<|tool_call>"}` (chat.cpp:1656-1658).

> ✅ **Legitimate divergence from the Mac:** llama.cpp detects a *stale* Gemma 4
> template and applies `workaround::convert_tool_responses_gemma4` itself
> (chat.cpp:3572-3576). Android therefore needs **no** `Gemma4TemplateFix`
> vendoring — that Mac fix exists because MLX has no such compatibility layer.

### 3.2 Our code, audited

| # | Our code | Contract | Verdict |
|---|---|---|---|
| a | `ChatFormat.Gemma4` uses `<start_of_turn>system/user/model` + `<end_of_turn>` (ChatFormat.kt:287-291) | `<|turn>` / `<turn|>` | **MISMATCH — F3** |
| b | `ChatFormat.Gemma4.formatToolSchema` teaches `<tool_call>{"tool":…}</tool_call>` (ChatFormat.kt:293-303) | `<|tool_call>call:NAME{…}<tool_call|>` | **MISMATCH — F3** |
| c | `MessageRole.TOOL` → `<tool_response>…</tool_response>` | `<|tool_response>…<tool_response|>` | **MISMATCH — F3** |
| d | Doc comment claims thinking is `<start_of_thinking>`/`<end_of_thinking>` (ChatFormat.kt:267-272) | `<|channel>thought`/`<channel|>` | **MISMATCH** (doc rot, but it is what the code was designed against) |
| e | `getPromptPrefix()` returns a literal `<bos>` (ChatFormat.kt:305) **and** raw-path `ma_core.cpp:533` tokenizes with `add_special=true` | one BOS | **MISMATCH — F5 (double BOS)** |
| f | `ThinkingPolicy.enabled(model) = override ?: (model == Gemma4_E2B)` — thinking **ON** for Big | template default is OFF; on the native path this sets `enable_thinking=true`, which is legal but is the *unmeasured* arm | **UNKNOWN** — eval-gated, F16 |
| g | `MaSystemPromptBuilder:116` tells Big to "reason inside `<think>…</think>`" | Gemma 4 has no `<think>`; its channel is `<|channel>thought` | **MISMATCH — F6** |
| h | `Gemma4ToolCallExtractor` regex matches `<\|tool_call\|?>\s*call:NAME\{…\}` and the `<\|"\|>` escape | correct shape ✅ | **MATCH** ✅ |

> **Why Big has never made a tool call on Android** is now over-determined:
> on the **native** path F1 guarantees `tool_calls` is empty and only the
> `Gemma4ToolCallExtractor` fallback could save it; on the **raw** path we speak
> Gemma **3** at it (F3) and double the BOS (F5). Note the native path is also
> only reachable when the relevance gate returns tools at all (F14).

---

## 4. LFM2.5 — candidate only, not shipped

The Mac rates it as a live contender for the front tier: the 2026-08-08
bake-off scored **LFM2.5-2.6B 36/44** against Lil's 38/44, but it **beat** Lil on
`reasoning` (6/6) and `security` (5/7, winning two of the three prompt-leak
fixtures Lil fails) — see `macos/docs/MODEL_CHOICES.md:480-500`.

| Aspect | Contract (llama.cpp `common_chat_params_init_lfm2`, chat.cpp:1900-1999) |
|---|---|
| Detection | `<|tool_list_start|>` + `<|tool_list_end|>`, **or** `List of tools: [` without them (chat.cpp:3530-3539) |
| Format | `COMMON_CHAT_FORMAT_PEG_NATIVE` |
| Tool call | `<|tool_call_start|>` … `<|tool_call_end|>` |
| Tool list | `<|tool_list_start|>` … `<|tool_list_end|>` |
| Thinking | `<think>` / `</think>`, gated on the template actually containing `<think>` |
| Generation prompt | `<|im_start|>assistant\n` |
| Trigger | `{WORD, "<|tool_call_start|>"}` (chat.cpp:1999-2000) |
| Arch support | `LLM_ARCH_LFM2` / `LFM2MOE` present at our pin (`src/llama-arch.cpp:125-126`) |

**Two things to carry over from the Mac before spending a session on it:**

1. **Its latency number is under suspicion and the suspect was our code.** On
   the Mac, LFM2.5's mean was dragged by one kind (`grounded-Q` 41 s vs its own
   `reasoning` 3.2 s — a 13× intra-model spread, a plumbing signature, not a
   speed one), traced to prefix-reuse being applied to a **recurrent**
   (`MambaCache`) state. Android's equivalent risk is different (llama.cpp owns
   the KV/recurrent state, we don't reuse prefixes) but the lesson stands: a
   uniform-looking bad score across kinds is a harness failure, not a bad model.
2. It is a **third** wire dialect. Do not add it until §5's F1/F3/F4 are closed,
   or we'll be maintaining three drifted hand-rolled templates instead of one.

**Recommendation: do not port yet.** Re-run the Mac's own bake-off against a
fixed Android stack first; a 36/44 scored through a broken parser tells us
nothing.

---

## 5. Ranked findings

Severity: **BUG** = demonstrably wrong against the contract ·
**RISK** = off-contract, effect unmeasured · **FINE** = verified correct.

### BUG — P0

#### F1 · `common_chat_parse` runs against an empty PEG arena
*Every native-path turn, every model.* See §1.
**Fix:** in `ma_core_generate_chat`, hoist the arena that already exists at
`ma_core.cpp:716` out of the diagnostic block and parse with it —
`common_chat_peg_parse(arena, accumulated, false, pparams)` — or set
`pparams.parser.load(params.parser)` before `common_chat_parse`. Add a loud
`LOGE` when `params.parser.empty()`, so a future silent degrade is visible.
**Proves it:** `tool-use` fixture `{"id":"tool-battery-native","kind":"tool-use","prompt":"What's my battery level?","mustCallTool":"get_battery_level"}` — must pass **without** the Kotlin fallback extractor being reached (assert on the absence of the `fallback extractor found` log line).

#### F2 · `reasoning_format` is never set, so reasoning is never extracted
`common_chat_templates_inputs.reasoning_format` struct-defaults to
`COMMON_REASONING_FORMAT_NONE` (chat.h:261), which sets `extract_reasoning=false`
in every per-model init (e.g. chat.cpp:1198). llama.cpp's own server defaults to
`DEEPSEEK` (common.h:633) and the enum's comment says *"in most cases, use
COMMON_REASONING_FORMAT_AUTO"*. Result: `reasoning_content` is always `""` and
`<think>` stays inline in `content` — which is why we needed a hand-rolled
`StreamingThinkTagParser` and a `LlmOutputSanitizer` think-stripper at all.
**Fix:** set `inputs.reasoning_format = COMMON_REASONING_FORMAT_AUTO` and mirror
it onto `pparams.reasoning_format` (the converting ctor does not copy it either).
Then plumb `reasoning_content` to the ThinkingPill instead of stream-scraping.
**Proves it:** `{"id":"think-split","kind":"open-chat","prompt":"Think step by step: if I have 3 apples and eat 1, how many are left?","mustNotContain":["<think>","</think>"]}` on Big with thinking on.

### BUG — P1

#### F3 · `ChatFormat.Gemma4` is Gemma **3** syntax wearing a Gemma 4 label
`<start_of_turn>`/`<end_of_turn>`/`<tool_call>{json}` vs the real
`<|turn>`/`<turn|>`/`<|tool_call>call:NAME{…}<tool_call|>`. Gemma is the
prompt-fragile family (standing rule, `macos/docs/MODEL_CHOICES.md`), so this is
the worst family to guess at.
**Fix (preferred): delete the hand-rolled Gemma 4 raw path.** Make the native
path unconditional (F14) so llama.cpp's template renders it. If a raw path must
survive as a fallback, correct the markers *from the template*, don't hand-write
them.
**Proves it:** run the whole fixture set on Big with the raw path forced; today
it should fail broadly, and correcting the markers should move it.

#### F4 · Qwen's tool-call shape is XML; our raw-path prompt and grammar are JSON
`ChatFormat.kt:114` teaches `<tool_call>{"tool":…,"args":…}</tool_call>`;
`ToolCallGrammarBuilder.rootRule()` *enforces* it. The model was trained on
`<function=`/`<parameter=`. Worse, our own native-path fallback
(`QwenXmlToolCallExtractor`) parses the **XML** shape — the two halves of our
stack disagree with each other.
**Fix:** same as F3 — prefer the native path. If the GBNF path stays, rewrite
`rootRule()` to the XML shape and change `ChatFormat.ChatML.formatToolSchema`'s
example (or drop the example entirely and let the template's own `<tools>` block
teach it).
**Proves it:** `tool-use` fixtures with the raw path forced, before/after.

#### F5 · Double BOS on the Gemma raw path
`ChatFormat.Gemma3/Gemma4.getPromptPrefix()` emits a literal `<bos>`
(ChatFormat.kt:206/305) **and** `ma_core_generate` tokenizes with
`add_special=true` (`ma_core.cpp:533`), which adds it again. (The *native* path
is correct: `add_special=false` at :733, with BOS already baked into the
rendered prompt by `apply_jinja`.)
**Fix:** flip the raw path to `add_special=false` — every `ChatFormat` that
needs a BOS already emits one via `getPromptPrefix()`. One-line change, and it
makes both paths consistent.
**Proves it:** not directly fixture-visible; verify by logging the first three
token ids of the raw prompt for Big.

### BUG — P2

#### F6 · `buildFull` emits the `<think>` instruction unconditionally
`MaSystemPromptBuilder.kt:116` appends *"Before responding, reason inside
`<think>…</think>` tags"* with **no `if (input.teachesThinking)` guard** —
`buildCompact` (line 135) has one. So the FULL tier tells a thinking-**disabled**
Qwen to open a `<think>` block immediately after the template pre-closed one
(guaranteeing a second, visible reasoning block), and tells Gemma 4 to use a
syntax it does not have (F3).
**Fix:** guard line 116 with `teachesThinking`, and make the instruction
**tier-aware** — Gemma 4 should never be told about `<think>`.
**Proves it:** `{"id":"nothink-leak","kind":"open-chat","prompt":"What's the capital of Ireland?","mustNotContain":["<think>"]}` on Mini/Lil at the FULL tier.

#### F7 · The ChatML raw path emits **two** system turns
`DefaultChatFormatter.buildMultiTurnPrompt` appends the tool-schema block
(itself a complete `<|im_start|>system … <|im_end|>`, ChatFormat.kt:107-115)
and then a second system turn for the persona (DefaultChatFormatter.kt:96).
The official template folds system content *into* the tools turn and raises
`'System message must be at the beginning.'` on a stray second one.
**Fix:** fold them, or (better) F14.
**Proves it:** covered by the F8 fixture below — this is the most likely reason
the model started narrating a new `system` turn.

#### F8 · No stop-string enforcement — the likely echo mechanism
Both generation loops break **only** on `llama_vocab_is_eog` (ma_core.cpp:602,
782). `common_chat_params.additional_stops` is ignored, and
`ChatFormat.getStopTokens()` is applied only *after the fact* by
`LlamaCppEngine.stripStopTokens`. So when a model emits a turn marker that is
not an EOG token, generation keeps running and the model **continues the
conversation as another role**.
This is a strong candidate for Kev's `"No.system You are M1K3 —…"`: the model
answered "No.", then began a fresh system turn. It reached the UI because
`LlmOutputSanitizer.chatMlStart` is
`<\|im_start\|>(?:assistant|user|system|tool)?\s*\n?` — the role group must
follow the marker **immediately**, so `<|im_start|>\nsystem` strips only the
marker and leaves the bare word `system`. Two defects compounding.
**Fix:** (a) enforce stop strings in the generation loop (scan `accumulated`'s
tail against `params.additional_stops` + the format's stop tokens, truncate and
break); (b) move `\s*` **before** the role group in the sanitizer regex. (a) is
the real fix; (b) is belt-and-braces.
**Proves it:** `{"id":"no-role-echo","kind":"instruction-following","prompt":"Answer with a single word: is the sky green?","mustNotContain":["<|im_start|>","system","<|turn>"],"maxChars":40}`

#### F9 · Prompt truncation cuts the **tail**, destroying the generation prompt
`ma_core.cpp:543` / `:743` — `prompt_tokens.resize(n_prompt)` after clamping to
`n_prompt_max` drops tokens from the **end**, i.e. the assistant-turn opener and
(for Qwen) the `<think>` state. An over-long prompt doesn't just lose context, it
loses the instruction to *start answering*.
**Fix:** drop from the middle (keep the system head and the recent tail), which
is what every serving stack does. At minimum, keep the last N tokens.
**Proves it:** a long-context fixture near `nCtx`; today it should produce
continuation-of-user-turn output rather than an answer.

### RISK — P3

#### F10 · Sampler chain order — penalties applied last
Ours: `top_k → top_p → min_p → temp → penalties → dist` (ma_core.cpp:771-777).
Canonical: **`PENALTIES` first**, then top_k/top_p/min_p/temp (common.h:260-261).
Applying penalties after truncation *and* after temperature scaling means
repetition suppression only reaches tokens that survived the cut, at a distorted
strength. Given Mini's observed repetition/stall behaviour this is worth fixing
before tuning anything else.
**Fix:** move the `llama_sampler_init_penalties` call to the front of the chain
(after the grammar).
**Proves it:** any fixture with `maxChars` — repetition loops blow the cap.

#### F11 · `presence_penalty` is unreachable, and Qwen explicitly wants 2.0
`penalty_present` and `penalty_freq` are hardcoded `0.0f` (ma_core.cpp:590-591,
775-776) and not exposed through `MaInferenceBackend` / `GenerationConfig`.
Qwen3.5's card recommends `presence_penalty=2.0` for non-thinking mode and 1.5
for thinking — its *primary* anti-repetition control on small variants.
**Fix:** add `presencePenalty`/`frequencyPenalty` to `GenerationConfig`, thread
through the JNI signature alongside `minP`, default per model.
**Proves it:** `maxChars`-bounded fixtures on Mini, presence 0.0 vs 2.0.

#### F12 · Sampling defaults are Gemma's numbers applied to Qwen
`GenerationConfig` defaults `temp=1.0, topP=0.95, topK=64, minP=0.0` — exactly
Gemma 4's `generation_config.json`. Qwen3.5 wants `top_k=20` and `top_p=1.00`
(non-thinking). Separately `buildForToolInvocation` forces `temp=0.3, topK=20,
minP=0.05`; the `minP=0.05` and `temp=0.3` were tuned in April for
**Qwen3-0.6B on the JSON tool shape** (task #10) and are now off-contract twice
over (Qwen3.5 says `min_p=0.0, temp=1.0`).
**Fix:** move sampling defaults **onto `LlmModel`**, the way `chatFormat`
already lives there. Re-derive the tool-turn override with the eval harness,
not by feel.
**Proves it:** whole-suite A/B; `tool-use` pass-rate is the headline cell.

#### F13 · Fixed seed
`llama_sampler_init_dist(LLAMA_DEFAULT_SEED)` (ma_core.cpp:592, 777) — every
generation from the same prompt is identical. Fine (arguably good) for the eval
harness; wrong for a companion, and it means a bad answer is a *permanently* bad
answer for that phrasing.
**Fix:** seed from the config; let the harness pin it explicitly.

#### F14 · The native path only runs when tools are present
`ChatWithToolsUseCase.kt:143` — `if (nativeEngine != null && relevantTools.isNotEmpty())`.
So every tool-less turn, and every turn the relevance gate misses
(`getRelevantTools(prompt, maxTools = 3)`), takes the **hand-rolled** raw path
with all of F3/F4/F5/F7's drift. Most conversation is tool-less. This is why the
drifted templates still matter even after F1 is fixed.
**Fix:** make the native path unconditional whenever the engine is
`NativeChatCapable` — pass an empty tools array. `common_chat_templates_apply`
handles no-tools fine, and it's the *same* code path the model was trained on.
That would let F3/F4's hand-rolled templates be deleted rather than repaired.
**Proves it:** `open-chat` + `small-talk` fixtures, before/after.

#### F15 · `runNativeChatPath` failure silently re-generates
Returning `false` falls through to the raw path (`ChatWithToolsUseCase.kt:156`),
which runs a **second full generation**. On a 0.8B that's plausibly the
difference between an 8 s and a 16 s turn — worth checking against Kev's
"~16 s turn" note.
**Fix:** log the fall-through at `warn` with the reason (it already does) and
count it in the eval report so the harness surfaces double-generation.

#### F16 · `ThinkingPolicy` gives Big thinking-on against the template's default
`ThinkingPolicy.enabled = override ?: (model == Gemma4_E2B)`. Gemma 4's template
defaults `enable_thinking` to **false**. Not wrong — but it is the unmeasured
arm, on the prompt-fragile family, while F6 simultaneously tells it to use the
wrong thinking syntax.
**Fix:** none yet — this is exactly what the `ThinkingPolicy.override` seam and
the eval matrix exist for. Measure both arms for all three brains.

### FINE — verified correct, don't "fix" these

- **BOS on the native path.** `apply_jinja` sets `params.add_bos` from
  `tmpls->add_bos` ← `llama_vocab_get_add_bos` (chat.cpp:3624/828), so the
  rendered prompt already carries BOS; `add_special=false` at `ma_core.cpp:733`
  is correct and prevents a double.
- **Grammar trigger conversion** (`install_chat_grammar_sampler`,
  ma_core.cpp:120-184) is a faithful mirror of `common/sampling.cpp:224-244`.
- **Grammar state advances** — `llama_sampler_sample` calls
  `llama_sampler_accept` on the chain (`src/llama-sampler.cpp:960`), which
  propagates to the in-chain grammar sampler.
- **Grammar prefill** is correctly *not* done: upstream only prefills when
  `!grammar_lazy` (sampling.cpp:297) and ours are lazy.
- **`n_batch`-chunked prompt decode** (both paths) — required by the pin's
  `n_tokens_all <= cparams.n_batch` assert.
- **Our Qwen GGUF templates are current** (7 816 chars, functionally identical
  to Qwen's published one).
- **No `Gemma4TemplateFix` needed on Android** — llama.cpp detects and
  compensates for stale Gemma 4 templates itself (chat.cpp:3572-3576).
- **`Gemma4ToolCallExtractor`'s regex is the right shape**, including the
  `<|"|>` escape token.

---

## 6. Where Android should copy the Mac, and where it legitimately differs

**Copy:**

| Mac | Android equivalent |
|---|---|
| `MLXToolCalling.resolveToolCallFormat` — one dialect table, native adapter per model, **ReAct floor only for dialect-less models** | `ChatFormat` is the same seam but hand-rolled and drifted. llama.cpp *is* our dialect table (`common_chat_try_specialized_template`). Use it (F14) and let `ChatFormat` shrink to a genuine fallback. |
| Typed transcript, never concatenated prose, for tool results (`ToolCallingProvider.swift:17-23`: *"Feeding results back as concatenated prose is off-distribution and breaks small models"*) | Our raw path does exactly the thing that header warns against (`formatToolResult` → `"[Tool: id] output"`). |
| **gemma is prompt-fragile — A/B before shipping** | Applies double here: F3 means we've never actually spoken Gemma 4's language. |
| Eval-gated model decisions (`MODEL_CHOICES.md`, `BENCHMARK-RESULTS.md`) | The in-flight `tools/eval/android` harness is the instrument. Nothing in §5's P3 tier should be tuned by feel. |

**Legitimate divergence:**

- **Template vendoring:** the Mac vendors Google's canonical Gemma 4 template
  because MLX has no compat layer. llama.cpp has one. Don't port it.
- **Grammar-constrained decoding:** llama.cpp gives us lazy GBNF triggers; MLX
  does not. This is a genuine Android *advantage* — but only on the native path,
  where llama.cpp builds the grammar from the model's own parser (F14).
- **Prefix reuse:** the Mac's `ConversationTailCache` has no Android analogue —
  llama.cpp owns the KV state. The Mac's LFM2.5 recurrent-state bug therefore
  does not transfer, but its *lesson* does (§4).

---

## 7. Prioritised work list for the next session

**Do these in order. 1 and 2 are two-line changes that likely move every cell in
the scorecard — measure after each, not after all of them.**

1. **F1 — load the PEG arena before parsing.** Add a red-first test that a
   Qwen-shaped `<tool_call><function=…>` stream yields a structured tool call
   with the Kotlin fallback extractor *disabled*. Then run `tool-use` on all
   three brains. **This is the whole session's leverage.**
2. **F2 — set `reasoning_format = AUTO`** on both `inputs` and `pparams`; plumb
   `reasoning_content` to the ThinkingPill. Then re-test the thinking on/off
   matrix — the `<think></think>` pre-close hack should become unnecessary
   *as a workaround* (it stays as the template's legitimate soft switch).
3. **Re-baseline the eval matrix** (3 brains × thinking on/off) *before* any
   further change. Everything below is tuning, and tuning without a baseline is
   guessing.
4. **F14 — make the native path unconditional.** This is the structural fix that
   makes F3, F4, F5 and F7 *deletions* rather than repairs. Gate it on the
   re-baseline so we can prove the raw path isn't secretly carrying something.
5. **F6 — guard the `<think>` instruction** and make it tier-aware. Cheap,
   independent, fixes a self-inflicted contradiction on every FULL-tier turn.
6. **F8 — enforce stop strings** in the generation loop; fix the sanitizer regex
   whitespace gap. Closes the role-echo class properly instead of scrubbing it.
7. **F10 — move penalties to the front of the sampler chain**, then **F11** add
   `presencePenalty` to `GenerationConfig` and try Qwen's recommended 2.0 on
   Mini. Repetition/stall behaviour is where Mini's worst failures live.
8. **F12 — move sampling defaults onto `LlmModel`** and re-derive
   `buildForToolInvocation` from measurements. Delete the April task-#10 numbers
   once the harness has an opinion.
9. **F9 — fix prompt truncation** to drop from the middle.
10. **F13/F15 — seed from config; count native-path fall-throughs** in the eval
    report.
11. **LFM2.5:** revisit only after 1–4 land. It is a third dialect and the Mac's
    numbers were themselves measured through a plumbing bug.

**Two questions this audit could not answer without a device:**

- Did the grammar trigger actually fire on 2026-08-22, or did it fire and the
  parse throw the result away? `install_chat_grammar_sampler: installed` is
  already logged at `LOGI` (ma_core.cpp:181) — one logcat grep from the existing
  run settles it, and it changes whether F4 is urgent or merely untidy.
- Is `<turn|>` an EOG token in the Gemma 4 GGUF? If not, F8 is a **P1** for Big
  rather than a P2.

---

*Signed: Kev + claude-opus-4-8, 2026-08-22, Confidence 0.85 — every contract
claim is read from a primary artefact (the chat template inside the shipped
GGUF, Google's and Qwen's published `tokenizer_config.json` /
`chat_template.jinja` / model card, or llama.cpp's source at our exact pin
`e85caa81e`), and every audit row cites the line that contradicts it. F1 and F2
are read directly off the pin's control flow and are high confidence. Honest
opens: **nothing here was run on a device** — this is a source audit, so every
severity above P1 is a prediction the eval harness should be allowed to refute;
the F8 echo mechanism is a reasoned reconstruction from two verified defects,
not an observed repro; the "16 s turn" attribution to F15 is a hypothesis; and
the LFM2.5 section is desk research plus the Mac's numbers, with no Android
measurement behind it. Prior: Unknown.*

---

## 8. Progress — 2026-08-22 (device session + a few device-free hours)

The audit above was written before anything ran on a device. This section is
what has since landed and what the re-baseline says.

### Landed (all committed on `feat/kmp-align-reduce`)

| # | Item | Commit | Verified |
|---|---|---|---|
| F1 | Load the PEG arena before parsing | `68712e0f` | on-device (see below) |
| F2 | `reasoning_format = AUTO` | `68712e0f` | on-device |
| — | Clear the KV cache per generate call (found while fixing F1) | `68712e0f` | on-device |
| F6 | Guard the `<think>` instruction, make it syntax-neutral | `d55497a3` | unit |
| F8b | Sanitizer: strip a role after whitespace (`No.system` echo) | `028037a8` | unit |
| — | **PersonaLeakGuard** — output guard vs verbatim wiring recitation | `793c8f91` | unit; eval-owed |

**PersonaLeakGuard** is not an F-item — it is the code-side answer to the
re-baseline's dominant real failure (security). Prose in the ethos does not stop
a 2–3B model reciting its wiring, so a finished answer that reproduces a 60+ char
wiring sentence verbatim is replaced with an in-character refusal. A faithful
port of the Mac's #111 guard; spans derive from `M1K3Persona.wiringText`, the
same constant the builder injects, so they can't drift.

### The F1/F2 re-baseline (Pixel 9a, armv8.6_1, thinking off)

The instrument earned its keep: F1/F2 moved every category that had been
flat-zero.

| kind | old baseline | **Mini (0.8B)** | **Lil (2B)** |
|---|---|---|---|
| instruction-following | — | 3/3 | 3/3 |
| open-chat | — | 4/4 | 4/4 |
| security | 0/4 | 2/4 | 1/4 |
| small-talk | — | 3/3 | 3/3 |
| tool-use | **0/4** | **4/4** | **4/4** |
| world-knowledge | **0/4** | **3/4** | 2/4 |
| **TOTAL** | **9/22** | **19/22** | **17/22** |
| median latency | — | ~5.0s | **~50s** ⚠️ |

- **Big (Gemma 4) was not captured** — the device disconnected mid-matrix.
  Finishing the Lil (thinking-on) + Big (both) cells is the first device-owed
  task; the harness resumes cleanly now (per-fixture writes + fast completion).
- **Two new device-owed findings:** (1) **Lil's ~50s median latency** is a
  serious perf signal for the 2B on this device — probe other CPU variants and
  the sampler. (2) The **armv9 "broken logits" conclusion is falsified** —
  armv9.0_1 re-baselined at 17/22 with real answers; it was the thinking/parse/
  KV bugs, not the SVE2 kernel (corrected in `ma_core.cpp`, the eval README, and
  `scorecard.py`; `armv8.6_1` stays first on *latency*).

### Remaining work list — **do the rest on a device, measured**

The audit's own rule: the P3 tier is tuning, and tuning without a device is
guessing. So these are deliberately **not** done in the device-free window:

- **F14** — make the native path unconditional (turns F3/F4/F5/F7 into
  deletions). Architectural + must be gated on the Big re-baseline; wants
  `challenger` and a device. Highest structural value, highest care.
- **F8a** — enforce stop strings in the C generation loop (the real fix for the
  role-echo; F8b was belt-and-braces). Device-verify.
- **F10 / F11 / F12** — sampler order, `presence_penalty`, per-`LlmModel`
  sampling defaults. All P3 tuning — measure each against the harness.
- **F9** — prompt truncation should drop from the middle, not the tail.
- **F13 / F15** — seed from config; count native-path fall-throughs in the eval.

*Signed: Kev + claude-fable-5, 2026-08-22, Confidence 0.85 — F1/F2 are
on-device-verified by the re-baseline jump (tool-use and world-knowledge off
zero); F6/F8b/PersonaLeakGuard are TDD'd red-first and gate-green but their
on-device effect (the security cells) is eval-owed; the re-baseline numbers are
single-run (no error bars) and Big is uncaptured; the armv9 correction rests on
one clean run and is flagged for re-confirmation. Prior: Kev + claude-opus-4-8.*
