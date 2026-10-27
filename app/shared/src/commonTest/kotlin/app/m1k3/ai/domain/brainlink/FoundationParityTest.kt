package app.m1k3.ai.domain.brainlink

import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Pins the Foundation reads the Mac's M1K3BrainLink leans on without saying so
 * (Swift's Int from a string, CharacterSet.whitespaces, JSONSerialization's
 * `as? String` / `as? Int`), so the Kotlin twins read the wire the same way.
 *
 * Every expected value was printed on macOS 27 (2026-10-27) by a swiftc probe
 * built from `macos/Sources/M1K3BrainLink/BrainLinkPolicies.swift` and its
 * siblings plus a main that prints Int(_:), trimmingCharacters(in:
 * .whitespaces), JSONSerialization's `as? [String: Any]` and the `as? String`
 * and `as? Int` reads for each literal below; the printed lines are in the PR
 * that added this file. Where the twin answers differently, the test names the
 * gap.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (each literal
 * read off the Mac's own Foundation; the two named gaps are deliberate).
 * Prior: none (new file).
 * Review: Kev + claude-opus-5.5, 2026-10-27 — the code-quality fold: the strict
 * walk pinned on nested values and JSON's number grammar, the Int read's full
 * match pinned on mixed-script digits, the Int edges named, and the provenance
 * made reproducible (each literal re-run through the probe). Confidence 0.85.
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
        // U+0663 is ARABIC-INDIC DIGIT THREE and U+FF18 FULLWIDTH DIGIT EIGHT: Kotlin's
        // toIntOrNull takes both, alone or beside an ASCII digit; Swift takes neither.
        for (junk in listOf("", "+", "+-1", "1e3", " 80", "80 ", "80\n", "٣", "٣0", "8٣", "８")) {
            assertNull(junk.toSwiftIntOrNull(), "'$junk' is not an Int on the Mac")
        }
    }

    @Test
    fun `an integer past Int range reads as absent`() {
        assertEquals(Int.MAX_VALUE, "2147483647".toSwiftIntOrNull())
        assertEquals(Int.MIN_VALUE, "-2147483648".toSwiftIntOrNull())
        // Gap one: Swift's 64-bit Int takes these. No port or retry the Mac sends comes near them.
        for (past in listOf("2147483648", "-2147483649", "99999999999")) {
            assertNull(past.toSwiftIntOrNull(), past)
        }
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
    fun `the strict walk reaches nested values`() {
        // Foundation refuses every one of these; kotlinx alone keeps the bad token as a primitive.
        for (body in listOf(
            """{"a":[abc]}""",
            """{"a":{"b":abc}}""",
            """{"a":[1,{"b":NaN}]}""",
            """{"a":01}""",
            """{"a":-01}""",
            """{"a":+1}""",
            """{"a":.5}""",
            """{"a":1.}""",
            """{"a":1e}""",
            """{"a":-}""",
            """{"a":True}""",
            """{"a":'x'}""",
        )) {
            assertNull(parseJsonObject(body), body)
        }
        // ...and takes every valid shape, padded with whitespace or nested.
        val nested = assertNotNull(parseJsonObject("""{"a":[true,false,null,-1.5e+3,"s"],"b":{"c":0}}"""))
        assertEquals(0, (nested["b"] as? JsonObject)?.wholeIntOrNull("c"))
        assertEquals(1, parseJsonObject(" {\"a\":1}\n")?.wholeIntOrNull("a"))
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
