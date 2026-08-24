package app.m1k3.ai.domain.avatar

import kotlin.math.abs
import kotlin.math.floor

/**
 * A cell in the face matrix (origin top-left; col increases right, row down).
 */
data class FaceCell(
    val col: Int,
    val row: Int,
)

/**
 * M1K3's calm, resting face — a 13×11 pixel matrix mirroring the Mac
 * screensaver's `PixelFace` (macos/Sources/M1K3ScreensaverCore/PixelFace.swift)
 * EXACTLY, so the same character shows up on every M1K3 surface. Pure and
 * deterministic (time in, cells out) — no drawing context, no per-emotion
 * shape. One settled mood: open eyes that blink and glance idly, and a
 * gentle ⌣ smile.
 *
 * Ported rather than shared via any binary link — this module has no Apple
 * dependency and needs none; the grid math is a dozen lines of arithmetic.
 *
 * Signed: kev + claude-fable-5, 2026-08-22, confidence 0.85. Context: the
 * Android UX pass replaces the 64×64 DotMatrix hero (a 539-line, 8-emotion
 * region-art DSL that read as garbled at the hero's actual on-screen size)
 * with this. Reduction, not a like-for-like port — one calm face, matching
 * the Mac's own screensaver choice that a resting mood is enough.
 * Prior: PixelFace.swift (M1K3ScreensaverCore, Kev + claude-opus-4-8, 2026-08-20).
 */
object PixelFace {
    const val COLS = 13
    const val ROWS = 11

    val leftEye = FaceCell(col = 4, row = 3)
    val rightEye = FaceCell(col = 8, row = 3)
    const val MOUTH_ROW = 7

    // Blink: closed for a blink flick at the tail of each period.
    private const val BLINK_PERIOD = 4.2
    private const val BLINK_DURATION = 0.16

    // Glance: a one-cell sideways dart, briefly, on its own slow cycle.
    private const val GLANCE_PERIOD = 5.3
    private const val GLANCE_DURATION = 0.5

    /** True while the eyes are mid-blink (closed). */
    fun isBlinking(time: Double): Boolean {
        val t = time.rem(BLINK_PERIOD)
        return t >= BLINK_PERIOD - BLINK_DURATION
    }

    /**
     * The idle glance offset in cols: 0 at rest, ±1 during a brief dart. The
     * direction alternates each glance so the eyes don't always look the same way.
     */
    fun glanceOffset(time: Double): Int {
        // Fire in the TAIL of each period (like the blink) so t=0 is centred rest,
        // not mid-glance — the face opens looking straight ahead.
        val phase = time.rem(GLANCE_PERIOD)
        if (phase < GLANCE_PERIOD - GLANCE_DURATION) return 0
        val index = floor(time / GLANCE_PERIOD).toInt()
        return if (index % 2 == 0) 1 else -1
    }

    /**
     * Every lit cell of the face at [time] — the two eyes (or the closed blink
     * lines) plus the resting smile. What the renderer glows.
     */
    fun litCells(time: Double): Set<FaceCell> {
        val cells = eyeCells(time).toMutableSet()
        cells += smileCells()
        return cells
    }

    // ── eyes ─────────────────────────────────────────────────────────────

    private fun eyeCells(time: Double): Set<FaceCell> {
        if (isBlinking(time)) {
            // Closed: a flat 3-cell line at each eye's row.
            val closed = mutableSetOf<FaceCell>()
            for (anchor in listOf(leftEye, rightEye)) {
                for (dc in -1..1) {
                    closed += FaceCell(col = anchor.col + dc, row = anchor.row)
                }
            }
            return closed
        }
        // Open: a single pupil per eye, shifted by the idle glance.
        val dx = glanceOffset(time)
        return setOf(
            FaceCell(col = leftEye.col + dx, row = leftEye.row),
            FaceCell(col = rightEye.col + dx, row = rightEye.row),
        )
    }

    // ── mouth (a settled smile: corners turned up one row) ─────────────────

    private fun smileCells(): Set<FaceCell> {
        // A gentle ⌣: the middle dips to the mouth row, stepping up one row for
        // each cell out to the corners — a connected, warm upturn. Distance from
        // the centre column (6) sets the row.
        val mouth = mutableSetOf<FaceCell>()
        for (col in 3..9) {
            val dc = abs(col - 6)
            val row =
                when (dc) {
                    3 -> MOUTH_ROW - 1

                    // cols 3, 9 — corners highest
                    2 -> MOUTH_ROW

                    // cols 4, 8
                    else -> MOUTH_ROW + 1 // cols 5, 6, 7 — middle lowest
                }
            mouth += FaceCell(col = col, row = row)
        }
        return mouth
    }
}
