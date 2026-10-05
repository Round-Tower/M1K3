import { describe, expect, mock, test } from 'claude-code/testing'

import type { RenderElement, RenderInput } from 'claude-code'

import { FOX_CLIPS, clipFor, frameIndex, framePath, gaitFor } from '../hooks/companion'
import { lineFor, firstSentence, speakingMs, voiceForNotification, voiceForTurn } from '../hooks/voice'

/** The band above the prompt on a 160-column terminal, nothing else holding it. */
const BAND: RenderInput<'AbovePrompt'> = {
  component: 'AbovePrompt',
  surface: 'terminal',
  requestId: 'band',
  viewport: { columns: 160, rows: 40 },
  props: { hasSurvey: false, isWorking: false, maxRows: 8, bodyColumns: 120, scroll: { offset: 0, bodyRows: 8 }, view: {} },
}

/** A rendered tree's text as it reads: its strings and labels, in order. */
function textOf(tree: unknown): string {
  if (typeof tree === 'string' || typeof tree === 'number') return String(tree)
  if (Array.isArray(tree)) return tree.map(textOf).join('')
  if (typeof tree !== 'object' || !tree) return ''
  const props: unknown = Reflect.get(tree, 'props')
  const label = typeof props === 'object' && props ? Reflect.get(props, 'label') : undefined
  return `${typeof label === 'string' ? label : ''}${textOf(Reflect.get(tree, 'children') ?? [])}`
}

describe('companion', () => {
  test('gaits follow ClipMapper.gait(for:)', () => {
    expect(gaitFor({ emotion: 'neutral', activity: 'idle' })).toBe('rest')
    expect(gaitFor({ emotion: 'sleepy', activity: 'idle' })).toBe('sleepy')
    expect(gaitFor({ emotion: 'thinking', activity: 'thinking' })).toBe('alert')
    expect(gaitFor({ emotion: 'thinking', activity: 'listening' })).toBe('alert')
    expect(gaitFor({ emotion: 'excited', activity: 'generating' })).toBe('move')
    expect(gaitFor({ emotion: 'happy', activity: 'speaking' })).toBe('move')
    expect(gaitFor({ emotion: 'angry', activity: 'error' })).toBe('distress')
    // The choreographer's beats: delight after an answer, a warm beat for love.
    expect(gaitFor({ emotion: 'happy', activity: 'idle' })).toBe('react')
    expect(gaitFor({ emotion: 'love', activity: 'idle' })).toBe('affection')
  })

  test('the fox dialect collapses eight gaits onto its three clips', () => {
    expect(new Set(Object.values(FOX_CLIPS))).toEqual(new Set(['Survey', 'Walk', 'Run']))
    expect(clipFor({ emotion: 'neutral', activity: 'idle' })).toBe('Survey')
    expect(clipFor({ emotion: 'excited', activity: 'generating' })).toBe('Walk')
    expect(clipFor({ emotion: 'angry', activity: 'error' })).toBe('Run')
    expect(clipFor({ emotion: 'happy', activity: 'idle' })).toBe('Run')
  })

  test('frames loop with the clip and never run off its end', () => {
    const walk = { frames: 12, duration: 0.71 }
    expect(frameIndex(walk, 0)).toBe(0)
    expect(frameIndex(walk, 0.355)).toBe(6)
    expect(frameIndex(walk, 0.71)).toBe(0)
    expect(frameIndex(walk, 0.7099)).toBe(11)
    expect(frameIndex(walk, 100.5)).toBeLessThan(12)
    expect(framePath('/p', 'phosphor', 'Run', 7)).toBe('/p/assets/frames/phosphor-Run-07.png')
  })
})

