// The fox companion from baked sprite frames (assets/, rendered from the
// Khronos Fox GLB: see assets/ATTRIBUTION.md). The gait and clip rules are
// M1K3Avatar's ClipMapper + CompanionDialect.fox, ported verbatim; crossfades
// do not exist with sprites, so clips snap and the one-shot beats hide it.
//
// Pure: paths, parsing and timing. The reads are the hooks' (register.tsx).
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.8 (the mapping is pinned by
// tests/companion.test.ts; the image tier's fallback is verify-by-launch).
// Prior: Kev + claude-opus-4-8 (CompanionSpec.swift, 2026-06-11)

import type { Mood } from '../types'

export type Look = 'fox' | 'phosphor'
export type Gait = 'rest' | 'alert' | 'move' | 'react' | 'distress' | 'sleepy' | 'affection' | 'fidget'
export type ClipMeta = { frames: number; duration: number; svgFrames: number }
export type Manifest = { frameWidth: number; frameHeight: number; looks: Record<Look, Record<string, ClipMeta>> }
export type BrailleClip = { frames: number; duration: number; band: string[][]; pane: string[][] }

/** The band's slot for a companion, in cells: a 2:1 frame over six rows. */
export const BAND_COLUMNS = 24
export const BAND_ROWS = 6

/** The braille colour per look: the phosphor green, or the fox's coat. */
export const BRAILLE_COLOUR: Record<Look, number> = { fox: 0xe8873a, phosphor: 0x79ffb0 }

/** ClipMapper.gait(for:), with the choreographer's one-shot beats folded in. */
export function gaitFor(mood: Pick<Mood, 'emotion' | 'activity'>): Gait {
  switch (mood.activity) {
    case 'error': return 'distress'
    case 'listening': case 'thinking': return 'alert'
    case 'generating': case 'speaking': return 'move'
    case 'idle':
      if (mood.emotion === 'sleepy') return 'sleepy'
      if (mood.emotion === 'happy' || mood.emotion === 'excited' || mood.emotion === 'surprised') return 'react'
      if (mood.emotion === 'love') return 'affection'
      return 'rest'
  }
}

/** CompanionDialect.fox.clipName(for:): three clips carry eight gaits. */
export const FOX_CLIPS: Record<Gait, string> = {
  rest: 'Survey', alert: 'Survey', sleepy: 'Survey', fidget: 'Survey',
  move: 'Walk',
  react: 'Run', distress: 'Run', affection: 'Run',
}

export const clipFor = (mood: Pick<Mood, 'emotion' | 'activity'>): string => FOX_CLIPS[gaitFor(mood)]

/** Which frame of a looping clip shows `elapsed` seconds after it started. */
export function frameIndex(meta: { frames: number; duration: number }, elapsed: number): number {
  const phase = ((elapsed % meta.duration) + meta.duration) % meta.duration
  return Math.min(meta.frames - 1, Math.floor((phase / meta.duration) * meta.frames))
}

export const manifestPath = (root: string): string => `${root}/assets/manifest.json`
export const braillePath = (root: string, look: Look, clip: string): string => `${root}/assets/braille/${look}-${clip}.json`
export const stripPath = (root: string, look: Look, clip: string): string => `${root}/assets/svg/${look}-${clip}.png`
export const framePath = (root: string, look: Look, clip: string, index: number): string =>
  `${root}/assets/frames/${look}-${clip}-${String(index).padStart(2, '0')}.png`

export const parseManifest = (text: string): Manifest => JSON.parse(text) as Manifest
export const parseBraille = (text: string): BrailleClip => JSON.parse(text) as BrailleClip

export function clipMeta(manifest: Manifest, look: Look, clip: string): ClipMeta {
  const meta = manifest.looks[look]?.[clip]
  if (meta === undefined) throw new Error(`m1k3: no baked clip ${look}/${clip}`)
  return meta
}

/** A once-per-path cache for the asset reads; a reload starts it over, cheaply. */
export class Loaded<T> {
  private pending = new Map<string, Promise<T>>()
  get(key: string, load: () => Promise<T>): Promise<T> {
    let value = this.pending.get(key)
    if (value === undefined) {
      value = load()
      this.pending.set(key, value)
    }
    return value
  }
}
