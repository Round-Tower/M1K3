# M1K3 localisation glossary and style guide

The rules every translation of M1K3's interface follows, human or LLM. Wave one is
German (`de`), French (`fr`), Spanish (`es`) and Brazilian Portuguese (`pt-BR`); Japanese
is the next wave. The source language is `en`, written in en-GB spelling (Kev, 2026-11-19).

The plumbing is `tools/l10n/xcstrings_l10n.py` (export → draft → apply → coverage →
review sheet); the CI gate is `tools/ci/check_string_catalogs.py`.

## Voice and register

M1K3 talks like a friend: first person, plain, warm, a little playful. The store copy
already set the register, and the app matches it:

| Locale | Address | From the store copy |
|---|---|---|
| de | **du** (lower-case), never Sie | „Sprich mit mir“, „Bring dein eigenes Wissen mit“ |
| fr | **tu**, never vous | « Parle-moi », « Apporte tes connaissances » |
| es | **tú**, never usted or vosotros | „Háblame“, „Trae tu propio conocimiento“ |
| pt-BR | **você** | „Fale comigo“, „Traga seu conhecimento“ |

- **Spanish is one `es` for Spain and Latin America.** Prefer words both read naturally
  ("añadir" and "agregar" are both fine; avoid "ordenador"/"computadora" by saying "Mac"
  or "dispositivo"). An `es-419` split is a later call, not wave one.
- Interface labels (buttons, menu items, settings titles) are short and neutral, in the
  imperative or infinitive the platform uses: de infinitive („Chat umbenennen“), fr
  infinitive (« Renommer la discussion »), es infinitive („Cambiar nombre“), pt-BR
  infinitive („Renomear conversa“).
- Sentences M1K3 says about itself stay in the first person („Ich merke mir …“).

## Never translate

Brand, tier, character and product names are names, not words:

