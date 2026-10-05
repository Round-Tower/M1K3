// The m1k3 mod: guard, voice, and the avatar band. The engine takes one
// unmatched hook per event per module and never `$` as an argument, so every
// event is registered here once and every `$` call is spelled here; the parts
// (guard.ts, avatar-state.ts, voice.ts, companion.ts, face-math.ts, raster.ts)
// are pure and say what to do. `session.start` binds the closures the other
// hooks and the timers share (apply a mood change, say a line, paint a frame).
//
// Signed: Kev + Claude, 2026-10-05, Confidence 0.7 (the hooks load and the
// pure parts are pinned; the band's look on each surface is verify-by-launch).
// Prior: Unknown
// Review: Kev + Claude, 2026-10-05 — summoned pass on #493: `speak` is bounded
// (SPEAK_TIMEOUT_MS) and gapped (SPEAK_GAP_MS), both falling back to the toast;
// answers are read aloud only under `readAnswers`. Confidence 0.7.

import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import {
  AVATARS, onNotification, onQuiet, onSessionStart, onSpeak, onToolEnd, onToolStart, onTurnComplete, onTurnStart,
  type Change,
} from './avatar-state'
import {
  BAND_COLUMNS, BAND_ROWS, BRAILLE_COLOUR, Loaded, braillePath, clipFor, clipMeta, frameIndex, framePath, manifestPath, parseBraille, parseManifest, stripPath,
  type BrailleClip, type Look, type Manifest,
} from './companion'
import { isActive, statusLabel } from './face-math'
import { registerGuard, xcodeprojMessage } from './guard'
import { FACE_COLUMNS, FACE_ROWS, brailleCells, faceCells, faceSvg, spriteSvg } from './raster'
import { SERVER, SPEAK_TIMEOUT_MS, maySpeak, speakingMs, voiceForNotification, voiceForTurn } from './voice'
import type { Avatar, Mood } from '../types'

// The session's values (types/index.d.ts is the contract). Consts of this
// file, so the engine's scan can list what the module reads and writes.
const avatar = atom({ plugin: 'm1k3', key: 'avatar' } as const, 'face' as Avatar)
const mood = atom({ plugin: 'm1k3', key: 'mood' } as const, { emotion: 'neutral', activity: 'idle', since: 0 } as Mood)
const isBandHidden = atom({ plugin: 'm1k3', key: 'isBandHidden' } as const, false)
/** The band's second line: what M1K3 is reacting to, in a few words. */
const note = atom({ plugin: 'm1k3', key: 'note' } as const, 'Waiting for you.')

const AVATAR_STORE_KEY = 'm1k3.avatar'
const TIER_STORE_KEY = 'm1k3.companionTier'

type Tier = 'image' | 'braille'
type Band = { requestId: string; surface: string }

const isAvatar = (value: unknown): value is Avatar => typeof value === 'string' && (AVATARS as readonly string[]).includes(value)

