// What M1K3 looks like right now, derived from the session's events, and which
// avatar draws it. Values live in `$.state` (the contract is types/index.d.ts)
// so a hot reload and every reader of the band see the same thing.
//
// Pure: the transitions take the event and answer the mood to set. The hooks
// in register.tsx hold the atoms and make the `$` calls (the engine refuses
// `$` as an argument, and reads an atom only where it is a const of the file).
//
// The transitions mirror AvatarState.fromActivity and the CompanionChoreographer's
// beats (a react one-shot when the answer lands, Sit after a long quiet).
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.8 (pure and pinned by
// tests/companion.test.ts through the gaits they drive). Prior: Unknown

import { fromActivity, type AvatarState, type Emotion } from './face-math'
import type { Avatar, Mood } from '../types'

export const AVATARS: readonly Avatar[] = ['face', 'fox', 'phosphor', 'off']

/** How long the happy beat after an answer, and the error face, hold. */
export const SETTLE_MS = 2500
export const ERROR_MS = 1500
/** A quiet half hour drifts the face to sleepy. */
export const SLEEPY_AFTER_MS = 30 * 60 * 1000

/** A mood to set, with the band's second line, and what follows it after a beat. */
export type Change = { state: AvatarState; note?: string; then?: { afterMs: number; state: AvatarState; note?: string } }

const idle = (emotion: Emotion = 'neutral'): AvatarState => ({ emotion, activity: 'idle' })

export const onSessionStart = (): Change => ({ state: idle(), note: 'Waiting for you.' })

export const onTurnStart = (text: string): Change => ({ state: fromActivity('thinking'), note: text ? firstWords(text, 48) : 'Thinking.' })

/** Before a tool runs: the generating face, unless the session is idle (a plugin's own call). */
export const onToolStart = (current: Mood, tool: string, input: Record<string, unknown>): Change | undefined =>
  current.activity === 'idle' ? undefined : { state: fromActivity('generating'), note: `${tool}${describe(input)}` }

/** After a tool ran: the error face for a beat on a failure, else back to thinking. */
export function onToolEnd(wasIdle: boolean, isError: boolean, tool: string): Change | undefined {
  if (isError) return { state: fromActivity('error'), note: `${tool} failed`, then: { afterMs: ERROR_MS, state: fromActivity('thinking') } }
  return wasIdle ? undefined : { state: fromActivity('thinking') }
}

/** A permission prompt or an idle prompt: Claude Code is waiting on the person. */
export function onNotification(kind: string, message: string): Change | undefined {
  if (kind === 'permission_prompt') return { state: fromActivity('listening'), note: `Needs you: ${firstWords(message, 40)}` }
  if (kind === 'idle_prompt') return { state: fromActivity('listening'), note: 'Waiting for you.' }
  return undefined
}

export function onTurnComplete(reason: string): Change {
  if (reason === 'answer') return { state: idle('happy'), note: 'Done.', then: { afterMs: SETTLE_MS, state: idle(), note: 'Waiting for you.' } }
  if (reason === 'error' || reason === 'refusal') {
    return {
      state: { emotion: 'angry', activity: 'error' },
      note: reason === 'refusal' ? 'The model refused.' : 'The turn errored.',
      then: { afterMs: ERROR_MS, state: idle('sad'), note: 'Waiting for you.' },
    }
  }
  return { state: idle(), note: 'Interrupted.' }
}

/** The idle tick: sleepy once a quiet half hour has passed, else nothing. */
export const onQuiet = (current: Mood, now: number, lastActivityAt: number): Change | undefined =>
  current.activity === 'idle' && current.emotion !== 'sleepy' && now - lastActivityAt >= SLEEPY_AFTER_MS
    ? { state: idle('sleepy'), note: 'Quiet for a while.' }
    : undefined

/** Speaking, then back to neutral once the utterance should be over (unless a later mood took over). */
export const onSpeak = (text: string, forMs: number): Change => ({ state: fromActivity('speaking'), note: text, then: { afterMs: forMs, state: idle() } })

export function firstWords(text: string, max: number): string {
  const line = text.replace(/\s+/g, ' ').trim()
  return line.length <= max ? line : `${line.slice(0, max - 1).trimEnd()}…`
}

function describe(input: Record<string, unknown>): string {
  const arg = typeof input.command === 'string' ? input.command : typeof input.file_path === 'string' ? input.file_path : typeof input.pattern === 'string' ? input.pattern : ''
  return arg ? ` ${firstWords(arg, 36)}` : ''
}
