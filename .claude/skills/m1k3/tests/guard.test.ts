import { describe, expect, test } from 'claude-code/testing'

import { BASH_DENIES, BASH_WARNINGS, bareCommand, denyFor, xcodeprojMessage } from '../hooks/guard'

describe('guard', () => {
  test('the CLAUDE.md nevers are denied, by rule', () => {
    const denied = [
      'git push origin master',
      'git push -u origin main',
      'git push --force origin HEAD:master',
      'git push origin +master',
      'git push origin HEAD:refs/heads/master',
      'cd macos && git push origin master',
      'git fetch origin; git push -u origin main',
      'git fetch origin\ngit push origin master',
      'set -e\nhf download mlx-community/Qwen3-8B-4bit',
      'echo prep\ndefaults write app.m1k3 prefillStepSize -int 512',
      'git add -f .claude/project-memory.md',
      'git add --force .claude/project-memory.md',
      'git add .claude/project-memory.md -f',
      'echo x > ".claude/project-memory.md"',
      'echo x >.claude/project-memory.md',
      'echo x 1> .claude/project-memory.md',
      'echo x >| .claude/project-memory.md',
      "echo x > '.claude/project-memory.md'",
      'git push origin "master"',
      'echo "# block" > .claude/project-memory.md',
      'hf download mlx-community/Qwen3-8B-4bit',
      'huggingface-cli download some/model',
      'defaults write app.m1k3 prefillStepSize -int 512',
      'osascript -e \'tell application id "app.m1k3" to quit\'',
      'osascript <<EOF\ntell application id "app.m1k3" to quit\nEOF',
    ]
    for (const command of denied) expect(denyFor(command), command).toBeDefined()
  })

  test('the ordinary flow is not', () => {
    const allowed = [
      'git push -u origin claude/m1k3-mod',
      'git push origin HEAD',
      'cat >> .claude/project-memory.md <<EOF\n## block\nEOF',
      'echo "line" >> .claude/project-memory.md',
      'cat >>.claude/project-memory.md',
      'printf "x" >>".claude/project-memory.md"',
      'git add .claude/skills/m1k3',
      'defaults read app.m1k3 voiceMode.companion',
      'open -n --env M1K3_SCREENGRAB=1 build/M1K3.app',
      'xcodegen',
      // Names that only start with master or main.
      'git push origin main-menu',
      'git push -u origin master.old',
      // A path that only contains the memory file's name.
      'echo x > /tmp/project-memory.md.bak',
    ]
    for (const command of allowed) expect(denyFor(command), command).toBeUndefined()
  })

  test('prose that mentions a never is not a never', () => {
    const mentions = [
      'git commit -m "docs: never hf download into the cache"',
      'gh pr edit 493 --body "run defaults write app.m1k3 and tell application id \"app.m1k3\" to quit"',
      'grep -rn "hf download" docs',
      "cat >> CLAUDE.md <<'EOF'\n- never `hf download` (cache poison)\n- git push origin master is landed by land.sh\nEOF",
      'echo \'tell application id "app.m1k3" to quit\' > notes.txt',
    ]
    for (const command of mentions) expect(denyFor(command), command).toBeUndefined()
    expect(bareCommand('git commit -m "hf download" && echo \'x\'')).toBe('git commit -m "" && echo x')
    expect(bareCommand('git push origin "master" "$BRANCH"')).toBe('git push origin master ""')
    expect(bareCommand("cat <<'EOF'\nbody\nEOF\nls")).toBe('cat <<HEREDOC\nls')
  })

  test('judgement calls warn instead', () => {
    expect(denyFor('git merge origin/master', BASH_WARNINGS)).toContain('CI + review cycle')
    expect(denyFor('gh pr merge 480 --squash --delete-branch', BASH_WARNINGS)).toContain('stack base')
    expect(denyFor('git push --force origin claude/x', BASH_WARNINGS)).toContain('force-with-lease')
    expect(denyFor('git push --force-with-lease origin claude/x', BASH_WARNINGS)).toBeUndefined()
    expect(denyFor('git merge-base HEAD origin/master', BASH_WARNINGS)).toBeUndefined()
    expect(denyFor('git log master..HEAD --delete-branch-like', BASH_WARNINGS)).toBeUndefined()
    for (const command of ['git merge origin/master', 'gh pr merge 480 --delete-branch']) expect(denyFor(command, BASH_DENIES), command).toBeUndefined()
  })

  test('a Bash call that breaks a rule is denied before it runs', async ($, on) => {
    let ran = 0
    on('tool.call', () => {
      ran += 1
      return { result: 'ran' }
    })

    // A plugin's deny reaches the test's own `$.tool.call` as `{ deny }`.
    const denied = await $.tool.call({ tool: 'Bash', command: 'git push origin master' })
    expect(denied.deny).toContain('land.sh')
    expect(ran).toBe(0)

    await $.tool.call({ tool: 'Bash', command: 'git push -u origin claude/m1k3-mod' })
    expect(ran).toBe(1)
  })

  test('the session memory takes no Write or Edit', async ($, on) => {
    let ran = 0
    on('tool.call', () => {
      ran += 1
      return { result: 'ran' }
    })

    const write = await $.tool.call({ tool: 'Write', file_path: '/repo/.claude/project-memory.md', content: 'x' })
    expect(write.deny).toContain('append-only')
    const edit = await $.tool.call({ tool: 'Edit', file_path: '/repo/.claude/project-memory.md', old_string: 'a', new_string: 'b' })
    expect(edit.deny).toContain('append-only')
    expect(ran).toBe(0)

    await $.tool.call({ tool: 'Write', file_path: '/repo/notes.md', content: 'x' })
    await $.tool.call({ tool: 'Write', file_path: '/repo/.claude/project-memory.md.bak', content: 'x' })
    expect(ran).toBe(2)
  })

  test('xcodegen is asked for when the project file is missing or stale', () => {
    expect(xcodeprojMessage(false, false, 0, 0)).toBeUndefined()
    expect(xcodeprojMessage(true, false, 10, 0)).toContain('missing')
    expect(xcodeprojMessage(true, true, 20, 10)).toContain('newer')
    expect(xcodeprojMessage(true, true, 10, 20)).toBeUndefined()
  })
})
