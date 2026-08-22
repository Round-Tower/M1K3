package app.m1k3.ai.domain.avatar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Pinning tests for [PixelFace], ported 1:1 from the Mac's PixelFaceTests
 * (macos/Tests/M1K3ScreensaverCoreTests/M1K3ScreensaverCoreTests.swift) so
 * both surfaces are provably drawing the same face.
 */
class PixelFaceTest {
    @Test
    fun `grid matches the Mac screensaver face`() {
        assertEquals(13, PixelFace.COLS)
        assertEquals(11, PixelFace.ROWS)
        assertEquals(FaceCell(col = 4, row = 3), PixelFace.leftEye)
        assertEquals(FaceCell(col = 8, row = 3), PixelFace.rightEye)
    }

    @Test
    fun `at rest both pupils are lit as single cells`() {
        // t=0: not blinking, no glance -> round pupils at their homes.
        assertFalse(PixelFace.isBlinking(0.0))
        assertEquals(0, PixelFace.glanceOffset(0.0))
        val cells = PixelFace.litCells(0.0)
        assertTrue(cells.contains(FaceCell(col = 4, row = 3)))
        assertTrue(cells.contains(FaceCell(col = 8, row = 3)))
        // No closed-eye line neighbours when open.
        assertFalse(cells.contains(FaceCell(col = 3, row = 3)))
        assertFalse(cells.contains(FaceCell(col = 5, row = 3)))
    }

    @Test
    fun `blink closes each eye to a three cell line`() {
        // Tail of the first blink period.
        val t = 4.2 - 0.05
        assertTrue(PixelFace.isBlinking(t))
        val cells = PixelFace.litCells(t)
        for (dc in -1..1) {
            assertTrue(cells.contains(FaceCell(col = 4 + dc, row = 3)))
            assertTrue(cells.contains(FaceCell(col = 8 + dc, row = 3)))
        }
    }

    @Test
    fun `glance shifts both pupils the same way`() {
        // Tail of the first glance period (phase >= period - duration), and not
        // a blink moment -> both pupils dart the same way.
        val t = 5.2
        assertFalse(PixelFace.isBlinking(t))
        val dx = PixelFace.glanceOffset(t)
        assertNotEquals(0, dx)
        val cells = PixelFace.litCells(t)
        assertTrue(cells.contains(FaceCell(col = 4 + dx, row = 3)))
        assertTrue(cells.contains(FaceCell(col = 8 + dx, row = 3)))
    }

    @Test
    fun `smile turns up at the corners`() {
        val cells = PixelFace.litCells(0.0)
        // A ⌣ curve: corners highest (row 6), middle lowest (row 8).
        assertTrue(cells.contains(FaceCell(col = 3, row = PixelFace.MOUTH_ROW - 1)))
        assertTrue(cells.contains(FaceCell(col = 9, row = PixelFace.MOUTH_ROW - 1)))
        assertTrue(cells.contains(FaceCell(col = 6, row = PixelFace.MOUTH_ROW + 1)))
        // The full mouth spans cols 3...9, stepping up one row per cell toward
        // the corners (distance from centre column 6 sets the row).
        for (col in 3..9) {
            val dc = kotlin.math.abs(col - 6)
            val onRow =
                when (dc) {
                    3 -> PixelFace.MOUTH_ROW - 1
                    2 -> PixelFace.MOUTH_ROW
                    else -> PixelFace.MOUTH_ROW + 1
                }
            assertTrue(cells.contains(FaceCell(col = col, row = onRow)))
        }
    }

    @Test
    fun `lit cells stay inside the grid`() {
        for (step in 0 until 200) {
            val t = step * 0.1
            for (cell in PixelFace.litCells(t)) {
                assertTrue(cell.col in 0 until PixelFace.COLS)
                assertTrue(cell.row in 0 until PixelFace.ROWS)
            }
        }
    }
}