describe('voice', () => {
  test('lines are short and name what happened', () => {
    expect(lineFor({ kind: 'permission', message: 'Claude needs your permission to use Bash' })).toBe('Claude Code needs you: Claude needs your permission to use Bash')
    expect(lineFor({ kind: 'idle' })).toBe('Claude Code is waiting for you.')
    expect(lineFor({ kind: 'done', answer: '**Pushed.** The band toggles; tests cover both surfaces.', seconds: 61.4 })).toBe('Done after 61 seconds. Pushed.')
    expect(lineFor({ kind: 'failed', reason: 'refusal' })).toContain('refused')
  })

  test('only long turns and failures are spoken', () => {
    expect(voiceForTurn('answer', 'Done.', 5_000)).toBeUndefined()
    expect(voiceForTurn('answer', 'Done.', 25_000)?.emotion).toBe('happy')
    expect(voiceForTurn('aborted', '', 90_000)).toBeUndefined()
    expect(voiceForTurn('error', '', 1_000)?.text).toContain('error')
    expect(voiceForNotification('permission_prompt', 'Bash?')?.emotion).toBe('thinking')
    expect(voiceForNotification('auth_success', '')).toBeUndefined()
  })

  test('the first sentence is what gets read out, markdown stripped', () => {
    expect(firstSentence('# Done\n\nI pushed `fix`. Then more.')).toBe('Done I pushed fix.')
    expect(speakingMs('one two three')).toBe(300 + 3 * 380)
    expect(speakingMs('word '.repeat(100))).toBe(8000)
  })

  test('with the app unreachable the line becomes a toast, and the band shows the error face', async ($, on) => {
    const toasts: string[] = []
    const statuses: (string | undefined)[] = []
    const clock = mock.clock(on, { now: 1_000 })
    mock.store(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('command.register', ($, e) => ({ value: { command: e.name } }))
    on('fs.exists', () => ({ value: false }))
    on('ui.status', ($, e) => {
      statuses.push(e.text)
      return { value: undefined }
    })
    on('mcp.call', () => {
      throw new Error('not connected')
    })
    on('ui.toast', ($, e) => {
      toasts.push(e.text)
      return { value: undefined }
    })
    on('turn.start', ($, e) => ({ turnId: e.turnId }))
    on('turn.complete', ($, e) => ({ text: e.answer }))

    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    expect(statuses, 'no xcodegen nag outside the M1K3 checkout').toEqual([])
    expect(textOf(await $.ui.render(BAND))).toContain('M1K3 · Ready')

    await $.turn.start({ text: 'add a /face toggle', turnId: 't1' })
    expect(textOf(await $.ui.render(BAND))).toContain('Thinking…')
    expect(textOf(await $.ui.render(BAND))).toContain('add a /face toggle')

    await $.turn.complete({ reason: 'error', answer: '', durationMs: 1000, isAborted: false, turnId: 't1' })
    await clock.settle()
    expect(toasts).toEqual(['Claude Code stopped on an error.'])
    expect(textOf(await $.ui.render(BAND))).toContain('Error')

    // The error face holds a beat, then settles to sad.
    await clock.advance(1_600)
    expect(textOf(await $.ui.render(BAND))).toContain('Ready · sad')
  })

  test('a quick answer ends quietly; a long one is spoken through the app', async ($, on) => {
    const spoken: unknown[] = []
    const clock = mock.clock(on, { now: 1_000 })
    mock.store(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('command.register', ($, e) => ({ value: { command: e.name } }))
    on('fs.exists', () => ({ value: false }))
    on('ui.status', () => ({ value: undefined }))
    on('mcp.call', ($, e) => {
      spoken.push(e.args)
      return { value: { content: [{ type: 'text', text: 'Speaking.' }], isError: false } }
    })
    on('turn.complete', ($, e) => ({ text: e.answer }))
    on('ui.render', () => h('Text', {}, 'engine') as RenderElement)

    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.turn.complete({ reason: 'answer', answer: 'Quick.', durationMs: 3_000, isAborted: false, turnId: 't1' })
    await clock.settle()
    expect(spoken).toEqual([])
    expect(textOf(await $.ui.render(BAND))).toContain('Ready · happy')

    await $.turn.complete({ reason: 'answer', answer: 'Pushed. The band toggles.', durationMs: 61_000, isAborted: false, turnId: 't2' })
    await clock.settle()
    expect(spoken).toEqual([{ text: 'Done after 61 seconds. Pushed.', emotion: 'happy' }])
    expect(textOf(await $.ui.render(BAND))).toContain('Speaking…')

    // /face hides the band; the engine then draws its own.
    const { text } = await $.command.run({ command: 'face', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
    expect(text).toBe('M1K3 band hidden.')
    expect(textOf(await $.ui.render(BAND))).toBe('engine')
  })
})
