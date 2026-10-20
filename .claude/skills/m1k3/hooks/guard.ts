// CLAUDE.md's "nevers" as enforced rules. A `tool.call` hook that returns
// `{ deny }` stops the call before the permission check; the reason reaches the
// model as the tool's error, so it can choose the right thing instead.
//
// Denies are the explicit nevers. Rules that need judgement (a master merge
// that resolves a conflict, a stack base) get a toast, not a deny. Every rule
// reads the command with its quoted spans and heredoc bodies blanked, so a
// commit message or a PR body that merely mentions a phrase never trips it;
// the one rule that lives inside quotes by nature (the AppleScript quit) reads
// the raw command and needs `osascript` beside it. Best effort by design: a
// `tee`, `cp` or `sed -i` onto the session memory is not caught, nor a push
// whose refspec comes after a later flag (`git push origin HEAD --force master`),
// nor a command wrapped in `bash -c`, `eval`, `git -C` or `git -c`, nor a
// redirect onto an expansion (`> "$PWD/.claude/project-memory.md"`): a quoted
// word with `$` in it is prose to the rules, since its value is unknown here.
// The file tools' path is matched as spelled: a `..` hop or a symlink onto the
// memory is not resolved (`$.fs.stat(path, { resolve: true })` could, later).
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.85 (every rule is pinned by
// tests/guard.test.ts, denies, allows and the prose cases alike). Prior: Unknown
// Review: Kev + Claude, 2026-10-05 — summoned pass on #493: rules anchored to a
// command boundary and read off the blanked command (quoted mentions, heredocs,
// `main-menu`, `merge-base` no longer match); `+master`, `refs/heads/master` and
// `git add <file> -f` now do. Confidence 0.85.
// Review: Kev + Claude, 2026-10-05 — second pass: a newline is a command boundary
// too (multi-line Bash is how a push to master would most likely slip through).
// Review: Kev + Claude, 2026-10-05 — auto pass on the Swift head: a quoted path or
// refspec is kept bare, not blanked (`> ".claude/project-memory.md"`, `"master"`);
// the file tools' pattern ends at the name, like the Bash one.
// Review: Kev + Claude, 2026-10-05 — second auto pass: `>>` with no space
// (`cat >>.claude/project-memory.md`) is the sanctioned append, not a replace.
// Review: Kev + claude-opus-5-5, 2026-10-15 — the master/main push deny is this checkout's:
// when the last `cd` before the push resolves outside it (`$HOME` for `~`), the push runs
// (Kev's agent-context push was refused). Unresolvable targets keep the deny. Confidence 0.8.
// Review: same day (2), pre-push review fold — a worktree's main checkout and any M1K3 folder
// stay M1K3; a cd that doesn't persist (closed subshell, `$(…)`, `&`, `|`) doesn't count; every
// push must leave; `..` resolved; no checkout, no exemption. Confidence 0.8.

import type { On } from 'claude-code'

export type Rule = { test: RegExp; reason: string; raw?: true }

// The session memory, twice on purpose: a tool's `file_path` is the whole path
// (so `$`), a Bash command carries it as one word among others (so a lookahead).
// Either way `project-memory.md.bak` is not it.
const MEMORY = /\.claude\/project-memory\.md$/
const MEMORY_PATH = String.raw`\.claude\/project-memory\.md(?=\s|$)`
/** Where a command may start: a line, or after a separator, with the usual wrappers. */
const AT_START = String.raw`(?:^|[;&|(\n]|\|\||&&)\s*(?:sudo\s+|time\s+|env\s+(?:\S+=\S*\s+)*|[A-Z_]+=\S*\s+)*`

export const BASH_DENIES: readonly Rule[] = [
  {
    test: new RegExp(`${AT_START}git\\s+push\\b(?:\\s+-\\S+)*\\s+\\S+\\s+\\+?(?:\\S+:)?(?:refs\\/heads\\/)?(?:master|main)(?=[\\s;&|)]|$)`),
    reason: 'never a direct push to master: push the branch and land it with macos/tools/ci/land.sh',
  },
  {
    test: new RegExp(`${AT_START}git\\s+add\\b(?=[^\\n;&|]*\\s(?:-\\S*f\\S*|--force)(?=\\s|$))(?=[^\\n;&|]*${MEMORY_PATH})`),
    reason: '.claude/project-memory.md is gitignored on purpose and never force-added',
  },
  {
    test: new RegExp(String.raw`(?:^|[^>])>(?!>)[|&]?\s*\S*${MEMORY_PATH}`),
    reason: '.claude/project-memory.md is append-only: use >> to add a block, never > to replace it',
  },
  {
    test: new RegExp(`${AT_START}(?:hf|huggingface-cli)\\s+download(?=\\s|$)`),
    reason: 'never pre-seed the model cache with hf download (cache poison); let the app fetch and verify weights',
  },
  {
    test: new RegExp(`${AT_START}defaults\\s+write\\s+app\\.m1k3(?=\\s|$)`),
    reason: 'defaults write app.m1k3 never reaches the sandboxed app on macOS 27: pass A/B overrides as argv (M1K3 -prefillStepSize 512)',
  },
  {
    // Inside quotes by nature, so read raw; `osascript` beside it is what makes it a run, not a mention.
    test: /\bosascript\b[\s\S]*tell\s+application\s+id\s+"app\.m1k3"/,
    reason: 'tell application id "app.m1k3" quits the live app too: stop a worktree build by PID',
    raw: true,
  },
]

export const BASH_WARNINGS: readonly Rule[] = [
  {
    test: new RegExp(`${AT_START}git\\s+merge(?=\\s|$)[^\\n;&|]*\\s(?:origin\\/)?(?:master|main)(?=\\s|$)`),
    reason: 'merging master into a PR branch costs a full CI + review cycle: only for a conflict or a fix the PR needs',
  },
  {
    test: new RegExp(`${AT_START}gh\\s+pr\\s+merge\\b[^\\n;&|]*\\s--delete-branch(?=\\s|$)`),
    reason: '--delete-branch on a stack base closes its dependants: retarget them first (gh pr edit <N> --base master)',
  },
  {
    test: new RegExp(`${AT_START}git\\s+push\\b[^\\n;&|]*\\s(?:--force|-f)(?=\\s|$)`),
    reason: 'a plain --force rewrites history for everyone on the branch: --force-with-lease, and never on someone else\'s branch',
  },
]

/**
 * The command with its quoted spans and heredoc bodies blanked, so the rules
 * read what runs and never the prose it carries (a commit message, a PR body,
 * a grep pattern, a CLAUDE.md edit).
 */
export function bareCommand(command: string): string {
  return command
    // A heredoc body: from the line after `<<WORD` (quoted or not, `<<-` too) to the line holding WORD.
    .replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n[\s\S]*?\n[ \t]*\2(?=\s|$)/g, '<<HEREDOC')
    // A quoted word stays (a quoted path or refspec is a normal shell habit); quoted prose is blanked.
    .replace(/"((?:[^"\\]|\\[\s\S])*)"/g, (_, inner: string) => (isBareWord(inner) ? inner : '""'))
    .replace(/'([^']*)'/g, (_, inner: string) => (isBareWord(inner) ? inner : "''"))
}

