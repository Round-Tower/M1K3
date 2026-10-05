// Packing for the terminal's `Raster` leaf: `columns * rows` little-endian u32
// triplets [codePoint, foreground, background], standard padded base64. The
// module environment has no Buffer and may lack `Uint8Array.toBase64`, so the
// encoder lives here.
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.8 (the packing is pinned by
// tests/face.test.ts; how a terminal paints it is verify-by-launch). Prior: Unknown

import { ACCENT, COLS, ROWS, frame, shade, type AvatarState } from './face-math'

/** The terminal's default colour: bit 24 alone. */
export const DEFAULT_COLOUR = 0x01000000
const UPPER_HALF = 0x2580 // ▀: foreground paints the top half, background the bottom

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

export function toBase64(bytes: Uint8Array): string {
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i] ?? 0, b = bytes[i + 1] ?? 0, c = bytes[i + 2] ?? 0
    const hasB = i + 1 < bytes.length, hasC = i + 2 < bytes.length
    const n = (a << 16) | (b << 8) | c
    out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) + (hasB ? B64.charAt((n >> 6) & 63) : '=') + (hasC ? B64.charAt(n & 63) : '=')
  }
  return out
}

export type Cell = { glyph: number; fg: number; bg: number }

/** Encodes cells (row-major) as `RasterProps.cells`. */
export function packCells(cells: readonly Cell[]): string {
  const bytes = new Uint8Array(cells.length * 12)
  const view = new DataView(bytes.buffer)
  cells.forEach((cell, i) => {
    view.setUint32(i * 12, cell.glyph, true)
    view.setUint32(i * 12 + 4, cell.fg, true)
    view.setUint32(i * 12 + 8, cell.bg, true)
  })
  return toBase64(bytes)
}

/** The face's box in terminal cells: two LED rows per cell. */
export const FACE_COLUMNS = COLS
export const FACE_ROWS = Math.ceil(ROWS / 2)

/** One face frame as packed `Raster` cells: `▀` with the top LED as foreground, the bottom as background. */
export function faceCells(state: AvatarState, time: number): string {
  const grid = frame(state, time)
  const accent = ACCENT[state.emotion]
  const cells: Cell[] = []
  for (let r = 0; r < FACE_ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      const top = grid[2 * r]?.[c] ?? 0
      const bottom = grid[2 * r + 1]?.[c] ?? 0
      cells.push({ glyph: UPPER_HALF, fg: shade(accent, top), bg: shade(accent, bottom) })
    }
  }
  return packCells(cells)
}

/** Braille rows (one string per row, one glyph per cell) as packed cells in one colour. */
export function brailleCells(rows: readonly string[], colour: number): string {
  const cells: Cell[] = []
  for (const row of rows) {
    for (const glyph of row) {
      const code = glyph.codePointAt(0) ?? 0x20
      cells.push({ glyph: code, fg: colour, bg: DEFAULT_COLOUR })
    }
  }
  return packCells(cells)
}

/** The face as SVG markup for the desktop and editor surfaces, which have no `Raster`. */
export function faceSvg(state: AvatarState, time: number, size = 12): string {
  const grid = frame(state, time)
  const accent = ACCENT[state.emotion]
  const hex = `#${accent.toString(16).padStart(6, '0')}`
  const pad = 6
  const w = pad * 2 + COLS * size, h = pad * 2 + ROWS * size
  let rects = ''
  for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      const level = grid[r]?.[c] ?? 0
      const x = pad + c * size + 2, y = pad + r * size + 2
      rects += `<rect x="${x}" y="${y}" width="${size - 4}" height="${size - 4}" rx="1.5" fill="${hex}" fill-opacity="${(0.08 + 0.92 * level).toFixed(3)}"/>`
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}"><rect width="${w}" height="${h}" fill="#0e1013" rx="6"/>${rects}</svg>`
}

/**
 * A baked sprite strip as a self-animating SVG: an `<image>` stepped along x
 * by an SMIL animate. Plays itself, so the desktop gets no redraw traffic.
 */
export function spriteSvg(pngBase64: string, frames: number, durationSeconds: number, frameWidth = 80, frameHeight = 40): string {
  const values = Array.from({ length: frames }, (_, i) => -i * frameWidth).join(';')
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${frameWidth} ${frameHeight}" width="${frameWidth * 3}" height="${frameHeight * 3}">`
    + `<rect width="${frameWidth}" height="${frameHeight}" fill="#0e1013" rx="4"/>`
    + `<image href="data:image/png;base64,${pngBase64}" x="0" y="0" width="${frameWidth * frames}" height="${frameHeight}">`
    + `<animate attributeName="x" calcMode="discrete" values="${values}" dur="${durationSeconds.toFixed(2)}s" repeatCount="indefinite"/>`
    + `</image></svg>`
}
