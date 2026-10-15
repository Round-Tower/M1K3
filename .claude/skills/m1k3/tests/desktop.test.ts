import { describe, expect, mock, test } from 'claude-code/testing'

import type { RenderInput } from 'claude-code'

import { COLS, ROWS } from '../hooks/face-math'

/** The band above the prompt in the desktop app's Code tab. */
const BAND: RenderInput<'AbovePrompt'> = {
  component: 'AbovePrompt',
  surface: 'desktop',
  requestId: 'band',
  viewport: { columns: 160, rows: 40 },
  props: { hasSurvey: false, isWorking: false, maxRows: 8, bodyColumns: 120, scroll: { offset: 0, bodyRows: 8 }, view: {} },
}

describe('desktop', () => {
  test('the face band validates and draws on the desktop surface', async ($, on) => {
    mock.clock(on, { now: 1_000 })
    mock.store(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('command.register', ($, e) => ({ value: { command: e.name } }))
    on('fs.exists', () => ({ value: false }))
    on('ui.status', () => ({ value: undefined }))

    await $.session.start({ surface: 'desktop', isInteractive: true, cwd: '/work' })
    const ui = await $.ui.mount({ plugin: 'm1k3', ...BAND })
    const svg = await ui.find({ type: 'Svg' })
    expect(svg).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /M1K3/ })).toBeDefined()
    await ui.unmount()

    // Legible, not an empty box: each LED fills most of its pitch, and the
    // drawing is big enough to read beside the caption.
    const source: unknown = Reflect.get(Reflect.get(svg ?? {}, 'props') ?? {}, 'source')
    expect(typeof source, 'the Svg carries its markup as props.source').toBe('string')
    const leds = [...String(source).matchAll(/<rect x="\d+" y="\d+" width="(\d+)"/g)].map(m => Number(m[1]))
    expect(leds.length).toBe(COLS * ROWS)
    expect(Math.min(...leds)).toBeGreaterThanOrEqual(8)
  })
})
