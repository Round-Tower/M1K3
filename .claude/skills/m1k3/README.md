# m1k3 — the M1K3 mod for Claude Code

A Claude Code plugin of function hooks (a "mod": one `register(on, options)`
hooking the engine's events as `($, e, next)` functions). It loads by itself
in any Claude Code session opened in this checkout, from this folder, and
hot-reloads when a file here changes. Three things, one plugin:

| Part | What it does | Where |
|---|---|---|
| **guard** | CLAUDE.md's nevers as `tool.call` denies: a direct push to master, a `Write` or `Edit` over the append-only `.claude/project-memory.md` (or a `>` redirect onto it, or a `git add -f` of it), `hf download`, `defaults write app.m1k3`, `tell application id "app.m1k3"`. Judgement calls (a master merge, `--delete-branch`, a plain `--force`) toast instead. On `session.start` the status line says when `M1K3.xcodeproj` is missing or older than `project.yml`. | `hooks/guard.ts` |
| **voice** | When a session needs you (a permission prompt, an idle prompt) or ends a turn over 20 s, or fails, the live app says so through its own MCP server (`speak`, the `m1k3` server `m1k3 connect claude` registers). With the app unreachable, the line is a toast. `voice: false` in the plugin's config turns it off. | `hooks/voice.ts` |
| **avatar band** | The band above the prompt shows M1K3 reacting to the session: thinking on `turn.start`, generating while a tool runs, listening on a permission prompt, the error face on a failed tool, a happy beat on `turn.complete`, sleepy after a quiet half hour, speaking while the app speaks. The pixel face is `M1K3Avatar`'s `FaceExpression`, ported; the fox is baked frames of the Khronos Fox through `ClipMapper`'s fox dialect. | `hooks/register.tsx`, `face-math.ts`, `raster.ts`, `companion.ts`, `avatar-state.ts` |

## Commands

- `/face` hides or shows the band (`/face off`, `/face on`).
- `/companion face|fox|phosphor|off` picks the avatar; the pick is kept across sessions.

## How the avatar reaches each surface

| Surface | Face | Companion |
|---|---|---|
| Terminal, kitty graphics (kitty, Ghostty) | `Raster`: 13 × 6 cells of `▀`, two LED rows per cell, repainted by `$.ui.blit` at 30 fps active / 2 fps idle | `Image` by file path, one PNG per frame, swapped by `$.ui.blit` at the clip's rate; the terminal reads the file itself |
| Any other terminal | the same `Raster` | a braille `Raster` (24 × 6 cells, 48 × 24 dots, one colour). The first blit an `Image` refuses ("draws its alt") drops the session to this tier for good, and the choice is remembered |
| Desktop, VS Code, mobile | `Svg` of rounded rects, redrawn up to 4 times a second while active | `Svg` holding an 80 × 40 sprite strip with an SMIL `animate` on its x offset: it plays itself |

The colours are `AvatarEmotion.accentColor` scaled by each cell's intensity
over black, so the face reads on a dark terminal; a light theme gets a dark
face. Rendering costs no GPU: everything is baked or arithmetic, in the spirit
of `AvatarPresence` (nothing is painted while the band is hidden).

## Assets

`assets/` holds the fox's baked frames (both looks, three clips, 158 PNGs at
192 × 96), their braille reductions and the desktop strips, with
`assets/ATTRIBUTION.md`. The bake was three.js in headless Chromium over the
GLB; the other companions get the same treatment through
`macos/tools/companion-pipeline/` when they are wanted here.

## Developing

```sh
claude plugin validate .claude/skills/m1k3   # what the engine would refuse
claude plugin test .claude/skills/m1k3       # tests/*.test.ts against the engine
tsc -p .claude/skills/m1k3                   # once a session has laid .claude-plugin/types/
```

The engine writes `.claude-plugin/types/` beside the plugin when it loads it
(the API, the built-in tools, the connected MCP tools); it is gitignored.
Two engine rules shape the code: one unmatched hook per event per module, and
`$` only ever spelled `$.noun.method(...)`, never passed. So `register.tsx`
owns every event and every engine call, and the other files are pure.