/** One argument with nothing the shell would read: no whitespace, quotes, expansions or operators. */
const isBareWord = (text: string): boolean => text.length > 0 && !/[\s"'`$;&|<>()\\]/.test(text)

export function denyFor(command: string, rules: readonly Rule[] = BASH_DENIES): string | undefined {
  const bare = bareCommand(command)
  return rules.find(rule => rule.test.test(rule.raw ? command : bare))?.reason
}

const PUSH_DENY = BASH_DENIES[0]!

/** The checkout a plugin at `<checkout>/.claude/skills/<name>` was loaded from; undefined otherwise. */
export function checkoutOf(pluginRoot: string): string | undefined {
  return /^(.+)\/\.claude\/skills\/[^/]+\/?$/.exec(pluginRoot)?.[1]
}

/** `..` and `.` segments resolved, trailing slashes dropped. */
function normalise(path: string): string {
  const parts: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') parts.pop()
    else parts.push(part)
  }
  return `/${parts.join('/')}`
}

/** Whether `path` is this repo: under the checkout, under the main checkout of a worktree, or any M1K3 folder. */
function isOwnRepo(path: string, checkout: string): boolean {
  const main = checkout.replace(/\/\.claude\/worktrees\/[^/]+$/, '')
  const name = (main.split('/').at(-1) ?? '').toLowerCase()
  const under = (root: string): boolean => path === root || path.startsWith(`${root}/`)
  return under(checkout) || under(main) || (name !== '' && path.toLowerCase().split('/').some(part => part.includes(name)))
}

