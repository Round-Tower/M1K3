// The pixel face, ported line for line from macos/Sources/M1K3Avatar
// (FaceGrid.swift + FaceExpression.swift) so the terminal draws the same face
// the app does. Pure and deterministic: every phase derives from `time`.
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.85 (a port; tests/face.test.ts
// pins the same cells FaceExpressionTests does). Prior: Kev + claude-sonnet-4-6
// (FaceExpression.swift, 2026-06-08)

export type Emotion =
  | 'neutral' | 'happy' | 'sad' | 'angry' | 'surprised' | 'love' | 'thinking' | 'excited' | 'sleepy'
export type Activity = 'idle' | 'listening' | 'thinking' | 'generating' | 'speaking' | 'error'
export type AvatarState = { emotion: Emotion; activity: Activity }

export const COLS = 13
export const ROWS = 11
const LEFT_EYE = { col: 4, row: 3 }
const RIGHT_EYE = { col: 8, row: 3 }
const MOUTH_ROW = 7
const MOUTH_COLS = { from: 3, to: 9 }
const CENTRE_COL = Math.floor(COLS / 2)
const BACKGROUND = 0.06

/** AvatarActivity.isActive: faster animation while engaged. */
export const isActive = (activity: Activity): boolean => activity !== 'idle' && activity !== 'error'

/** AvatarState.fromActivity: emotion follows the task. */
export function fromActivity(activity: Activity): AvatarState {
  const emotion: Record<Activity, Emotion> = {
    idle: 'neutral', listening: 'thinking', thinking: 'thinking',
    generating: 'excited', speaking: 'happy', error: 'angry',
  }
  return { emotion: emotion[activity], activity }
}

/** AvatarActivity.statusLabel(isRecording: false): the badge idiom. */
export function statusLabel(activity: Activity): string {
  const names: Record<Activity, string> = {
    idle: 'Ready', listening: 'Listening…', thinking: 'Thinking…',
    generating: 'Generating…', speaking: 'Speaking…', error: 'Error',
  }
  return names[activity]
}

/** AvatarEmotion.accentColor (M1K3App/AvatarEmotion+SwiftUI.swift), as 0xRRGGBB. */
export const ACCENT: Record<Emotion, number> = {
  neutral: 0x8e8e93, happy: 0x34c759, sad: 0x0a84ff, angry: 0xff453a, surprised: 0xffd60a,
  love: 0xff375f, thinking: 0xbf5af2, excited: 0xff9900, sleepy: 0x617d8c,
}

// Swift's `.rounded()` rounds half away from zero; JS Math.round rounds half up.
const roundAway = (x: number): number => (x < 0 ? -Math.round(-x) : Math.round(x))
// Swift's truncatingRemainder, for the non-negative times this is fed.
const mod = (a: number, b: number): number => a - Math.floor(a / b) * b

const cellPhase = (col: number, row: number): number => mod(col * 12.9898 + row * 78.233, 6.2831853)

/** A short blink window (~140 ms every 3.5 s). */
export const isBlinking = (time: number): boolean => mod(time, 3.5) < 0.14

/** Idle saccade: every 5.3 s the pupils dart one cell sideways for half a second. */
export function saccadeOffset(time: number): number {
  const period = 5.3
  const phase = mod(time, period)
  if (phase < 2.0 || phase >= 2.5) return 0
  return Math.floor(time / period) % 2 === 0 ? 1 : -1
}

function oneEye(col: number, row: number, anchor: { col: number; row: number }, state: AvatarState, time: number): number {
  if (isBlinking(time) || state.emotion === 'sleepy') {
    return row === anchor.row && Math.abs(col - anchor.col) <= 1 ? 0.9 : 0
  }
  if (state.emotion === 'happy' || state.emotion === 'excited' || state.emotion === 'love') {
    const onArc = (row === anchor.row && Math.abs(col - anchor.col) === 1) || (row === anchor.row - 1 && col === anchor.col)
    return onArc ? 1 : 0
  }
  if (state.emotion === 'surprised') {
    const onPlus = (col === anchor.col && Math.abs(row - anchor.row) <= 1) || (row === anchor.row && Math.abs(col - anchor.col) <= 1)
    return onPlus ? 1 : 0
  }
  let pupilCol = anchor.col
  let pupilRow = anchor.row
  if (state.activity === 'thinking') {
    pupilRow -= 1
    pupilCol += roundAway(Math.sin(time * 1.3))
  } else if (state.activity === 'idle') {
    pupilCol += saccadeOffset(time)
  }
  return col === pupilCol && row === pupilRow ? 1 : 0
}

const eyeIntensity = (col: number, row: number, state: AvatarState, time: number): number =>
  Math.max(oneEye(col, row, LEFT_EYE, state, time), oneEye(col, row, RIGHT_EYE, state, time))

const curlSign = (emotion: Emotion): number =>
  emotion === 'happy' || emotion === 'excited' || emotion === 'love' ? 1 : emotion === 'sad' || emotion === 'angry' ? -1 : 0

function mouthRows(col: number, state: AvatarState, time: number): number[] {
  const distance = Math.abs(col - CENTRE_COL)
  if (state.emotion === 'surprised' && state.activity !== 'speaking') {
    return distance <= 1 ? [MOUTH_ROW, MOUTH_ROW + 1] : []
  }
  const curveRow = MOUTH_ROW - curlSign(state.emotion) * Math.floor(distance / 2)
  const rows = [curveRow]
  if (state.activity === 'speaking') {
    const open = 1 + roundAway(1.5 * (0.5 + 0.5 * Math.sin(time * 9)))
    for (let extra = 1; extra <= open; extra++) rows.push(curveRow + extra)
  }
  return rows
}

const mouthIntensity = (col: number, row: number, state: AvatarState, time: number): number =>
  col < MOUTH_COLS.from || col > MOUTH_COLS.to ? 0 : mouthRows(col, state, time).includes(row) ? 1 : 0

/** Horizontal CRT-style tear while erroring, in cell units; zero outside `.error`. */
export function columnShift(row: number, state: AvatarState, time: number): number {
  if (state.activity !== 'error') return 0
  const sweep = 0.9
  const phase = mod(time, sweep) / sweep
  const tearRow = Math.floor(phase * ROWS)
  if (row === tearRow) return 0.55
  if (row === tearRow + 1) return -0.35
  return 0
}

/** Brightness 0…1 for a cell. */
export function intensity(col: number, row: number, state: AvatarState, time: number): number {
  const feature = Math.max(eyeIntensity(col, row, state, time), mouthIntensity(col, row, state, time))
  let base = Math.max(BACKGROUND, feature)
  if (columnShift(row, state, time) !== 0) base = Math.max(base, 0.3)
  const flicker = 1 + 0.06 * Math.sin(time * 7 + cellPhase(col, row))
  return Math.min(Math.max(base * flicker, 0), 1)
}

/**
 * The whole 13×11 grid for one instant, row-major. A terminal shifts whole
 * cells, so the tear is rounded (one row jumps a cell, the next only glows).
 */
export function frame(state: AvatarState, time: number): number[][] {
  const grid: number[][] = []
  for (let row = 0; row < ROWS; row++) {
    const shift = roundAway(columnShift(row, state, time))
    const torn = columnShift(row, state, time) !== 0
    const cells: number[] = []
    for (let col = 0; col < COLS; col++) {
      const source = col - shift
      cells.push(source >= 0 && source < COLS ? intensity(source, row, state, time) : torn ? 0.3 : BACKGROUND)
    }
    grid.push(cells)
  }
  return grid
}

/** `accent` scaled by `level` over black, as 0xRRGGBB. */
export function shade(accent: number, level: number): number {
  const r = Math.round(((accent >> 16) & 0xff) * level)
  const g = Math.round(((accent >> 8) & 0xff) * level)
  const b = Math.round((accent & 0xff) * level)
  return (r << 16) | (g << 8) | b
}
