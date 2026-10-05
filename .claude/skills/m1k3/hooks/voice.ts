// M1K3 as Claude Code's voice: when a session needs the person, or finishes a
// long turn, the live app says so through its own MCP server (`speak`), over
// the connection `m1k3 connect claude` set up. With the app not running, or
// the server not connected, the line becomes a toast instead (register.tsx).
//
// Pure: what to say and for how long. The call itself is the hook's.
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.75 (the lines are pinned; what
// the app does with them rides its own `speak` tool). Prior: Unknown

import { firstWords } from './avatar-state'

/** The server's name as /mcp lists it (M1K3CLICore/ConnectPlan.serverName). */
export const SERVER = 'm1k3'
/** Turns shorter than this end quietly; the band already shows them. */
export const LONG_TURN_MS = 20_000

export type Line = { text: string; emotion: string }

export type VoiceEvent =
  | { kind: 'permission'; message: string }
  | { kind: 'idle' }
  | { kind: 'done'; answer: string; seconds: number }
  | { kind: 'failed'; reason: string }

export function lineFor(event: VoiceEvent): string {
  switch (event.kind) {
    case 'permission': return `Claude Code needs you: ${firstWords(event.message, 80)}`
    case 'idle': return 'Claude Code is waiting for you.'
    case 'done': return `Done after ${Math.round(event.seconds)} seconds. ${firstSentence(event.answer)}`.trim()
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
export function voiceForTurn(reason: string, answer: string, durationMs: number): Line | undefined {
  if (reason === 'answer') return durationMs >= LONG_TURN_MS ? { text: lineFor({ kind: 'done', answer, seconds: durationMs / 1000 }), emotion: 'happy' } : undefined
  if (reason === 'error' || reason === 'refusal') return { text: lineFor({ kind: 'failed', reason }), emotion: 'sad' }
  return undefined
}
