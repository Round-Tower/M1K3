// M1K3 as Claude Code's voice: when a session needs the person, or finishes a
// long turn, the live app says so through its own MCP server (`speak`), over
// the connection `m1k3 connect claude` set up. With the app not running, or
// the server not connected, the line becomes a toast instead (register.tsx).
//
// Pure: what to say and for how long. The call itself is the hook's.
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.75 (the lines are pinned; what
// the app does with them rides its own `speak` tool). Prior: Unknown
// Review: Kev + Claude, 2026-10-05 — summoned pass on #493: a finished turn says
// "Done after N seconds." alone unless `readAnswers` is on (the first sentence
// read aloud on an open-plan Mac is the person's call); the call gets a bound
// and a gap (SPEAK_TIMEOUT_MS, SPEAK_GAP_MS) in register.tsx. Confidence 0.8.

import { firstWords } from './avatar-state'

/** The server's name as /mcp lists it (M1K3CLICore/ConnectPlan.serverName). */
export const SERVER = 'm1k3'
/** Turns shorter than this end quietly; the band already shows them. */
export const LONG_TURN_MS = 20_000
/** A `speak` that has not answered by then is given up on (the line toasts instead). */
export const SPEAK_TIMEOUT_MS = 8_000
/** Lines closer together than this toast rather than queue speech behind speech. */
export const SPEAK_GAP_MS = 10_000

export type Line = { text: string; emotion: string }

export type VoiceEvent =
  | { kind: 'permission'; message: string }
  | { kind: 'idle' }
  | { kind: 'done'; answer: string; seconds: number; readAnswer?: boolean }
  | { kind: 'failed'; reason: string }

export function lineFor(event: VoiceEvent): string {
  switch (event.kind) {
    case 'permission': return `Claude Code needs you: ${firstWords(event.message, 80)}`
    case 'idle': return 'Claude Code is waiting for you.'
    case 'done': {
      const done = `Done after ${Math.round(event.seconds)} seconds.`
      return event.readAnswer ? `${done} ${firstSentence(event.answer)}`.trim() : done
    }
    case 'failed': return event.reason === 'refusal' ? 'Claude Code stopped: the model refused.' : 'Claude Code stopped on an error.'
  }
}

export function firstSentence(text: string): string {
  const plain = text.replace(/[`*_#>]/g, '').replace(/\s+/g, ' ').trim()
  const end = plain.search(/[.!?](\s|$)/)
  return firstWords(end > 0 ? plain.slice(0, end + 1) : plain, 140)
}

/** Roughly how long the app takes to say it, so the band's mouth moves meanwhile. */
export const speakingMs = (text: string): number => Math.min(8000, 300 + text.split(/\s+/).length * 380)

/** What to say for a notification, or nothing. */
export function voiceForNotification(kind: string, message: string): Line | undefined {
  if (kind === 'permission_prompt') return { text: lineFor({ kind: 'permission', message }), emotion: 'thinking' }
  if (kind === 'idle_prompt') return { text: lineFor({ kind: 'idle' }), emotion: 'neutral' }
  return undefined
}

/** What to say when a turn ends, or nothing: long answers and failures only. */
export function voiceForTurn(reason: string, answer: string, durationMs: number, readAnswer = false): Line | undefined {
  if (reason === 'answer') {
    return durationMs >= LONG_TURN_MS ? { text: lineFor({ kind: 'done', answer, seconds: durationMs / 1000, readAnswer }), emotion: 'happy' } : undefined
  }
  if (reason === 'error' || reason === 'refusal') return { text: lineFor({ kind: 'failed', reason }), emotion: 'sad' }
  return undefined
}

/** Whether a line may be spoken now, given when the last one was. */
export const maySpeak = (now: number, lastSpokeAt: number): boolean => now - lastSpokeAt >= SPEAK_GAP_MS