export const register: Register = (on, options) => {
  registerGuard(on)

  const isVoiceOn = options.voice !== false
  const readsAnswers = options.readAnswers === true
  let lastSpokeAt = -Infinity
  let band: Band | undefined
  let tier: Tier = 'image'
  let root = ''
  let settle: { cancel: () => void } | undefined
  let lastActivityAt = 0
  let clipStartedAt = 0
  let lastClip = ''
  let lastPaintAt = 0
  let lastDesktopAt = 0
  const manifests = new Loaded<Manifest>()
  const brailles = new Loaded<BrailleClip>()
  const strips = new Loaded<string>()

  // Bound at session.start, where the session's `$` is; no-ops until then.
  let applyChange: (change: Change) => Promise<void> = async () => undefined
  let sayLine: (text: string, emotion: string) => Promise<void> = async () => undefined

  on('session.start', async ($, e, next) => {
    root = $.plugin.root
    lastActivityAt = await $.clock.now()
    const stored = await $.store.get(AVATAR_STORE_KEY).catch(() => undefined)
    const initial: Avatar = isAvatar(stored) ? stored : isAvatar(options.avatar) ? options.avatar : 'face'
    await update($, avatar, () => initial)
    if ((await $.store.get(TIER_STORE_KEY).catch(() => undefined)) === 'braille') tier = 'braille'

    applyChange = async change => {
      const now = await $.clock.now()
      settle?.cancel()
      settle = undefined
      await update($, mood, () => ({ ...change.state, since: now }))
      if (change.note !== undefined) await update($, note, () => change.note ?? '')
      const then = change.then
      if (then !== undefined) {
        settle = $.clock.after(then.afterMs, async () => {
          // Only settle what this change set; a later event may have moved on.
          if ((await read($, mood)).since !== now) return
          await update($, mood, () => ({ ...then.state, since: now + then.afterMs }))
          if (then.note !== undefined) await update($, note, () => then.note ?? '')
        })
      }
    }

    sayLine = async (text, emotion) => {
      // Speech behind speech is noise: a line within the gap toasts instead. A
      // `speak` that stalls (a wedged voice engine, #471) is bounded the same way.
      const now = await $.clock.now()
      if (!maySpeak(now, lastSpokeAt)) {
        $.ui.toast(text, { timeoutMs: 6000 })
        return
      }
      lastSpokeAt = now
      try {
        const result = await Promise.race([
          $.mcp.call(SERVER, 'speak', { text, emotion }),
          new Promise<never>((_, reject) => $.clock.after(SPEAK_TIMEOUT_MS, () => reject(new Error('speak timed out')))),
        ])
        if (result.isError) throw new Error('speak refused')
        await applyChange(onSpeak(text, speakingMs(text)))
      } catch {
        $.ui.toast(text, { timeoutMs: 6000 })
      }
    }

    await applyChange(onSessionStart())

    // `xcodegen` after every checkout: the project file is a gitignored artifact.
    const [hasSpec, hasProject] = await Promise.all([$.fs.exists('macos/project.yml'), $.fs.exists('macos/M1K3.xcodeproj/project.pbxproj')])
    const specMtime = hasSpec ? (await $.fs.stat('macos/project.yml')).mtimeMs : 0
    const projectMtime = hasProject ? (await $.fs.stat('macos/M1K3.xcodeproj/project.pbxproj')).mtimeMs : 0
    const stale = xcodeprojMessage(hasSpec, hasProject, specMtime, projectMtime)
    if (stale !== undefined) $.ui.status(stale)

    await $.command.register({ name: 'face', description: 'Hide or show the M1K3 band above the prompt' })
    await $.command.register({ name: 'companion', description: 'Pick the M1K3 avatar: face, fox, phosphor or off', argumentHint: '[face|fox|phosphor|off]' })

    // Idle life: a quiet half hour drifts the face to sleepy; the next turn wakes it.
    $.clock.every(60_000, async () => {
      const change = onQuiet(await read($, mood), await $.clock.now(), lastActivityAt)
      if (change !== undefined) await applyChange(change)
    })

    // The band's clock: the face at 30 fps while active and 2 fps idle, a
    // companion at its clip's own rate. Nothing is painted while hidden.
    $.clock.every(33, async () => {
      if (band === undefined) return
      const which = await read($, avatar)
      if (which === 'off' || (await read($, isBandHidden))) return
      const current = await read($, mood)
      const now = await $.clock.now()
      const lively = isActive(current.activity) || current.activity === 'error'

      if (band.surface !== 'terminal') {
        // No blit on a remote surface: redraw the Svg a few times a second while
        // the face is active (a companion's SMIL sprite animates by itself).
        if (which !== 'face') return
        const every = lively ? 250 : 1000
        if (now - lastDesktopAt < every) return
        lastDesktopAt = now
        $.ui.invalidate('ui.render')
        return
      }

      if (which === 'face') {
        const every = lively ? 33 : 500
        if (now - lastPaintAt < every) return
        lastPaintAt = now
        await $.ui.blit({ requestId: band.requestId, key: 'face', cells: faceCells(current, now / 1000) })
        return
      }

      const look: Look = which
      const clip = clipFor(current)
      if (clip !== lastClip) {
        lastClip = clip
        clipStartedAt = now
      }
      const meta = clipMeta(await manifests.get(root, () => $.fs.read(manifestPath(root)).then(parseManifest)), look, clip)
      const every = Math.max(33, (meta.duration * 1000) / meta.frames)
      if (now - lastPaintAt < every) return
      lastPaintAt = now
      const index = frameIndex(meta, (now - clipStartedAt) / 1000)

      if (tier === 'image') {
        const blit = await $.ui.blit({ requestId: band.requestId, key: 'fox', source: { file: framePath(root, look, clip, index), format: 'png' } })
        if (blit.deny !== undefined && /\balt\b/.test(blit.deny)) {
          // This terminal cannot draw pictures: drop to braille for good here.
          tier = 'braille'
          await $.store.set(TIER_STORE_KEY, tier).catch(() => undefined)
          $.ui.invalidate('ui.render')
        }
        return
      }
      const path = braillePath(root, look, clip)
      const braille = await brailles.get(path, () => $.fs.read(path).then(parseBraille))
      await $.ui.blit({ requestId: band.requestId, key: 'fox', cells: brailleCells(braille.band[index] ?? [], BRAILLE_COLOUR[look]) })
    })

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    lastActivityAt = await $.clock.now()
    await applyChange(onTurnStart(e.text))
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const current = await read($, mood)
    const before = onToolStart(current, e.tool, e as unknown as Record<string, unknown>)
    if (before !== undefined) await applyChange(before)
    const ran = await next(e)
    const after = onToolEnd(current.activity === 'idle', ran.deny === undefined && ran.isError === true, e.tool)
    if (after !== undefined) await applyChange(after)
    return ran
  })

  on('classic.Notification', async ($, e, next) => {
    const change = onNotification(e.notification_type, e.message)
    if (change !== undefined) await applyChange(change)
    const line = isVoiceOn ? voiceForNotification(e.notification_type, e.message) : undefined
    if (line !== undefined) void sayLine(line.text, line.emotion)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    lastActivityAt = await $.clock.now()
    await applyChange(onTurnComplete(e.reason))
    const line = isVoiceOn ? voiceForTurn(e.reason, e.answer, e.durationMs, readsAnswers) : undefined
    if (line !== undefined) void sayLine(line.text, line.emotion)
    return next(e)
  })

  on('command.run', { command: 'face' }, async ($, e) => {
    const wanted = e.args.trim().toLowerCase()
    const hide = wanted === 'off' || wanted === 'hide' ? true : wanted === 'on' || wanted === 'show' ? false : !(await read($, isBandHidden))
    await update($, isBandHidden, () => hide)
    return { text: hide ? 'M1K3 band hidden.' : 'M1K3 band shown.' }
  })

  on('command.run', { command: 'companion' }, async ($, e) => {
    const wanted = e.args.trim().toLowerCase()
    if (!isAvatar(wanted)) return { text: `Pick one of ${AVATARS.join(', ')} (now: ${await read($, avatar)}).` }
    await update($, avatar, () => wanted)
    await update($, isBandHidden, () => false)
    await $.store.set(AVATAR_STORE_KEY, wanted)
    lastClip = ''
    return { text: wanted === 'off' ? 'M1K3 avatar off.' : `M1K3 avatar: ${wanted}.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const which = await read($, avatar)
    if (e.props.hasSurvey || which === 'off' || (await read($, isBandHidden))) {
      band = undefined
      return next(e)
    }
    band = { requestId: e.requestId, surface: e.surface }
    const home = root || $.plugin.root
    const current = await read($, mood)
    const line = await read($, note)
    const time = (await $.clock.now()) / 1000
    const label = statusLabel(current.activity) + (current.activity === 'idle' && current.emotion !== 'neutral' ? ` · ${current.emotion}` : '')

    const { Box, Text } = $.ui.resolve(e)
    const caption = (
      <Box flexDirection="column" marginLeft={2}>
        <Text>
          <Text dimColor>M1K3 · </Text>
          <Text bold>{label}</Text>
        </Text>
        <Text dimColor wrap="truncate-end">{line}</Text>
      </Box>
    )

    if (e.surface === 'terminal') {
      const { Raster, Image } = $.ui.resolve(e)
      if (which === 'face') {
        return (
          <Box flexDirection="row" alignItems="center">
            <Raster key="face" columns={FACE_COLUMNS} rows={FACE_ROWS} cells={faceCells(current, time)} />
            {caption}
          </Box>
        )
      }
      const look: Look = which
      const clip = clipFor(current)
      if (tier === 'image') {
        return (
          <Box flexDirection="row" alignItems="center">
            <Image
              key="fox"
              source={{ file: framePath(home, look, clip, 0), format: 'png' }}
              columns={BAND_COLUMNS}
              rows={BAND_ROWS}
              alt={look === 'fox' ? "M1K3's fox" : "M1K3's phosphor fox"}
            />
            {caption}
          </Box>
        )
      }
      const path = braillePath(home, look, clip)
      const braille = await brailles.get(path, () => $.fs.read(path).then(parseBraille))
      return (
        <Box flexDirection="row" alignItems="center">
          <Raster key="fox" columns={BAND_COLUMNS} rows={BAND_ROWS} cells={brailleCells(braille.band[0] ?? [], BRAILLE_COLOUR[look])} />
          {caption}
        </Box>
      )
    }

    // Desktop, editor, mobile: no Raster or Image, so the face is an Svg and a
    // companion is a self-animating SMIL sprite.
    const { Svg } = $.ui.resolve(e)
    if (which === 'face') {
      return (
        <Box flexDirection="row" alignItems="center">
          <Svg source={faceSvg(current, time, 8)} alt={`M1K3 ${label}`} width={13 * 8 + 12} height={11 * 8 + 12} />
          {caption}
        </Box>
      )
    }
    const look: Look = which
    const clip = clipFor(current)
    const manifest = await manifests.get(home, () => $.fs.read(manifestPath(home)).then(parseManifest))
    const meta = clipMeta(manifest, look, clip)
    const strip = await strips.get(stripPath(home, look, clip), () => $.fs.read(stripPath(home, look, clip), { as: 'bytes' }).then(bytes => bytes.base64))
    return (
      <Box flexDirection="row" alignItems="center">
        <Svg source={spriteSvg(strip, meta.svgFrames, meta.duration)} alt={`M1K3's ${look}, ${clip.toLowerCase()}`} width={160} height={80} isInteractive />
        {caption}
      </Box>
    )
  })
}