/** Where a `cd` may start: a line or a separator, or a subshell's `(` (the push must then share it). */
const CD = /(?:^|;|&&|\|\||\n|\()\s*cd\s+([^\s;&|)]+)/g

/**
 * Whether every push to master/main in `command` runs in another repo: the last
 * `cd` before each names an absolute or `~` path that is not M1K3. The guard
 * keeps M1K3's master; a sibling repo pushing its own main is its business
 * (2026-10-14: `cd ~/.agent-context; git push origin main` was refused). A `cd`
 * that doesn't persist to the push (a closed subshell, `$(…)`, a backgrounded or
 * piped `cd`) doesn't count, and anything unresolvable (no home or checkout,
 * `cd -`, a `$VAR`, a relative hop) stays in the checkout, so the deny stands.
 */
export function leavesCheckout(command: string, home: string | undefined, checkout: string | undefined): boolean {
  if (checkout === undefined) return false
  const bare = bareCommand(command)
  const pushes = [...bare.matchAll(new RegExp(PUSH_DENY.test.source, 'g'))]
  if (pushes.length === 0) return false
  return pushes.every((push) => {
    const before = bare.slice(0, push.index) // the push's own boundary (`&&`, `;`) is not between
    const cd = [...before.matchAll(CD)].at(-1)
    if (cd === undefined) return false
    // The push's own boundary counts: a lone `&` or `|` there backgrounds or pipes the `cd`.
    const between = before.slice(cd.index + cd[0].length) + bare.slice(push.index, push.index + 2)
    if (/\)|(?<![&|])[&|](?![&|])/.test(between)) return false
    const target = cd[1] ?? ''
    const path = target === '~' || target.startsWith('~/')
      ? (home === undefined ? undefined : home + target.slice(1))
      : target.startsWith('/') ? target : undefined
    return path !== undefined && !isOwnRepo(normalise(path), checkout)
  })
}

export const MEMORY_DENY = '.claude/project-memory.md is append-only; add a block with `cat >> .claude/project-memory.md`'

/** The matched `tool.call` hooks: Bash commands, and the two file tools on the session memory. */
export function registerGuard(on: On): void {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = e.command.trim()
    const reason = denyFor(command)
    if (reason !== undefined) {
      const elsewhere = reason === PUSH_DENY.reason
        && leavesCheckout(command, await $.env.get('HOME').catch(() => undefined), checkoutOf($.plugin.root))
      if (!elsewhere) return { deny: `${$.plugin.name} guard: ${reason}` }
    }
    const warning = denyFor(command, BASH_WARNINGS)
    if (warning !== undefined) $.ui.toast(`${$.plugin.name} guard: ${warning}`, { timeoutMs: 8000 })
    return next(e)
  })

  // A `Write` replaces the whole file: that is how 700 lines were lost on
  // 2026-09-15. `Edit` can drop a block just as silently, so it is refused too
  // (a typo in the chronicle stays; the chronicle is append-only). Appending
  // goes through the shell with >>.
  on('tool.call', { tool: 'Write' }, ($, e, next) => (MEMORY.test(e.file_path) ? { deny: `${$.plugin.name} guard: ${MEMORY_DENY}` } : next(e)))
  on('tool.call', { tool: 'Edit' }, ($, e, next) => (MEMORY.test(e.file_path) ? { deny: `${$.plugin.name} guard: ${MEMORY_DENY}` } : next(e)))
}

/**
 * `xcodegen` after every checkout: the project file is a gitignored artifact.
 * `undefined` when it is current (or this is not the M1K3 checkout).
 */
export function xcodeprojMessage(hasSpec: boolean, hasProject: boolean, specMtimeMs: number, projectMtimeMs: number): string | undefined {
  if (!hasSpec) return undefined
  if (!hasProject) return 'xcodegen: M1K3.xcodeproj is missing (run xcodegen in macos/)'
  return specMtimeMs > projectMtimeMs ? 'xcodegen: project.yml is newer than M1K3.xcodeproj (run xcodegen in macos/)' : undefined
}
