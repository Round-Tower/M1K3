// CLAUDE.md's "nevers" as enforced rules. A `tool.call` hook that returns
// `{ deny }` stops the call before the permission check; the reason reaches the
// model as the tool's error, so it can choose the right thing instead.
//
// Denies are the explicit nevers. Rules that need judgement (a master merge
// that resolves a conflict, a stack base) get a toast, not a deny.
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.85 (every rule is pinned by
// tests/guard.test.ts, denies and allows alike). Prior: Unknown

import type { On } from 'claude-code'

export type Rule = { test: RegExp; reason: string }

const MEMORY = /\.claude\/project-memory\.md/

export const BASH_DENIES: readonly Rule[] = [
  {
    test: /\bgit\s+push\b(?:\s+-\S+)*\s+\S+\s+(?:\S+:)?(?:master|main)\b/,
    reason: 'never a direct push to master: push the branch and land it with macos/tools/ci/land.sh',
  },
  {
    test: /\bgit\s+add\s+(?:-\S*f\S*|--force)\b.*project-memory\.md/,
    reason: '.claude/project-memory.md is gitignored on purpose and never force-added',
  },
  {
    test: /(?:^|[^>])>\s*\S*project-memory\.md/,
    reason: '.claude/project-memory.md is append-only: use >> to add a block, never > to replace it',
  },
  {
    test: /\b(?:hf|huggingface-cli)\s+download\b/,
    reason: 'never pre-seed the model cache with hf download (cache poison); let the app fetch and verify weights',
  },
  {
    test: /\bdefaults\s+write\s+app\.m1k3\b/,
    reason: 'defaults write app.m1k3 never reaches the sandboxed app on macOS 27: pass A/B overrides as argv (M1K3 -prefillStepSize 512)',
  },
  {
    test: /tell\s+application\s+id\s+"app\.m1k3"/,
    reason: 'tell application id "app.m1k3" quits the live app too: stop a worktree build by PID',
  },
]

export const BASH_WARNINGS: readonly Rule[] = [
  {
    test: /\bgit\s+merge\b.*\b(?:origin\/)?(?:master|main)\b/,
    reason: 'merging master into a PR branch costs a full CI + review cycle: only for a conflict or a fix the PR needs',
  },
  {
    test: /--delete-branch\b/,
    reason: '--delete-branch on a stack base closes its dependants: retarget them first (gh pr edit <N> --base master)',
  },
  {
    test: /\bgit\s+push\b.*\s--force(?:\s|$)/,
    reason: 'a plain --force rewrites history for everyone on the branch: --force-with-lease, and never on someone else\'s branch',
  },
]

export const denyFor = (command: string, rules: readonly Rule[] = BASH_DENIES): string | undefined =>
  rules.find(rule => rule.test.test(command))?.reason

export const MEMORY_DENY = '.claude/project-memory.md is append-only; add a block with `cat >> .claude/project-memory.md`'

/** The matched `tool.call` hooks: Bash commands, and the two file tools on the session memory. */
export function registerGuard(on: On): void {
  on('tool.call', { tool: 'Bash' }, ($, e, next) => {
    const command = e.command.trim()
    const reason = denyFor(command)
    if (reason !== undefined) return { deny: `${$.plugin.name} guard: ${reason}` }
    const warning = denyFor(command, BASH_WARNINGS)
    if (warning !== undefined) $.ui.toast(`m1k3 guard: ${warning}`, { timeoutMs: 8000 })
    return next(e)
  })

  // A `Write` replaces the whole file: that is how 700 lines were lost on
  // 2026-09-15. `Edit` can drop a block just as silently. Both are refused;
  // appending goes through the shell with >>.
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
