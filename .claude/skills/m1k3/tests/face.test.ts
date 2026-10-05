import { describe, expect, test } from 'claude-code/testing'

import { COLS, ROWS, columnShift, frame, fromActivity, intensity, isBlinking, saccadeOffset, statusLabel } from '../hooks/face-math'
import { FACE_COLUMNS, FACE_ROWS, brailleCells, faceCells, packCells, toBase64 } from '../hooks/raster'

const lit = (grid: number[][]) => grid.flatMap((row, r) => row.map((level, c) => (level > 0.5 ? `${c},${r}` : '')).filter(Boolean))

describe('face', () => {
  test('the resting face is two pupils and a flat mouth, as FaceExpressionTests pins', () => {
    // t = 1.0: no blink (phase 1.0 of 3.5), no saccade (phase 1.0 of 5.3).
    const cells = lit(frame({ emotion: 'neutral', activity: 'idle' }, 1.0))
    expect(cells).toContain('4,3')
    expect(cells).toContain('8,3')
    for (let c = 3; c <= 9; c++) expect(cells, `mouth at ${c}`).toContain(`${c},7`)
    expect(cells.length).toBe(9)
  })

  test('a blink closes both eyes to a three-cell line', () => {
    expect(isBlinking(0.05)).toBe(true)
    expect(isBlinking(1.0)).toBe(false)
    const state = { emotion: 'neutral' as const, activity: 'idle' as const }
    expect(intensity(4, 3, state, 0.05)).toBeGreaterThan(0.8)
    expect(intensity(3, 3, state, 0.05)).toBeGreaterThan(0.8)
    expect(intensity(4, 2, state, 0.05)).toBeLessThan(0.1)
  })

  test('idle saccades alternate direction and never lock step with the blink', () => {
    expect(saccadeOffset(2.2)).toBe(1)
    expect(saccadeOffset(5.3 + 2.2)).toBe(-1)
    expect(saccadeOffset(1.0)).toBe(0)
  })

  test('emotion follows the task', () => {
    expect(fromActivity('generating')).toEqual({ emotion: 'excited', activity: 'generating' })
    expect(fromActivity('error')).toEqual({ emotion: 'angry', activity: 'error' })
    expect(statusLabel('idle')).toBe('Ready')
    expect(statusLabel('thinking')).toBe('Thinking…')
  })

  test('the smile curls up, the frown down, surprise opens an O', () => {
    const happy = lit(frame({ emotion: 'happy', activity: 'idle' }, 1.0))
    expect(happy).toContain('3,6') // the smile's end rises
    expect(happy).toContain('4,2') // the arc eye's peak
    const sad = lit(frame({ emotion: 'sad', activity: 'idle' }, 1.0))
    expect(sad).toContain('3,8')
    const surprised = lit(frame({ emotion: 'surprised', activity: 'idle' }, 1.0))
    expect(surprised).toContain('6,8')
  })

  test('the error tear shears one row and rounds to whole cells', () => {
    const state = { emotion: 'angry' as const, activity: 'error' as const }
    const shifts = Array.from({ length: ROWS }, (_, row) => columnShift(row, state, 0.3))
    expect(shifts.filter(s => s !== 0).length).toBe(2)
    const grid = frame(state, 0.3)
    expect(grid.length).toBe(ROWS)
    expect(grid.every(row => row.length === COLS)).toBe(true)
  })

  test('cells pack as little-endian u32 triplets in padded base64', () => {
    expect(toBase64(new Uint8Array([]))).toBe('')
    expect(toBase64(new Uint8Array([0x4d]))).toBe('TQ==')
    expect(toBase64(new Uint8Array([0x4d, 0x61]))).toBe('TWE=')
    expect(toBase64(new Uint8Array([0x4d, 0x61, 0x6e]))).toBe('TWFu')
    // One orange full block on the default background: the RasterProps example.
    expect(packCells([{ glyph: 0x2588, fg: 0xff8800, bg: 0x01000000 }])).toBe(toBase64(new Uint8Array([0x88, 0x25, 0, 0, 0, 0x88, 0xff, 0, 0, 0, 0, 1])))
  })

  test('a face frame fills its 13 by 6 box; braille rows fill theirs', () => {
    const packed = faceCells({ emotion: 'neutral', activity: 'idle' }, 1.0)
    expect(packed.length).toBe(Math.ceil((FACE_COLUMNS * FACE_ROWS * 12) / 3) * 4)
    const rows = ['⣿ ⡇', '  ⠁']
    expect(brailleCells(rows, 0x79ffb0).length).toBe(Math.ceil((2 * 3 * 12) / 3) * 4)
  })
})