- **M1K3**, **Mike** (M1K3's nickname)
- The brains: **Mini**, **Lil**, **Big**, **Pocket**
- **Brain at Home** (the feature's name; the sentence around it is translated)
- **Local API** (the OpenAI-compatible server's feature name; the wave-one drafts kept it in all four languages)
- Companions: **Phosphor Fox**, **Fox**, **Inkfish**, **Sparrow**, **Gecko**, **Colobus** (Kev, 2026-11-19: characters, like Mike)
- Apple names as Apple ships them in that language: **Apple Intelligence**, **Private Cloud
  Compute**, **Apple Silicon**, **Siri**, **VoiceOver**, **iCloud**, **Mac**, **iPhone**, **iPad**
- Third parties: **WhisperKit**, **Kokoro**, **OpenDyslexic**, **Silkscreen**, **Hugging Face**
  (huggingface.co), **GitHub**, **DuckDuckGo**, **Wikipedia**, **Markdown**, **MCP**, **QR**
- Anything inside a format argument, `${…}` parameter or code span.

## Apple's own terms

Use the word Apple's own localisation uses, so M1K3 reads like the rest of the Mac:

| en | de | fr | es | pt-BR |
|---|---|---|---|---|
| Settings (M1K3's window) | Einstellungen | Réglages | Ajustes | Ajustes |
| System Settings | Systemeinstellungen | Réglages Système | Ajustes del Sistema | Ajustes do Sistema |
| menu bar | Menüleiste | barre des menus | barra de menús | barra de menus |
| Shortcuts (the app) | Kurzbefehle | Raccourcis | Atajos | Atalhos |
| Live Activity | Live-Aktivität | Activité en direct | Actividad en vivo | Atividade ao Vivo |
| Notes (the app) | Notizen | Notes | Notas | Notas |
| Photos (the app) | Fotos | Photos | Fotos | Fotos |
| Files (the app) | Dateien | Fichiers | Archivos | Arquivos |
| Dictation | Diktierfunktion | Dictée | Dictado | Ditado |
| Focus | Fokus | Concentration | Enfoque | Foco |

## M1K3's words

Settled by the store copy; the per-language term tables the translation run builds
(`docs/l10n/terms-<locale>.json`) extend these and win on any word they list.

| en | de | fr | es | pt-BR |
|---|---|---|---|---|
| brain (Mini/Lil/Big) | Hirn | cerveau | cerebro | cérebro |
| on-device | auf dem Gerät / On-Device- | sur l’appareil | en el dispositivo | no dispositivo |
| memory (what M1K3 remembers) | Gedächtnis | mémoire | memoria | memória |
| a memory (one remembered fact) | Erinnerung | souvenir | recuerdo | lembrança |
| companion | Begleiter | compagnon | compañero | companheiro |
| web search | Websuche | recherche web | búsqueda web | busca na web |

## Typography

- **de:** „…“ quotes, `…` ellipsis, no space before `:`. Nouns capitalised; compound
  nouns joined or hyphenated (`On-Device-Suche`), never split with a space.
- **fr:** « … » quotes with a non-breaking space inside; a non-breaking space (U+00A0)
  before `:` `;` `!` `?` and inside « »; typographic apostrophe `’`.
- **es:** `¿…?` and `¡…!` open and close; “…” quotes.
- **pt-BR:** “…” quotes.
- Keep `…` (one character) where English has it; it marks a menu item that opens a window.

## Format arguments and markup

- Keep every `%@`, `%lld`, `%d`, `%f` and `%%`. To reorder arguments, number **all** of
  them (`%2$@ … %1$@`); never drop or re-kind one. `apply` rejects a draft that does.
- `${applicationName}` and every `${parameter}` (App Intents, App Shortcuts) stay exactly
  as written; every App Shortcuts phrase must contain `${applicationName}`.
- `^[%@ device](inflect: true)` is Apple's automatic grammar agreement and works in all
  four languages: translate the words inside the brackets and keep the markup
  (`^[%@ Gerät](inflect: true)`).
- A key with a single integer argument may vary by plural: give `one` and `other`
  (French `one` covers 0 and 1).
- Markdown in a value (`**bold**`, `[link](url)`) stays Markdown; never translate a URL.

## Length

German runs about a third longer than English. Buttons, toolbar items, tab titles and
menu items must fit the English width or close to it: pick the shorter correct word
(„Löschen“, not „Entfernen und löschen“). Body text and descriptions may run long.

## Privacy copy

Any line that says what leaves the device, what stays, who sees it, or asks permission
(Info.plist usage descriptions, web search, Private Cloud, Brain at Home, call recording,
exports, deletion) is drafted but held out of the catalogs in
`docs/l10n/pending-review.json`, so it renders in English until a native speaker reads it
(Kev, 2026-11-19, decision 3; master ships publicly in the nightly DMG).
`xcstrings_l10n.py review-sheet docs/l10n/pending-review.json <locale> <out.md>` prints the
lines; `apply docs/l10n/pending-review.json --approved --hold-review docs/l10n/pending-review.json
--locale <code>` writes one reader's approved lines and records each in `docs/l10n/approved.json`
with the English it was read against, so a later `sweep` or re-draft keeps it until that English
changes. Translate these **literally**: never soften or strengthen a promise.
A label of three words or fewer ("Delete", "Web search", "Always allow") names an action and makes
no promise, so it ships with the wave; the sentence that explains it stays held. A short label
that makes a claim ("Stays on device", "Private by design", "Fully local") is held.
"never", "only", "by default", "until you turn it on" carry the exact same force.

## Not in the catalogs, on purpose

The persona, the system prompt, the per-turn grounding, tool descriptions, the Local API
and CLI text, `PersonaLeakGuard.taughtDecline`, and replies the model reads back as history
stay English (plan 2026-11-18 §4). The brain answers in the person's language through the
reply-language clause (#870), not through translated prompts.

Signed: claude-opus-5-5, 2026-11-20, Confidence 0.8 (register and brand rules are Kev's
decisions and the shipped store copy; the Apple term table is from memory of Apple's
localisation and wants a native read, like the privacy copy). Prior: none (new file).
Review: claude-opus-5-5, 2026-11-20 — the approval command and its record (`approved.json`); short claims
are held. Confidence 0.8.
