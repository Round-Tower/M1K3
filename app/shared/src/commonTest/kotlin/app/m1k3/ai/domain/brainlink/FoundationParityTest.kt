package app.m1k3.ai.domain.brainlink

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Pins the Foundation reads the Mac's M1K3BrainLink leans on without saying so
 * (Swift's Int from a string, CharacterSet.whitespaces, JSONSerialization's
 * `as? String` / `as? Int`), so the Kotlin twins read the wire the same way.
 *
 * Every expected value was printed by Foundation on macOS 27 from a scratch
 * build of `macos/Sources/M1K3BrainLink/BrainLinkPolicies.swift` and its
 * siblings (2026-10-27), not assumed.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (each literal
 * read off the Mac's own Foundation; the two named gaps are deliberate).
 * Prior: none (new file).
 */
class FoundationParityTest {
    @Test
    fun `integers read like Swift Int from a string`() {
        assertEquals(52113, "52113".toSwiftIntOrNull())
        assertEquals(80, "+80".toSwiftIntOrNull())
        assertEquals(80, "0080".toSwiftIntOrNull())
        assertEquals(-5, "-5".toSwiftIntOrNull())
        assertEquals(0, "-0".toSwiftIntOrNull())
    }

    @Test
    fun `anything Swift Int refuses reads as absent`() {
        // U+0663 is ARABIC-INDIC DIGIT THREE: Kotlin's toIntOrNull takes it, Swift does not.
        for (junk in listOf("", "+", "+-1", "1e3", " 80", "٣")) {
            assertNull(junk.toSwiftIntOrNull(), "'$junk' is not an Int on the Mac")
        }
    }

    @Test
    fun `an integer past Int range reads as absent`() {
        // Gap one: Swift's 64-bit Int takes this. No port or retry the Mac sends comes near it.
        assertNull("99999999999".toSwiftIntOrNull())
    }

    @Test
    fun `whitespace trims like CharacterSet whitespaces`() {
        assertEquals("done", " \tdone\t ".trimSwiftWhitespaces())
        assertEquals("x", " x ".trimSwiftWhitespaces())
        assertEquals("y", " y　".trimSwiftWhitespaces())
        // Line breaks are not in the set: the Mac keeps them, so must we.
        assertEquals("done\r", "done\r".trimSwiftWhitespaces())
        assertEquals("\nx", "\nx".trimSwiftWhitespaces())
    }

    @Test
    fun `only a whole JSON object reads as one`() {
        assertNotNull(parseJsonObject("""{"a":1}"""))
        assertNull(parseJsonObject("[1]"))
        assertNull(parseJsonObject("nope"))
        assertNull(parseJsonObject("""{"token":"t"} x"""))
        assertNull(parseJsonObject("""{"a":abc}"""))
        assertNull(parseJsonObject(""))
        assertNull(parseJsonObject(null))
    }

    @Test
    fun `a field reads as a string only when it is one`() {
        assertEquals("x", parseJsonObject("""{"token":"x"}""")?.stringOrNull("token"))
        for (body in listOf("""{"token":1}""", """{"token":null}""", """{"token":true}""", "{}")) {
            assertNull(parseJsonObject(body)?.stringOrNull("token"), body)
        }
    }

    @Test
    fun `a field reads as an Int when it is a whole JSON number`() {
        val cases =
            mapOf(
                """{"s":30}""" to 30,
                """{"s":30.0}""" to 30,
                """{"s":1e2}""" to 100,
                """{"s":-0.0}""" to 0,
                """{"s":-5}""" to -5,
            )
        for ((body, expected) in cases) {
            assertEquals(expected, parseJsonObject(body)?.wholeIntOrNull("s"), body)
        }
    }

    @Test
    fun `fractions strings and nulls are not an Int`() {
        for (body in listOf("""{"s":30.5}""", """{"s":"30"}""", """{"s":null}""", "{}")) {
            assertNull(parseJsonObject(body)?.wholeIntOrNull("s"), body)
        }
    }

    @Test
    fun `a bool or an out of range number is not an Int`() {
        // Gap two: the Mac's NSNumber bridging reads true as 1 and 3000000000 as itself.
        // Neither is a retry the server writes, so the twin refuses them.
        assertNull(parseJsonObject("""{"s":true}""")?.wholeIntOrNull("s"))
        assertNull(parseJsonObject("""{"s":3000000000}""")?.wholeIntOrNull("s"))
    }
}
